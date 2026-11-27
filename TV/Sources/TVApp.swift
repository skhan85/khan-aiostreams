import AVFoundation
import SwiftUI

@main
struct AIOStreamsTVApp: App {
    @StateObject private var session = Session()
    @StateObject private var prefs = Preferences()
    @StateObject private var wash = ArtWash()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        AppLog.info("app", "started \(AppInfo.version) on \(AppInfo.deviceModel) tvOS \(UIDevice.current.systemVersion)")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch session.stage {
                case .needsServer: ServerView()
                case .needsSignIn: SignInView()
                case .signedIn:
                    if session.asking { SignInView() } else { MainView() }
                }
            }
            // The web app's theme colours and language, once they've loaded.
            .id(prefs.themeKey)
            .environment(\.locale, AppLanguage.locale)
            .environment(\.layoutDirection, AppLanguage.rightToLeft ? .rightToLeft : .leftToRight)
            .environmentObject(session)
            .environmentObject(prefs)
            .environmentObject(wash)
            .preferredColorScheme(.dark)
            // Screenshot mode only: the demo server's sign-in.
            .task { await DemoMode.start(session) }
            // From Top Shelf: a title's page, or playing it.
            .onOpenURL { DeepLink.open($0) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { session.left() } else if phase == .active { session.returned() }
                if phase == .active { ScreenFit.apply() }
            }
            .onAppear { ScreenFit.apply() }
            .tint(Theme.ring)
        }
    }
}

/// A message under a screen, for what went wrong.
struct ErrorText: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                .multilineTextAlignment(.center)
        }
    }
}

/// The sign-in screens' backdrop: the page's black with a faint glow from the top.
struct WelcomeBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(
                colors: [Color(red: 30 / 255, green: 32 / 255, blue: 70 / 255).opacity(0.8), .clear],
                center: .top,
                startRadius: 0,
                endRadius: Theme.px(620)
            )
        }
        .ignoresSafeArea()
    }
}

struct ServerView: View {
    @EnvironmentObject private var session: Session
    /// Khan AIOStreams: starts with the address the build was given (the KHAN_DEFAULT_SERVER secret).
    @State private var address = (Bundle.main.object(forInfoDictionaryKey: "KhanDefaultServer") as? String)?
        .trimmingCharacters(in: .whitespaces) ?? ""
    @State private var working = false
    @State private var error: String?

    private var recentServers: [Session.SavedServer] { Session.serverHistory }

    var body: some View {
        ZStack {
            WelcomeBackground()
            VStack(spacing: Theme.px(24)) {
                BrandLogo(height: Theme.px(64))
                Text(L("Connect to your server"))
                    .font(Theme.font(Theme.xl2, .semibold))
                    .foregroundStyle(Theme.gray200)
                Text(L("Use the address from your configure page: Save & Install → Jellyfin apps → Connect. With a share alias it's short, like your-instance/jellyfin/u/alias."))
                    .font(Theme.font(Theme.sm))
                    .foregroundStyle(Theme.gray400)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: Theme.px(560))
                TextField(L("Server address"), text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(Theme.font(Theme.base))
                    .frame(maxWidth: Theme.px(560))
                    .onSubmit(connect)
                Button(working ? L("Connecting…") : L("Connect"), action: connect)
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty)
                if !recentServers.isEmpty {
                    VStack(spacing: Theme.px(10)) {
                        Text(L("Recent servers"))
                            .font(Theme.font(Theme.xs, .semibold))
                            .foregroundStyle(Theme.gray400)
                        HStack(spacing: Theme.px(12)) {
                            ForEach(recentServers.prefix(3)) { saved in
                                Button(saved.name ?? URL(string: saved.address)?.host ?? saved.address) {
                                    address = saved.address
                                    connect()
                                }
                                .buttonStyle(SoftPillStyle())
                                .disabled(working)
                            }
                        }
                    }
                    .padding(.top, Theme.px(8))
                }
                ErrorText(text: error)
            }
            .foregroundStyle(.white)
        }
    }

    private func connect() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                try await session.connect(to: address)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// "Who's watching?", as the web app asks on a TV: the configuration's users, then a password
/// where one is set; or Quick Connect, or a name typed in.
struct SignInView: View {
    private enum Mode: Equatable {
        case pick
        case password(PublicUser)
        case manual
        case quickConnect
    }

    @EnvironmentObject private var session: Session
    @State private var mode: Mode = .pick
    @State private var users: [PublicUser] = []
    @State private var loaded = false
    @State private var quickConnectEnabled = false
    @State private var code: String?
    @State private var name = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    private var recentServers: [Session.SavedServer] { Session.serverHistory }
    @State private var poll: Task<Void, Never>?

    var body: some View {
        ZStack {
            WelcomeBackground()
            VStack(spacing: Theme.px(28)) {
                BrandLogo(height: Theme.px(64))
                switch mode {
                case .pick: picker
                case .password(let user): passwordForm(user)
                case .manual: manualForm
                case .quickConnect: quickConnectPanel
                }
                ErrorText(text: error)
            }
            .foregroundStyle(.white)
        }
        .task { await load() }
        .onDisappear { poll?.cancel() }
        .onChange(of: mode) { _, mode in
            error = nil
            if mode == .quickConnect { startQuickConnect() } else { poll?.cancel() }
        }
        .onExitCommand(perform: mode == .pick ? nil : { mode = .pick })
    }

    private var picker: some View {
        VStack(spacing: Theme.px(28)) {
            Text(users.isEmpty && loaded ? L("Sign in") : L("Who's watching?"))
                .font(Theme.font(Theme.xl2, .semibold))
                .foregroundStyle(Theme.gray200)
            if !users.isEmpty {
                // Five to a row, as the web app lays out a long list; past two rows they scroll.
                let rows = stride(from: 0, to: users.count, by: Self.perRow).map {
                    Array(users[$0..<min($0 + Self.perRow, users.count)])
                }
                let grid = VStack(spacing: Theme.px(28)) {
                    ForEach(rows.indices, id: \.self) { row in
                        HStack(spacing: Theme.px(40)) {
                            ForEach(rows[row]) { user in avatarButton(user) }
                        }
                    }
                }
                .padding(.vertical, Theme.px(12))
                Group {
                    if rows.count > 2 {
                        ScrollView { grid.frame(maxWidth: .infinity) }
                            .scrollClipDisabled()
                            .frame(maxHeight: Theme.px(310))
                    } else {
                        grid
                    }
                }
                .focusSection()
            } else if !loaded {
                ProgressView()
            }
            HStack(spacing: Theme.px(8)) {
                Button(L("Other user")) { name = ""; password = ""; mode = .manual }
                if quickConnectEnabled { Button(L("Quick Connect")) { mode = .quickConnect } }
                Button(L("Change server")) { session.forgetServer() }
            }
            .buttonStyle(SoftPillStyle())
            .padding(.top, Theme.px(8))
            .focusSection()
        }
    }

    private static let perRow = 5

    private func avatarButton(_ user: PublicUser) -> some View {
        Button {
            // Asked who's watching, whoever was carries on as they were.
            if session.asking && user.id == session.userId { session.carryOn(); return }
            name = user.name ?? ""
            password = ""
            // Signed in already: another profile is entered through this session, which needs
            // no password, only a PIN where the profile has one.
            if session.asking { switchProfile(user); return }
            if user.hasPassword == false { signIn() } else { mode = .password(user) }
        } label: {
            UserAvatar(user: user, url: avatarURL(user))
        }
        .buttonStyle(AvatarStyle())
    }

    private func passwordForm(_ user: PublicUser) -> some View {
        VStack(spacing: Theme.px(20)) {
            UserAvatar(user: user, url: avatarURL(user))
            Text(L("Password for %@", user.name ?? L("this user")))
                .font(Theme.font(Theme.xl, .semibold))
                .foregroundStyle(Theme.gray200)
            Text(L("If the user has a PIN, add it after the password with a /, like password/1234."))
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Theme.gray400)
            SecureField(L("Password"), text: $password)
                .font(Theme.font(Theme.base))
                .frame(maxWidth: Theme.px(440))
                .onSubmit(signIn)
            HStack(spacing: Theme.px(12)) {
                Button(working ? L("Signing in…") : L("Sign in"), action: signIn)
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(working)
                Button(L("Back")) { mode = .pick }.buttonStyle(SecondaryPillStyle())
            }
        }
    }

    private var manualForm: some View {
        VStack(spacing: Theme.px(20)) {
            Text(L("Sign in"))
                .font(Theme.font(Theme.xl2, .semibold))
                .foregroundStyle(Theme.gray200)
            TextField(L("Name"), text: $name)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(Theme.font(Theme.base))
                .frame(maxWidth: Theme.px(440))
            SecureField(L("Password, and /PIN if the user has one"), text: $password)
                .font(Theme.font(Theme.base))
                .frame(maxWidth: Theme.px(440))
                .onSubmit(signIn)
            HStack(spacing: Theme.px(12)) {
                Button(working ? L("Signing in…") : L("Sign in"), action: signIn)
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(working || name.isEmpty)
                Button(L("Back")) { mode = .pick }.buttonStyle(SecondaryPillStyle())
            }
        }
    }

    private var quickConnectPanel: some View {
        VStack(spacing: Theme.px(20)) {
            Text(L("Quick Connect"))
                .font(Theme.font(Theme.xl2, .semibold))
                .foregroundStyle(Theme.gray200)
            if let code {
                Text(code)
                    .font(Theme.font(64, .bold))
                    .monospacedDigit()
                    .kerning(Theme.px(8))
            } else {
                ProgressView().frame(height: Theme.px(80))
            }
            Text(L("On your configure page, open Save & Install → Jellyfin apps → Connect, type this code into the Quick Connect box and approve it."))
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Theme.gray400)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Theme.px(560))
            Button(L("Back")) { mode = .pick }.buttonStyle(SoftPillStyle())
        }
    }

    private func avatarURL(_ user: PublicUser) -> URL? {
        guard let client = session.client, let tag = user.primaryImageTag else { return nil }
        return client.url("/Users/\(user.id)/Images/Primary", ["tag": tag, "fillHeight": "240", "quality": "90"])
    }

    private func load() async {
        guard let client = session.client else { return }
        // A picker address lists its users, as a Jellyfin server does.
        users = (try? await client.get("/Users/Public") as [PublicUser]) ?? []
        quickConnectEnabled = (try? await client.get("/QuickConnect/Enabled") as Bool) ?? false
        loaded = true
        if users.isEmpty { mode = quickConnectEnabled ? .quickConnect : .manual }
    }

    private func startQuickConnect() {
        guard let client = session.client else { return }
        poll?.cancel()
        code = nil
        poll = Task {
            do {
                let started: QuickConnectState = try await client.post("/QuickConnect/Initiate")
                code = started.code
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(4))
                    let state: QuickConnectState = try await client.get("/QuickConnect/Connect", ["Secret": started.secret])
                    if state.authenticated == true {
                        let result: AuthResult = try await client.post(
                            "/Users/AuthenticateWithQuickConnect",
                            body: ["Secret": started.secret]
                        )
                        session.signIn(result)
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                // A code lasts a few minutes; a new one replaces it.
                if !Task.isCancelled {
                    AppLog.info("signin", "quick connect: \(error.localizedDescription)")
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled, mode == .quickConnect { startQuickConnect() }
                }
            }
        }
    }

    /// The web app's profile switch: a token for `user` from the session this Apple TV has. A
    /// profile with a PIN refuses it without one, so its form asks, and the form's answer is
    /// tried this way first (`signIn`). A server that can't switch this way leaves the password.
    private func switchProfile(_ user: PublicUser) {
        guard let client = session.client, client.token != nil, !working else {
            mode = .password(user)
            return
        }
        working = true
        error = nil
        Task {
            if let result = await profileToken(client, user.id, pin: nil) {
                session.signIn(result)
            } else {
                mode = .password(user)
            }
            working = false
        }
    }

    private func profileToken(_ client: JellyfinClient, _ userId: String, pin: String?) async -> AuthResult? {
        guard client.token != nil else { return nil }
        var body: [String: Any] = ["UserId": userId]
        if let pin, !pin.isEmpty { body["Pw"] = pin }
        return try? await client.post("/AIOStreams/Token", body: body) as AuthResult
    }

    private func signIn() {
        guard let client = session.client, !working, !name.isEmpty else { return }
        // Asked who's watching while signed in: the PIN through this session first.
        var asked: String?
        if session.asking, case .password(let user) = mode { asked = user.id }
        let switching = asked
        working = true
        error = nil
        Task {
            if let switching, let result = await profileToken(client, switching, pin: password) {
                poll?.cancel()
                session.signIn(result)
                working = false
                return
            }
            do {
                let result: AuthResult = try await client.post(
                    "/Users/AuthenticateByName",
                    body: ["Username": name, "Pw": password]
                )
                poll?.cancel()
                session.signIn(result)
            } catch let failure as JellyfinError where failure.status == 401 {
                error = L("That password doesn't match.")
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// A user's picture, or their initial on a colour of their own, with their name under it.
struct UserAvatar: View {
    let user: PublicUser
    let url: URL?

    private static let colours: [Color] = [
        Color(red: 0.76, green: 0.71, blue: 0.89), Color(red: 0.72, green: 0.87, blue: 0.95),
        Color(red: 1.0, green: 0.85, blue: 0.88), Color(red: 0.82, green: 0.95, blue: 0.84),
        Color(red: 0.99, green: 0.89, blue: 0.72),
    ]

    var body: some View {
        VStack(spacing: Theme.px(12)) {
            ZStack {
                Circle().fill(Self.colours[user.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.colours.count])
                Text(String((user.name ?? "?").prefix(1)).uppercased())
                    .font(Theme.font(44, .bold))
                    .foregroundStyle(.black.opacity(0.75))
                if let url {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fill) }
                    }
                }
            }
            .frame(width: Theme.px(112), height: Theme.px(112))
            .clipShape(Circle())
            Text(user.name ?? L("User"))
                .font(Theme.font(15))
                .foregroundStyle(Theme.gray200)
        }
    }
}

/// The ring goes round the picture alone, not its name.
private struct AvatarStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AvatarFocus(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct AvatarFocus<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label
        let pressed: Bool

        var body: some View {
            label
                .overlay(alignment: .top) {
                    if focused {
                        Circle()
                            .stroke(Theme.ring, lineWidth: Theme.ringWidth)
                            .frame(width: Theme.px(112) + 2 * Theme.ringOffset + Theme.ringWidth,
                                   height: Theme.px(112) + 2 * Theme.ringOffset + Theme.ringWidth)
                            .offset(y: -(Theme.ringOffset + Theme.ringWidth / 2))
                    }
                }
                .scaleEffect(focused ? 1.05 : 1)
                .opacity(pressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// A link into the app (`aiostreams://item/<id>`, `aiostreams://play/<id>`, or
/// `aiostreams://return?...` from Infuse), from Top Shelf or an external player.
enum DeepLink {
    struct ExternalReturn {
        let itemId: String?
        let sourceId: String?
        let positionMs: Double?
        let finished: Bool
    }

    static let opened = Notification.Name("aiostreams.deepLink")
    private(set) static var pending: URL?
    private(set) static var pendingReturn: ExternalReturn?

    static func open(_ url: URL) {
        if url.scheme == "aiostreams", url.host() == "return" {
            pendingReturn = parseReturn(url)
            NotificationCenter.default.post(name: opened, object: nil)
            return
        }
        pending = url
        NotificationCenter.default.post(name: opened, object: nil)
    }

    /// The link waiting, once: whether to play, and the title's id.
    static func take() -> (play: Bool, id: String)? {
        guard let url = pending, url.scheme == "aiostreams", let host = url.host(),
              ["item", "play"].contains(host), let id = url.pathComponents.dropFirst().first else { return nil }
        pending = nil
        return (host == "play", id)
    }

    static func takeReturn() -> ExternalReturn? {
        defer { pendingReturn = nil }
        return pendingReturn
    }

    private static func parseReturn(_ url: URL) -> ExternalReturn {
        // Players that append their own `?position=...` onto an `x-success` that already has `?`
        // create a second `?` in the query string; normalize extra `?` to `&`.
        var raw = url.absoluteString
        if let first = raw.firstIndex(of: "?") {
            let tail = raw[raw.index(after: first)...].replacingOccurrences(of: "?", with: "&")
            raw = String(raw[...first]) + tail
        }
        let items = URLComponents(string: raw)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let seconds = value("position").flatMap(Double.init)
        return ExternalReturn(
            itemId: value("played"),
            sourceId: value("source"),
            positionMs: seconds.map { $0 * 1000 },
            finished: value("finished") == "1"
        )
    }
}
