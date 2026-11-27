import Foundation
import Security

/// Scrob (github.com/ellite/scrob), a self-hosted watch tracker that passes plays on to Trakt, Simkl,
/// MDBList and the rest. The built-in player reports to it the way Scrob's Kodi add-on does
/// (POST /api/proxy/webhooks/kodi), signed in with Scrob's device link, so no key is typed on the TV.
enum Scrob {
    static let addressKey = "khan.scrob.address"
    fileprivate static let refreshKey = "scrob.refresh"

    /// The linked Scrob server, if there is one.
    static var address: URL? {
        guard ScrobKeychain.read(refreshKey) != nil else { return nil }
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
        ScrobKeychain.delete(refreshKey)
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
            throw LinkError.server("That address didn't answer as a Scrob server.")
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
                ScrobKeychain.write(refreshKey, refresh)
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
            guard let refresh = ScrobKeychain.read(Scrob.refreshKey),
                  let (data, _) = try? await Scrob.send(server, "auth/device/token",
                                                         json: ["grant_type": "refresh_token", "refresh_token": refresh]),
                  let reply = try? JSONDecoder().decode(TokenReply.self, from: data) else { return nil }
            if let token = reply.access_token, let newRefresh = reply.refresh_token {
                ScrobKeychain.write(Scrob.refreshKey, newRefresh)
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

    /// Sends one playback event as Scrob's Kodi add-on does: `event` is playback_started, _paused,
    /// _resumed or _stopped; `item` the title with its ids (type, title, showtitle, season, episode,
    /// year, uniqueid).
    /// Events go out one after another, so a stop never overtakes its start.
    @MainActor private static var queue: Task<Void, Never>?

    @MainActor
    static func report(_ event: String, item: [String: Any], session: String, position: Double, total: Double) {
        guard address != nil else { return }
        var payload: [String: Any] = [
            "event": event,
            "source": "aiostreams",
            "session_id": session,
            "item": item,
            "position_seconds": Int(max(0, position.isFinite ? position : 0)),
        ]
        if total.isFinite, total > 0 { payload["total_seconds"] = Int(total) }
        let previous = queue
        queue = Task {
            await previous?.value
            await post(payload)
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

/// The Scrob link's refresh token, in the app's own Keychain entries (the Apple TV app's
/// `Keychain` uses the same service, the bundle id, so a link made before this file stays).
enum ScrobKeychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.skhan85.khanaiostreams",
         kSecAttrAccount as String: key]
    }

    static func read(_ key: String) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
