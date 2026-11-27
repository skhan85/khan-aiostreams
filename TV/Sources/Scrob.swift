import Foundation
import SwiftUI

/// Scrob (github.com/ellite/scrob), a self-hosted watch tracker that passes plays on to Trakt, Simkl,
/// MDBList and the rest. The built-in player reports to it the way Scrob's Kodi add-on does
/// (POST /api/proxy/webhooks/kodi), signed in with Scrob's device link, so no key is typed on the TV.
enum Scrob {
    private static let addressKey = "khan.scrob.address"
    private static let refreshKey = "scrob.refresh"

    /// The linked Scrob server, if there is one.
    static var address: URL? {
        guard Keychain.read(refreshKey) != nil else { return nil }
        return UserDefaults.standard.string(forKey: addressKey).flatMap(URL.init(string:))
    }

    /// A typed address as the server's root: `scrob.example.com` becomes `https://scrob.example.com`.
    static func normalized(_ typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty else { return nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    static func unlink() {
        Keychain.delete(refreshKey)
        UserDefaults.standard.removeObject(forKey: addressKey)
        Task { await Tokens.shared.clear() }
    }

    // MARK: Device link (RFC 8628, as Scrob's /link page approves it)

    struct DeviceCode: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let verification_uri_complete: String
        let expires_in: Int
        let interval: Int
    }

    private struct TokenReply: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Int?
        let error: String?
    }

    enum LinkError: LocalizedError {
        case server(String)
        var errorDescription: String? {
            switch self {
            case .server(let reason): return reason
            }
        }
    }

    static func startLink(_ server: URL) async throws -> DeviceCode {
        let (data, response) = try await send(server, "auth/device/code",
                                              json: ["client_name": "Khan AIOStreams (Apple TV)", "scope": "write"])
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LinkError.server(L("That address didn't answer as a Scrob server."))
        }
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    /// Waits for the code to be approved on Scrob's /link page, then keeps the link. False when the
    /// code was turned down or ran out.
    static func finishLink(_ server: URL, _ code: DeviceCode) async -> Bool {
        var wait = max(code.interval, 5)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(wait))
            guard let (data, _) = try? await send(server, "auth/device/token", json: [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": code.device_code,
            ]), let reply = try? JSONDecoder().decode(TokenReply.self, from: data) else { continue }
            if let access = reply.access_token, let refresh = reply.refresh_token {
                UserDefaults.standard.set(server.absoluteString, forKey: addressKey)
                Keychain.write(refreshKey, refresh)
                await Tokens.shared.keep(access, for: reply.expires_in)
                return true
            }
            switch reply.error {
            case "slow_down": wait += 5
            case "authorization_pending", nil: continue
            default: return false
            }
        }
        return false
    }

    /// The access token, refreshed with the kept refresh token once it's near its end (they last a day).
    actor Tokens {
        static let shared = Tokens()
        private var access: String?
        private var expires = Date.distantPast

        func keep(_ token: String, for seconds: Int?) {
            access = token
            expires = Date().addingTimeInterval(TimeInterval(seconds ?? 86_400) - 300)
        }

        func clear() {
            access = nil
            expires = .distantPast
        }

        func current(_ server: URL, forceRefresh: Bool = false) async -> String? {
            if !forceRefresh, let access, Date() < expires { return access }
            guard let refresh = Keychain.read(Scrob.refreshKey),
                  let (data, _) = try? await Scrob.send(server, "auth/device/token",
                                                         json: ["grant_type": "refresh_token", "refresh_token": refresh]),
                  let reply = try? JSONDecoder().decode(TokenReply.self, from: data) else { return nil }
            if let token = reply.access_token, let newRefresh = reply.refresh_token {
                Keychain.write(Scrob.refreshKey, newRefresh)
                keep(token, for: reply.expires_in)
                return token
            }
            // Revoked in Scrob's Connected Apps: forget the link.
            if reply.error == "invalid_grant" {
                AppLog.warn("scrob", "link revoked, unlinking")
                Scrob.unlink()
            }
            return nil
        }
    }

    // MARK: Requests

    fileprivate static func send(_ server: URL, _ path: String, json: [String: Any],
                                 token: String? = nil) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: server.appending(path: "api/proxy/" + path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await URLSession.shared.data(for: request)
    }

    /// Sends one playback event; a token Scrob turns down is refreshed and the event sent once more.
    static func post(_ payload: [String: Any]) async {
        guard let server = address else { return }
        for attempt in 0..<2 {
            guard let token = await Tokens.shared.current(server, forceRefresh: attempt > 0) else { return }
            guard let (data, response) = try? await send(server, "webhooks/kodi", json: payload, token: token) else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { continue }
            if status != 200 {
                AppLog.warn("scrob", "event answered \(status): \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
            }
            return
        }
    }
}

/// The built-in player's plays, sent to Scrob: start, pause, resume and stop, with the position.
@MainActor
final class ScrobReporter {
    private let item: Item
    private let client: JellyfinClient
    private let userId: String?
    private let session = UUID().uuidString
    /// The title as Scrob identifies it, looked up once.
    private var identity: [String: Any]?

    init?(item: Item, client: JellyfinClient, userId: String?) {
        guard Scrob.address != nil, item.type == "Movie" || item.type == "Episode" else { return nil }
        self.item = item
        self.client = client
        self.userId = userId
    }

    func started(at position: Double, of duration: Double) { send("playback_started", position, duration) }
    func paused(at position: Double, of duration: Double) { send("playback_paused", position, duration) }
    func resumed(at position: Double, of duration: Double) { send("playback_resumed", position, duration) }
    func stopped(at position: Double, of duration: Double) { send("playback_stopped", position, duration) }

    private func send(_ event: String, _ position: Double, _ duration: Double) {
        let runtime = duration.isFinite && duration > 0
            ? duration : Double(item.runTimeTicks ?? 0) / (1000 * JellyfinClient.ticksPerMs)
        Task {
            let described = await describe()
            var payload: [String: Any] = [
                "event": event,
                "source": "aiostreams",
                "session_id": session,
                "item": described,
                "position_seconds": Int(max(0, position.isFinite ? position : 0)),
            ]
            if runtime > 0 { payload["total_seconds"] = Int(runtime) }
            await Scrob.post(payload)
        }
    }

    /// The title, with the ids Scrob matches on. An episode's own ids from AIOStreams can be missing,
    /// so it carries its show's IMDb and TVDB ids, which Scrob looks the show up by.
    private func describe() async -> [String: Any] {
        if let identity { return identity }
        var ids: [String: String] = [:]
        var described: [String: Any] = ["id": item.id]
        let wanted = [item.id, item.seriesId].compactMap { $0 }
        let found: ItemsResult? = try? await client.get("/Items", [
            "userId": userId, "Ids": wanted.joined(separator: ","), "Fields": "ProviderIds",
        ])
        let byId = Dictionary((found?.items ?? []).map { ($0.id, $0.providerIds ?? [:]) }) { first, _ in first }
        if item.type == "Episode" {
            let show = item.seriesId.flatMap { byId[$0] } ?? [:]
            if let imdb = show["Imdb"] { ids["imdb"] = imdb }
            if let tvdb = show["Tvdb"] { ids["tvdb"] = tvdb }
            if ids.isEmpty, let tmdb = show["Tmdb"] { ids["tmdb"] = tmdb }
            described["type"] = "episode"
            described["title"] = item.name ?? ""
            described["showtitle"] = item.seriesName ?? ""
            if let season = item.parentIndexNumber { described["season"] = season }
            if let episode = item.indexNumber { described["episode"] = episode }
        } else {
            let own = byId[item.id] ?? item.providerIds ?? [:]
            if let tmdb = own["Tmdb"] { ids["tmdb"] = tmdb }
            if let imdb = own["Imdb"] { ids["imdb"] = imdb }
            described["type"] = "movie"
            described["title"] = item.name ?? ""
            if let year = item.productionYear { described["year"] = year }
        }
        described["uniqueid"] = ids
        identity = described
        return described
    }
}

/// Links this Apple TV to a Scrob server: its address, then a code approved on Scrob's /link page.
struct ScrobLinkPanel: View {
    let done: () -> Void
    @State private var address = UserDefaults.standard.string(forKey: "khan.scrob.address") ?? ""
    @State private var code: Scrob.DeviceCode?
    @State private var state: String?
    @State private var working = false
    @State private var wait: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.px(14)) {
                Text(L("Link Scrob")).font(Theme.font(Theme.xl, .semibold))
                if let code {
                    Text(L("On your phone or computer, open the address below, sign in to Scrob and approve this code."))
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray400)
                    HStack(alignment: .center, spacing: Theme.px(20)) {
                        QRCodeView(url: code.verification_uri_complete, size: Theme.px(140))
                        VStack(alignment: .leading, spacing: Theme.px(6)) {
                            Text(code.user_code).font(Theme.font(Theme.xl2, .bold)).monospaced()
                            Text(code.verification_uri).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray300)
                        }
                    }
                } else {
                    Text(L("Plays in the built-in player are sent to your Scrob server, which passes them on to Trakt, Simkl or MDBList as you set it up there."))
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray400)
                    TextField(L("Scrob address"), text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.font(Theme.lg))
                }
                if let state {
                    Text(state).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray300)
                }
                HStack(spacing: Theme.px(8)) {
                    if code == nil {
                        Button(working ? L("Connecting…") : L("Get a code")) { Task { await start() } }
                            .buttonStyle(SoftPillStyle(selected: true))
                            .disabled(working || Scrob.normalized(address) == nil)
                    }
                    Button(L("Close"), action: close).buttonStyle(SoftPillStyle())
                }
            }
            .padding(Theme.px(24))
            .frame(width: Theme.px(620), alignment: .leading)
            .background(GlassBackground(shape: RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous),
                                        fill: Color(white: 17 / 255), panel: true))
            .overlay(RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous).stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
        }
        .foregroundStyle(.white)
        .onExitCommand(perform: close)
    }

    private func close() {
        wait?.cancel()
        done()
    }

    private func start() async {
        guard let server = Scrob.normalized(address) else { return }
        working = true
        state = nil
        defer { working = false }
        do {
            let issued = try await Scrob.startLink(server)
            code = issued
            wait = Task {
                let linked = await Scrob.finishLink(server, issued)
                guard !Task.isCancelled else { return }
                if linked {
                    done()
                } else {
                    code = nil
                    state = L("The code wasn't approved in time. Try again.")
                }
            }
        } catch {
            state = error.localizedDescription
        }
    }
}
