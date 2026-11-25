import Foundation
import Security
import SwiftUI

/// The server this Apple TV signed in to, kept across launches; the token stays in the Keychain.
@MainActor
final class Session: ObservableObject {
    enum Stage: Equatable {
        case needsServer
        case needsSignIn
        case signedIn
    }

    @Published private(set) var stage: Stage = .needsServer
    @Published private(set) var serverName: String?
    /// A plain Jellyfin server rather than AIOStreams, as the web app tells: its libraries sort and
    /// filter as asked, where an AIOStreams catalog keeps its own order.
    @Published private(set) var isStock = false
    @Published private(set) var userName: String?
    /// Who's watching is asked before the pages show (Ask when the app opens).
    @Published private(set) var asking = false
    private var leftAt: Date?

    /// Ask when the app opens, and when it's come back to after half an hour, as the web app's
    /// Who's watching setting does (kept on this Apple TV).
    static var askWho: Bool {
        get { UserDefaults.standard.bool(forKey: "account.askWho") }
        set { UserDefaults.standard.set(newValue, forKey: "account.askWho") }
    }
    private(set) var client: JellyfinClient?
    private(set) var userId: String?

    private let defaults = UserDefaults.standard

    struct SavedServer: Codable, Hashable, Identifiable {
        let address: String
        let name: String?
        var id: String { address }
    }

    static var serverHistory: [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: Keys.history),
              let list = try? JSONDecoder().decode([SavedServer].self, from: data) else { return [] }
        return list
    }

    private static func recordHistory(address: String, name: String?) {
        var list = serverHistory.filter { $0.address != address }
        list.insert(SavedServer(address: address, name: name), at: 0)
        if list.count > 5 { list = Array(list.prefix(5)) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Keys.history)
        }
    }

    init() {
        guard let saved = defaults.string(forKey: Keys.server), let base = URL(string: saved) else { return }
        serverName = defaults.string(forKey: Keys.serverName)
        var client = Self.makeClient(base)
        if let token = Keychain.read(Keys.token), let user = defaults.string(forKey: Keys.userId) {
            client.token = token
            userId = user
            userName = defaults.string(forKey: Keys.userName)
            stage = .signedIn
            asking = Self.askWho
        } else {
            stage = .needsSignIn
        }
        self.client = client
    }

    private static func makeClient(_ base: URL) -> JellyfinClient {
        JellyfinClient(base: base, token: nil, deviceId: AppInfo.deviceId, deviceName: AppInfo.deviceName)
    }

    /// Reads whether the server is AIOStreams or plain Jellyfin.
    func readServerKind() async {
        guard let client else { return }
        if let info: PublicSystemInfo = try? await client.get("/System/Info/Public") {
            isStock = info.aiostreams == nil
        }
    }

    /// Checks the address answers as this kind of server before keeping it.
    func connect(to address: String) async throws {
        guard let base = JellyfinClient.normalize(address) else {
            throw JellyfinError(status: 0, message: L("That is not a valid address."))
        }
        let client = Self.makeClient(base)
        let info: PublicSystemInfo = try await client.get("/System/Info/Public")
        self.client = client
        serverName = info.serverName
        defaults.set(base.absoluteString, forKey: Keys.server)
        defaults.set(info.serverName, forKey: Keys.serverName)
        Self.recordHistory(address: base.absoluteString, name: info.serverName)
        stage = .needsSignIn
        AppLog.info("session", "connected to \(base.host ?? "?") (\(info.serverName ?? "unnamed"))")
    }

    func signIn(_ result: AuthResult) {
        guard var client else { return }
        client.token = result.accessToken
        self.client = client
        userId = result.user.id
        userName = result.user.name
        Keychain.write(Keys.token, result.accessToken)
        defaults.set(result.user.id, forKey: Keys.userId)
        defaults.set(result.user.name, forKey: Keys.userName)
        stage = .signedIn
        asking = false
    }

    func signOut() {
        if let client, client.token != nil {
            Task { await client.fire("/Sessions/Logout", body: [:]) }
        }
        client?.token = nil
        userId = nil
        userName = nil
        Keychain.delete(Keys.token)
        defaults.removeObject(forKey: Keys.userId)
        defaults.removeObject(forKey: Keys.userName)
        stage = client == nil ? .needsServer : .needsSignIn
    }

    /// Whoever was watching carries on, without signing in again.
    func carryOn() { asking = false }

    /// The app went to the background, or came back: after half an hour away, who's watching is asked.
    func left() { leftAt = Date() }

    func returned() {
        defer { leftAt = nil }
        guard stage == .signedIn, Self.askWho, let leftAt, Date().timeIntervalSince(leftAt) >= 1800 else { return }
        asking = true
    }

    func forgetServer() {
        signOut()
        client = nil
        serverName = nil
        defaults.removeObject(forKey: Keys.server)
        defaults.removeObject(forKey: Keys.serverName)
        stage = .needsServer
    }

    /// The token expired or was revoked on the configure page.
    func expired() {
        AppLog.warn("session", "the server no longer accepts this sign-in")
        signOut()
    }

    private enum Keys {
        static let server = "server.base"
        static let serverName = "server.name"
        static let history = "server.history"
        static let userId = "user.id"
        static let userName = "user.name"
        static let token = "user.token"
    }
}

/// Generic password items for this app alone.
enum Keychain {
    private static let service = "com.skhan85.khanaiostreams.tv"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
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
