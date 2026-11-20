import SwiftUI

// Background from artwork, after the web app's (components/shell/art-wash.tsx): with it on, the whole
// app's background is the art of the title you're on, blurred and darkened, fading from one title to
// the next. The hero's title sets it on Home, a title's page on its page, and the version list.

@MainActor
final class ArtWash: ObservableObject {
    /// The title whose art the background is, the last one set.
    @Published private(set) var item: Item?
    /// The kind of page on screen, as the web app's `artPageOf`: `item` (a title's page), `browse`
    /// (Home, Discover, a library, Search, Favourites, a person, Live TV) or `other`.
    @Published var page = "browse"

    func show(_ next: Item) {
        guard next.id != item?.id else { return }
        item = next
    }
}

/// The background behind every page: the wash where it's on and set, else the page colour.
struct WashBackground: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var wash: ArtWash

    var body: some View {
        ZStack {
            Theme.background
            if prefs.artPages.contains(wash.page), let item = wash.item {
                RemoteImage(url: session.client?.backdrop(item, height: 360) ?? session.client?.still(item, height: 360))
                    .blur(radius: Theme.px(40), opaque: true)
                    .overlay(Color.black.opacity(0.4))
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.6), value: wash.item?.id)
        .ignoresSafeArea()
    }
}

extension View {
    /// The kind of page this is, for which pages the background from artwork shows behind.
    func artPage(_ page: String) -> some View {
        modifier(ArtPageKind(page: page))
    }

    /// The kind of page a panel over the page counts as while it's open.
    func artPageOver(_ page: String) -> some View {
        modifier(ArtPageOver(page: page))
    }

    /// Makes `item` the background from artwork while this view shows.
    func washed(by item: Item) -> some View {
        modifier(Washed(item: item))
    }
}

private struct Washed: ViewModifier {
    @EnvironmentObject private var wash: ArtWash
    let item: Item

    func body(content: Content) -> some View {
        content
            .onAppear { wash.show(item) }
            .onChange(of: item.id) { _, _ in wash.show(item) }
    }
}

private struct ArtPageKind: ViewModifier {
    @EnvironmentObject private var wash: ArtWash
    let page: String

    func body(content: Content) -> some View {
        content.onAppear { wash.page = page }
    }
}

/// A panel over the page, such as the version list, which shows the background from artwork as
/// title pages do, and hands the page beneath its own kind back as it closes.
private struct ArtPageOver: ViewModifier {
    @EnvironmentObject private var wash: ArtWash
    let page: String
    @State private var beneath: String?

    func body(content: Content) -> some View {
        content
            .onAppear {
                beneath = wash.page
                wash.page = page
            }
            .onDisappear { if let beneath { wash.page = beneath } }
    }
}
