import SwiftUI

// Playlists, as the web app has them (features/playlists, lib/playlists.ts): the user's Jellyfin
// playlists, each one's titles to play in order or shuffled, and titles added from their menus.
// A title played from a playlist plays on into the rest of it.

/// The Jellyfin calls the playlist pages and the card menu make.
enum Playlists {
    static func all(client: JellyfinClient, userId: String) async -> [Item] {
        let result: ItemsResult? = try? await client.get("/Items", [
            "userId": userId, "IncludeItemTypes": "Playlist", "Recursive": "true", "SortBy": "SortName", "Fields": "ChildCount",
        ])
        return result?.items ?? []
    }

    static func entries(_ playlist: Item, client: JellyfinClient, userId: String) async -> [Item] {
        let result: ItemsResult? = try? await client.get("/Playlists/\(playlist.id)/Items", ["userId": userId, "Fields": "Overview"])
        return result?.items ?? []
    }

    /// A new playlist holding these titles.
    static func create(_ name: String, ids: [String], client: JellyfinClient, userId: String) async throws {
        _ = try await client.json("POST", "/Playlists", body: ["Name": name, "Ids": ids, "UserId": userId, "MediaType": "Video"])
    }

    /// Adds a title that isn't there yet (Jellyfin keeps one twice when it's added again); false
    /// when it was.
    static func add(_ id: String, to playlist: Item, client: JellyfinClient, userId: String) async throws -> Bool {
        let current = try await client.json("GET", "/Playlists/\(playlist.id)")
        let ids = (current["ItemIds"] as? [String] ?? []).map { $0.replacingOccurrences(of: "-", with: "").lowercased() }
        guard !ids.contains(id.replacingOccurrences(of: "-", with: "").lowercased()) else { return false }
        try await client.call("POST", "/Playlists/\(playlist.id)/Items", ["ids": id, "userId": userId])
        return true
    }

    static func remove(_ entry: Item, from playlist: Item, client: JellyfinClient) async throws {
        guard let entryId = entry.playlistItemId else { return }
        try await client.call("DELETE", "/Playlists/\(playlist.id)/Items", ["entryIds": entryId])
    }

    static func delete(_ playlist: Item, client: JellyfinClient) async throws {
        try await client.call("DELETE", "/Items/\(playlist.id)")
    }
}

/// The user's playlists, as cards that open each one.
struct PlaylistsView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.openRoute) private var openRoute
    @State private var playlists: [Item] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: Theme.px(260), maximum: Theme.px(260)), spacing: Theme.px(20))]

    var body: some View {
        ScrollView {
            PageTitle(text: L("Playlists"))
            if loaded && playlists.isEmpty {
                Text(L("Add titles to a playlist from their menu: hold Select on a title and choose Add to playlist."))
                    .font(Theme.font(Theme.base))
                    .foregroundStyle(Theme.gray400)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pagePadding()
                    .focusable()
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.px(24)) {
                ForEach(playlists) { playlist in
                    Button { openRoute(.playlist(playlist)) } label: { PlaylistCard(playlist: playlist) }
                        .buttonStyle(RowStyle(radius: Theme.px(12)))
                }
            }
            .pagePadding()
            .padding(.vertical, Theme.px(16))
        }
        .edgeToEdge()
        .task { await load() }
        .refreshOnReturn { await load() }
    }

    private func load() async {
        guard let client = session.client, let userId = session.userId else { return }
        playlists = await Playlists.all(client: client, userId: userId)
        loaded = true
    }
}

/// A playlist's picture, name and how many titles it holds.
private struct PlaylistCard: View {
    @EnvironmentObject private var session: Session
    let playlist: Item

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.px(10), style: .continuous).fill(Color.white.opacity(0.06))
                Image(systemName: "list.bullet.rectangle.portrait").font(.system(size: Theme.px(36))).foregroundStyle(Theme.gray500)
                RemoteImage(url: session.client?.poster(playlist, height: 480))
            }
            .frame(width: Theme.px(260), height: Theme.px(146))
            .clipShape(RoundedRectangle(cornerRadius: Theme.px(10), style: .continuous))
            Text(playlist.name ?? "").font(Theme.font(Theme.base, .semibold)).lineLimit(1)
            if let count = playlist.childCount {
                Text(L("%ld titles", count)).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400)
            }
        }
        .padding(Theme.px(8))
    }
}

/// One playlist: Play, Shuffle and its titles in order; titles can be taken out, and the playlist
/// deleted.
struct PlaylistView: View {
    let playlist: Item
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Item] = []
    @State private var loaded = false
    @State private var choice: VersionChoice?
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.px(16)) {
                PageTitle(text: playlist.name ?? L("Playlist"))
                HStack(spacing: Theme.px(8)) {
                    Button { play(entries) } label: { Label(L("Play"), systemImage: "play.fill") }
                        .buttonStyle(SoftPillStyle(selected: true))
                    Button { play(entries.shuffled()) } label: { Label(L("Shuffle"), systemImage: "shuffle") }
                        .buttonStyle(SoftPillStyle())
                    Button { confirmDelete = true } label: { Label(L("Delete playlist"), systemImage: "trash") }
                        .buttonStyle(SoftPillStyle())
                }
                .disabled(entries.isEmpty && !loaded)
                .pagePadding()
                .focusSection()
                if loaded && entries.isEmpty {
                    Text(L("Nothing in this playlist yet."))
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray400)
                        .pagePadding()
                }
                PosterGrid(items: entries)
                    .environment(\.removeFromPlaylist, { entry in Task { await remove(entry) } })
            }
        }
        .edgeToEdge()
        .task { await load() }
        .refreshOnReturn { await load() }
        .playFlow($choice)
        .alert(L("Delete this playlist?"), isPresented: $confirmDelete) {
            Button(L("Delete playlist"), role: .destructive) { Task { await deletePlaylist() } }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    /// The first title, with the rest after it.
    private func play(_ list: [Item]) {
        let playable = list.filter { $0.playable && $0.locationType != "Virtual" }
        guard let first = playable.first else { return }
        choice = VersionChoice(item: first, startMs: first.resumeMs, queue: Array(playable.dropFirst()))
    }

    private func load() async {
        guard let client = session.client, let userId = session.userId else { return }
        entries = await Playlists.entries(playlist, client: client, userId: userId)
        loaded = true
    }

    private func remove(_ entry: Item) async {
        guard let client = session.client else { return }
        try? await Playlists.remove(entry, from: playlist, client: client)
        await load()
    }

    private func deletePlaylist() async {
        guard let client = session.client else { return }
        try? await Playlists.delete(playlist, client: client)
        dismiss()
    }
}

/// Inside a playlist's page, a title's menu can take it out of the playlist.
private struct RemoveFromPlaylistKey: EnvironmentKey {
    static let defaultValue: ((Item) -> Void)? = nil
}

extension EnvironmentValues {
    var removeFromPlaylist: ((Item) -> Void)? {
        get { self[RemoveFromPlaylistKey.self] }
        set { self[RemoveFromPlaylistKey.self] = newValue }
    }
}

/// Adds a title to a playlist, or to a new one, from its menu.
struct AddToPlaylist: View {
    let item: Item
    let done: () -> Void
    @EnvironmentObject private var session: Session
    @State private var playlists: [Item] = []
    @State private var naming = false
    @State private var name = ""
    @State private var result: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.px(12)) {
                Text(L("Add to playlist")).font(Theme.font(Theme.xl, .semibold))
                Text(item.isEpisode ? item.displayTitle : item.name ?? "").font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400)
                if let result {
                    Text(result).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray300)
                }
                ScrollView {
                    VStack(spacing: Theme.px(4)) {
                        Button { naming = true } label: {
                            Label(L("New playlist"), systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.px(14)).frame(height: Theme.px(44))
                        }
                        .buttonStyle(RowStyle(radius: Theme.px(8)))
                        ForEach(playlists) { playlist in
                            Button { Task { await add(to: playlist) } } label: {
                                Text(playlist.name ?? "").frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Theme.px(14)).frame(height: Theme.px(44))
                            }
                            .buttonStyle(RowStyle(radius: Theme.px(8)))
                        }
                    }
                    .padding(Theme.px(8))
                }
                .scrollClipDisabled()
            }
            .padding(Theme.px(20))
            .frame(width: Theme.px(480))
            .frame(maxHeight: Theme.px(600))
            .background(GlassBackground(shape: RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous),
                                        fill: Color(white: 17 / 255), panel: true))
            .overlay(RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous).stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
        }
        .foregroundStyle(.white)
        .onExitCommand(perform: done)
        .task {
            guard let client = session.client, let userId = session.userId else { return }
            playlists = await Playlists.all(client: client, userId: userId)
        }
        .alert(L("New playlist"), isPresented: $naming) {
            TextField(L("Name"), text: $name)
            Button(L("Create")) { Task { await create() } }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    private func add(to playlist: Item) async {
        guard let client = session.client, let userId = session.userId else { return }
        do {
            let added = try await Playlists.add(item.id, to: playlist, client: client, userId: userId)
            result = added ? L("Added to %@", playlist.name ?? "") : L("Already in %@", playlist.name ?? "")
            if added { try? await Task.sleep(for: .milliseconds(700)); done() }
        } catch {
            result = error.localizedDescription
        }
    }

    private func create() async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = session.client, let userId = session.userId else { return }
        do {
            try await Playlists.create(name, ids: [item.id], client: client, userId: userId)
            result = L("Added to %@", name)
            try? await Task.sleep(for: .milliseconds(700))
            done()
        } catch {
            result = error.localizedDescription
        }
    }
}
