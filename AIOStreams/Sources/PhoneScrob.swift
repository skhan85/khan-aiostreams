import AetherEngineFeatures
import Foundation
import UIKit

/// The iPhone and iPad player's plays, sent to a linked Scrob server (ScrobCore.swift): the page's
/// `now-playing` names the title (its `scrob` ids, from web/khan.patch), the engine says when it
/// pauses, resumes and stops.
@MainActor
final class PhoneScrob {
    /// The title playing, as Scrob identifies it, and the page's id for it.
    private var item: [String: Any]?
    private var key: String?
    private var session = UUID().uuidString
    private var playing = false
    private var position: Double = 0
    private var duration: Double = 0

    /// The page named what plays, or that nothing does (nil).
    func nowPlaying(_ info: [String: Any]?, engineState: PlaybackState) {
        let scrob = info?["scrob"] as? [String: Any]
        let next = scrob.flatMap { ($0["id"] as? String) ?? ($0["title"] as? String) }
        guard next != key else { return }
        finish(ended: false)
        guard let scrob, let next, Scrob.address != nil else { return }
        key = next
        item = Self.describe(scrob)
        session = UUID().uuidString
        playing = engineState == .playing
        send("playback_started")
    }

    /// Where the player is, kept for the stop that follows.
    func tick(_ seconds: Double, of length: Double) {
        guard item != nil, seconds.isFinite else { return }
        position = seconds
        if length.isFinite, length > 0 { duration = length }
    }

    func stateChanged(_ state: PlaybackState) {
        guard item != nil else { return }
        switch state {
        case .playing where !playing:
            playing = true
            send("playback_resumed")
        case .paused where playing:
            playing = false
            send("playback_paused")
        case .ended:
            finish(ended: true)
        default:
            break
        }
    }

    /// The title stopped or ended: its last position goes to Scrob.
    func finish(ended: Bool) {
        guard item != nil else { return }
        if ended, duration > 0 { position = duration }
        send("playback_stopped")
        item = nil
        key = nil
        playing = false
        position = 0
        duration = 0
    }

    private func send(_ event: String) {
        guard let item else { return }
        Scrob.report(event, item: item, session: session, position: position, total: duration)
    }

    /// The page's ids as Scrob's Kodi webhook reads them. An episode carries its show's IMDb and
    /// TVDB ids, which Scrob looks the show up by; its TMDB id only when it has neither.
    private static func describe(_ scrob: [String: Any]) -> [String: Any] {
        func text(_ key: String) -> String? {
            (scrob[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func number(_ key: String) -> Int? { JSON.number(scrob[key]).map { Int($0) } }
        let episode = text("type") == "episode"
        var ids: [String: String] = [:]
        if let imdb = text("imdb") { ids["imdb"] = imdb }
        if episode, let tvdb = text("tvdb") { ids["tvdb"] = tvdb }
        if let tmdb = text("tmdb"), !episode || ids.isEmpty { ids["tmdb"] = tmdb }
        var described: [String: Any] = [
            "type": episode ? "episode" : "movie",
            "title": text("title") ?? "",
            "uniqueid": ids,
        ]
        if let id = text("id") { described["id"] = id }
        if episode {
            described["showtitle"] = text("showtitle") ?? ""
            if let season = number("season") { described["season"] = season }
            if let number = number("episode") { described["episode"] = number }
        } else if let year = number("year") {
            described["year"] = year
        }
        return described
    }
}

/// Links this iPhone or iPad to a Scrob server, from Settings > iOS app > Open: the address, then a
/// code approved on Scrob's /link page, which opens in Safari.
@MainActor
enum PhoneScrobLink {
    private static var wait: Task<Void, Never>?

    static func ask(from host: UIViewController) {
        let alert = UIAlertController(
            title: String(localized: "Link Scrob"),
            message: String(localized: "Plays in the built-in player go to your Scrob server, which passes them on to Trakt, Simkl or MDBList."),
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "scrob.example.com"
            field.text = UserDefaults.standard.string(forKey: Scrob.addressKey)
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Get a code"), style: .default) { [weak alert, weak host] _ in
            guard let host, let server = Scrob.normalized(alert?.textFields?.first?.text ?? "") else { return }
            Task { await start(server, from: host) }
        })
        host.present(alert, animated: true)
    }

    private static func start(_ server: URL, from host: UIViewController) async {
        let code: Scrob.DeviceCode
        do {
            code = try await Scrob.startLink(server)
        } catch {
            tell(host, String(localized: "That address didn't answer as a Scrob server."))
            return
        }
        wait?.cancel()
        wait = Task {
            let linked = await Scrob.finishLink(server, code)
            guard !Task.isCancelled else { return }
            tell(host, linked ? String(localized: "Scrob is linked. Plays in the built-in player now go to it.")
                              : String(localized: "The code wasn't approved in time. Try again."))
        }
        let alert = UIAlertController(
            title: code.user_code,
            message: String(localized: "Approve this code on your Scrob server's link page. Open Scrob takes you there; come back to the app afterwards."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in wait?.cancel() })
        alert.addAction(UIAlertAction(title: String(localized: "Open Scrob"), style: .default) { _ in
            UIPasteboard.general.string = code.user_code
            if let url = URL(string: code.verification_uri_complete) { UIApplication.shared.open(url) }
        })
        host.present(alert, animated: true)
    }

    private static func tell(_ host: UIViewController, _ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        (host.presentedViewController ?? host).present(alert, animated: true)
    }
}
