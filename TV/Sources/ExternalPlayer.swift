import SwiftUI
import UIKit

/// Khan AIOStreams: the player a title plays in on this Apple TV, the app's own or another app.
/// Kept on this device, as the web app keeps its own external player choice in the browser.
enum ExternalPlayer: String, CaseIterable {
    case builtIn = "", infuse, vlc

    static let key = "khan.externalPlayer"
    private static let maxSubtitles = 10
    private static let imageSubtitleCodecs: Set<String> = ["pgssub", "hdmv_pgs_subtitle", "dvd_subtitle", "dvdsub", "vobsub", "dvb_subtitle"]
    @MainActor private(set) static var launchedExternally = false

    /// Infuse by default: it plays the stream and scrobbles to Trakt itself.
    static var current: ExternalPlayer {
        get {
            guard let saved = UserDefaults.standard.string(forKey: key) else { return .infuse }
            return ExternalPlayer(rawValue: saved) ?? .infuse
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    @MainActor static func consumeExternalReturn() -> Bool {
        guard launchedExternally else { return false }
        launchedExternally = false
        return true
    }

    var label: String {
        switch self {
        case .builtIn: return L("Built-in player")
        case .infuse: return "Infuse"
        case .vlc: return "VLC"
        }
    }

    /// Whether a request goes to this player rather than the app's own. Trailers, live channels,
    /// watch parties and versions that need their own request headers stay in the app.
    func takes(_ request: PlayRequest) -> Bool {
        guard self != .builtIn, !request.isTrailer, !request.item.isChannel, request.partyEntry == nil else { return false }
        if let headers = request.source.requiredHttpHeaders, !headers.isEmpty { return false }
        return true
    }

    /// External text subtitle URLs ordered by the user's preferred subtitle languages, matching the web app.
    private static func subtitleURLs(for source: MediaSource, client: JellyfinClient, languages: [String], mode: String) -> [URL] {
        guard mode != "None" else { return [] }
        let externals = (source.mediaStreams ?? []).filter { stream in
            guard stream.type == "Subtitle", let delivery = stream.deliveryUrl, !delivery.isEmpty else { return false }
            if let codec = stream.codec?.lowercased(), imageSubtitleCodecs.contains(codec) { return false }
            return true
        }
        guard !externals.isEmpty else { return [] }
        let ordered: [MediaStream]
        if languages.isEmpty {
            ordered = externals
        } else {
            let ranked = externals.sorted { a, b in
                let ai = languages.firstIndex { LanguageCodes.same($0, a.language) } ?? languages.count
                let bi = languages.firstIndex { LanguageCodes.same($0, b.language) } ?? languages.count
                return ai < bi
            }
            let matching = ranked.filter { stream in languages.contains { LanguageCodes.same($0, stream.language) } }
            ordered = matching.isEmpty ? ranked : matching
        }
        return ordered.prefix(maxSubtitles).compactMap { $0.deliveryUrl.flatMap { client.absolute($0) } }
    }

    /// The link that opens the stream in this player, from the request's start.
    func link(for request: PlayRequest, client: JellyfinClient, subtitleLanguages: [String] = [], subtitleMode: String = "Default") -> URL? {
        guard let stream = client.streamURL(itemId: request.item.id, source: request.source) else { return nil }
        switch self {
        case .builtIn:
            return nil
        case .infuse:
            var parts = URLComponents()
            parts.scheme = "infuse"
            parts.host = "x-callback-url"
            parts.path = "/play"
            let returnLink = "aiostreams://return?played=\(request.item.id)&source=\(request.source.ownId)"
            var query = [
                URLQueryItem(name: "url", value: stream.absoluteString),
                URLQueryItem(name: "filename", value: Self.filename(request.item)),
                URLQueryItem(name: "x-success", value: returnLink),
                URLQueryItem(name: "x-error", value: "aiostreams://return"),
            ]
            for sub in Self.subtitleURLs(for: request.source, client: client, languages: subtitleLanguages, mode: subtitleMode) {
                query.append(URLQueryItem(name: "sub", value: sub.absoluteString))
            }
            if let start = request.startMs, start > 0 {
                query.append(URLQueryItem(name: "position", value: String(Int(start / 1000))))
            }
            parts.queryItems = query
            return Self.encodingValues(parts)
        case .vlc:
            var parts = URLComponents()
            parts.scheme = "vlc-x-callback"
            parts.host = "x-callback-url"
            parts.path = "/stream"
            parts.queryItems = [URLQueryItem(name: "url", value: stream.absoluteString)]
            return Self.encodingValues(parts)
        }
    }

    /// Encodes each query value whole, so a stream address's own query survives the trip.
    private static func encodingValues(_ parts: URLComponents) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/:")
        var copy = parts
        copy.percentEncodedQuery = (parts.queryItems ?? []).map { item in
            "\(item.name)=\((item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return copy.url
    }

    /// A name Infuse can match to its own metadata: "Show S01E02" or "Film (2024)".
    static func filename(_ item: Item) -> String {
        if item.isEpisode, let show = item.seriesName {
            return [show, item.episodeCode].compactMap { $0 }.joined(separator: " ")
        }
        let name = item.name ?? "Video"
        return item.productionYear.map { "\(name) (\($0))" } ?? name
    }

    /// Opens the request in this player, telling the server it started so it shows in Continue
    /// Watching. Returns false where the player can't take it, for the app's own to play instead.
    @MainActor
    func open(_ request: PlayRequest, client: JellyfinClient, subtitleLanguages: [String] = [], subtitleMode: String = "Default") async -> Bool {
        guard takes(request), let url = link(for: request, client: client, subtitleLanguages: subtitleLanguages, subtitleMode: subtitleMode) else { return false }
        guard await UIApplication.shared.open(url) else {
            AppLog.warn("player", "\(label) did not open")
            return false
        }
        Self.launchedExternally = true
        var body: [String: Any] = [
            "ItemId": request.item.id,
            "MediaSourceId": request.source.ownId,
            "PositionTicks": Int64((request.startMs ?? 0) * JellyfinClient.ticksPerMs),
            "IsPaused": false,
            "CanSeek": true,
            "PlayMethod": "DirectPlay",
        ]
        if let session = request.playSessionId { body["PlaySessionId"] = session }
        await client.fire("/Sessions/Playing", body: body)
        return true
    }
}
