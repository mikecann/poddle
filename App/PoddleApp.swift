import SwiftUI
import PoddleKit
#if canImport(ChefKit)
import ChefKit
#endif

@main
struct PoddleApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var store: PoddleStore
    @State private var app: AppModel
    @State private var push: PushCoordinator
    /// Who's signed in. Nil on sample data, which needs nobody.
    @State private var account: Account?
    @Environment(\.scenePhase) private var scenePhase
    private let player: any PoddlePlayer

    /// Launch arguments are documented in the README ("Launch arguments").
    init() {
        let defaults = UserDefaults.standard
        #if DEBUG
        let screen = defaults.string(forKey: "PoddleScreen")
        // Sample data only when asked for: `-PoddleMock YES`, `-PoddleRealAudio YES`, or a screenshot run
        // without `-PoddleLive YES`. Otherwise it's LiveStore.
        let realAudio = defaults.bool(forKey: "PoddleRealAudio")
        let mock = defaults.bool(forKey: "PoddleMock") || realAudio || (screen != nil && !defaults.bool(forKey: "PoddleLive"))
        // Fake playback and downloads on screenshot runs, unless `-PoddleMockPlayer NO`; `-PoddleMockPlayer YES`
        // forces it on any launch. Otherwise the real engine plays.
        let fakePlayback = defaults.object(forKey: "PoddleMockPlayer") != nil ? defaults.bool(forKey: "PoddleMockPlayer") : screen != nil
        let autoplay = fakePlayback ? mock && defaults.string(forKey: "PoddlePaused") == nil : defaults.bool(forKey: "PoddleAutoplay")
        #else
        // Release (the App Store build): no sample data, screenshot or test hooks, just the real thing.
        let screen: String? = nil
        let realAudio = false
        let mock = false
        let fakePlayback = false
        let autoplay = false
        #endif

        let store: PoddleStore
        var account: Account?
        if mock {
            var seed = MockData.snapshot()
            if realAudio { seed = MockData.withRealAudio(seed) }
            store = MockStore.makeStore(seed: seed, downloads: fakePlayback ? MockData.downloads() : [:])
        } else {
            let live = Self.liveStore()
            store = live.store
            account = live.account
            Self.installChef(store)
        }
        let app = AppModel()
        app.isMock = mock
        let services = AppServices(store: store, app: app, fakePlayback: fakePlayback)
        let player = services.player

        if mock, let fake = player as? MockPlayer {
            fake.routeName = "Kitchen"
            fake.load(MockData.playingEpisodeId, position: nil, smartSaved: 252)
        } else if let head = store.queue.first {
            // Restore what was playing, paused at its saved position.
            player.load(head.id)
        }
        if let screen { app.applyLaunchScreen(screen, player: player, store: store) }
        // `-PoddleScreen signIn`: the signed-out screen, with a throwaway session store so nothing
        // real is touched.
        if screen == "signIn" {
            account = Account(config: LiveConfig(deploymentURL: URL(string: "https://unconfigured.convex.cloud")!), store: MemorySessionStore())
        }
        if autoplay {
            player.resume()
        }
        #if DEBUG
        AudioCheck.run(services)
        #endif

        _store = State(initialValue: store)
        _app = State(initialValue: app)
        _push = State(initialValue: services.push)
        _account = State(initialValue: account)
        self.player = player
    }

    /// The Convex-backed store for whoever's signed in, seeded from their on-disk cache so the
    /// first frame has data (offline too). Signed out, it's empty until someone signs in.
    private static func liveStore() -> (store: PoddleStore, account: Account) {
        var config = LiveConfigStore.bundled()
            ?? LiveConfig(deploymentURL: URL(string: "https://unconfigured.convex.cloud")!)
        #if DEBUG
        // `-PoddleConvexURL <url>` (with `-PoddleSiteURL <url>`): any backend, e.g. the e2e suite's local one.
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "PoddleConvexURL"),
           let url = URL(string: raw), url.host() != nil {
            config = LiveConfig(deploymentURL: url, siteURL: defaults.string(forKey: "PoddleSiteURL").flatMap(URL.init(string:)))
        }
        // `-PoddleResetState YES`: start as a fresh install on this backend (the e2e suite, before every scenario).
        if defaults.bool(forKey: "PoddleResetState") { resetForTests(config) }
        #endif
        let account = Account(config: config)
        let disk = account.userId.map { LiveDisk.forUser($0, deployment: config.deploymentURL) }
        if let disk { LiveDisk.adoptPreAccountFiles(deployment: config.deploymentURL, into: disk) }
        let live = LiveStore(
            deploymentURL: config.deploymentURL, deviceId: LiveConfigStore.deviceId(),
            userId: account.userId, auth: account.isSignedIn ? account : nil
        )
        let store = PoddleStore(dataSource: live, seed: LiveStore.cachedSnapshot(disk: disk), deviceId: live.deviceId)
        return (store, account)
    }

    #if DEBUG
    /// Everything a fresh install wouldn't have: the session, every cache and outbox, downloads,
    /// pending listening sessions, artwork thumbnails and saved preferences. Launch arguments stay.
    private static func resetForTests(_ config: LiveConfig) {
        KeychainSessionStore(deployment: config).delete()
        let files = FileManager.default
        for dir in [URL.applicationSupportDirectory, URL.cachesDirectory] {
            for item in (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                try? files.removeItem(at: item)
            }
        }
        if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
    }
    #endif

    /// Someone signed in or out (or their session ran out). The player lets go, sessions still
    /// waiting go into the previous person's outbox, then everything switches to the new person.
    private func accountChanged(to userId: String?) async {
        guard let account, let live = store.dataSource as? LiveStore, await live.userId != userId else { return }
        player.unload()
        // Let the closing listening segment reach the forwarder, then hand it to the old outbox.
        try? await Task.sleep(for: .milliseconds(300))
        await AppServices.current?.sessions?.flush()
        await live.flush()
        let disk = userId.map { LiveDisk.forUser($0, deployment: account.config.deploymentURL) }
        if let disk { LiveDisk.adoptPreAccountFiles(deployment: account.config.deploymentURL, into: disk) }
        await live.switchAccount(userId: userId, auth: userId == nil ? nil : account)
        // They deleted their account: nothing of theirs stays on this device.
        if let gone = app.wipeAfterSignOut {
            app.wipeAfterSignOut = nil
            LiveDisk.forUser(gone, deployment: account.config.deploymentURL).erase()
            AppServices.current?.downloads?.removeAll()
            ArtworkThumbnails.shared.removeAll()
        }
        store.resetForAccountChange(seed: LiveStore.cachedSnapshot(disk: disk))
        app.paths = [:]
        app.tab = .upNext
        Self.installChef(store)
        if userId != nil {
            push.registerAgain()
            if let head = store.queue.first { player.load(head.id) }
        }
    }

    /// Chef (Seth's feedback board) on Poddle's own connection, as whoever's signed in. Settings
    /// opens it ("Suggest a feature"); its floating button stays hidden. iOS only. Called again
    /// after an account change, so Chef asks again as the new person and sends what's waiting.
    private static func installChef(_ store: PoddleStore) {
        #if canImport(ChefKit)
        guard let live = store.dataSource as? LiveStore else { return }
        ChefKit.isHidden = true
        ChefKit.install(client: ChefConnection(live: live))
        ChefKit.retryPending()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let account, !account.isSignedIn {
                    SignInView()
                } else {
                    RootView()
                }
            }
                .environment(store)
                .environment(\.player, player)
                .environment(app)
                .environment(push)
                .environment(account)
                .preferredColorScheme(Self.forcedScheme)
                .tint(Palette.tomato)
                .onChange(of: account?.userId) { _, userId in Task { await accountChanged(to: userId) } }
                // Share links from the website (universal links) and its poddle:// "Open in Poddle" button.
                .onOpenURL { url in app.open(url, store: store) }
                .alert("Couldn't open that link", isPresented: $app.linkNotFound) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("That episode or show isn't available. It may be from a private feed.")
                }
                #if DEBUG
                // `-PoddleSignOut YES`: signs out at launch, the same way Settings does (for unattended checks).
                .task { if UserDefaults.standard.bool(forKey: "PoddleSignOut") { await account?.signOut() } }
                // `-PoddleOpenURL <url>`: opens a share link at launch, as if tapped (for unattended checks).
                .task {
                    guard let raw = UserDefaults.standard.string(forKey: "PoddleOpenURL"), let url = URL(string: raw) else { return }
                    try? await Task.sleep(for: .seconds(3))
                    app.open(url, store: store)
                }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    // Foreground: ask Convex to re-check feeds not checked in the last 2 minutes.
                    case .active: if account?.isSignedIn != false { Task { await store.refresh() } }
                    case .background:
                        if let live = store.dataSource as? LiveStore { Task { await live.flush() } }
                        #if os(iOS)
                        BackgroundRefresh.schedule()
                        #endif
                    default: break
                    }
                }
        }
        #if os(iOS)
        // Syncs and downloads new episodes while Poddle's closed (BackgroundRefresh).
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { await BackgroundRefresh.run() }
        #endif
        #if os(macOS)
        .defaultSize(width: 1100, height: 780)
        .commands { PlaybackCommands(player: player, store: store) }
        #endif
    }

    /// `-PoddleAppearance dark|light` for screenshots.
    static var forcedScheme: ColorScheme? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "PoddleAppearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
        #else
        nil
        #endif
    }
}

#if os(macOS)
/// Space to play or pause, arrows to skip (spec §2.6, Mac and iPad).
struct PlaybackCommands: Commands {
    var player: any PoddlePlayer
    var store: PoddleStore
    var body: some Commands {
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Skip Back") { player.skipBackTapped() }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Skip Forward") { player.skipForwardTapped() }.keyboardShortcut(.rightArrow, modifiers: [])
            Divider()
            Button("Next Chapter") { player.nextChapter() }.keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Previous Chapter") { player.previousChapter() }.keyboardShortcut(.leftArrow, modifiers: [.command])
        }
    }
}
#endif
