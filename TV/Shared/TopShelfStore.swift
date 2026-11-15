import Foundation

/// What the Apple TV's home screen shows for the app when it's in the top row (Top Shelf): the app's
/// Continue watching and Next up, which the app leaves in the app group's defaults as it loads Home,
/// for the Top Shelf extension to read. The images are the server's, which need no sign-in.
enum TopShelfStore {
    static let group = "group.com.skhan85.khanaiostreams.tv"
    private static let key = "topShelf"

    struct Shelf: Codable {
        var sections: [Section]
    }

    struct Section: Codable {
        var title: String
        var entries: [Entry]
    }

    struct Entry: Codable {
        var id: String
        var title: String
        var image: URL?
        /// How far through it is, 0 to 1, where it's been started.
        var progress: Double?
    }

    static func save(_ shelf: Shelf) {
        guard let defaults = UserDefaults(suiteName: group), let data = try? JSONEncoder().encode(shelf) else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> Shelf? {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Shelf.self, from: data)
    }

    /// Opens a title's page in the app.
    static func openURL(_ id: String) -> URL? { URL(string: "aiostreams://item/\(id)") }
    /// Plays a title in the app, as its page's Play does.
    static func playURL(_ id: String) -> URL? { URL(string: "aiostreams://play/\(id)") }
}
