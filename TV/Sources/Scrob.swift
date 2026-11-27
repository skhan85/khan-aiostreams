import Foundation
import SwiftUI

/// The built-in player's plays, sent to Scrob: start, pause, resume and stop, with the position.
@MainActor
final class ScrobReporter {
    private let item: Item
    private let client: JellyfinClient
    private let userId: String?
    private let session = UUID().uuidString
    /// The title as Scrob identifies it, looked up once.
    private var lookup: Task<[String: Any], Never>?
    private var pending: Task<Void, Never>?

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
        let session = session
        if lookup == nil { lookup = Task { await self.describe() } }
        let lookup = lookup
        // Each event waits on the one before it, so they reach Scrob in order.
        let previous = pending
        pending = Task {
            await previous?.value
            guard let described = await lookup?.value else { return }
            Scrob.report(event, item: described, session: session, position: position, total: runtime)
        }
    }

    /// The title, with the ids Scrob matches on. An episode's own ids from AIOStreams can be missing,
    /// so it carries its show's IMDb and TVDB ids, which Scrob looks the show up by.
    private func describe() async -> [String: Any] {
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
