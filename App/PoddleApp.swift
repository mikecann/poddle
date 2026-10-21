import SwiftUI
import PoddleKit

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
    @Environment(\.scenePhase) private var scenePhase
    private let player: any PoddlePlayer

    /// Launch arguments are documented in the README ("Launch arguments").
    init() {
        let defaults = UserDefaults.standard
        let screen = defaults.string(forKey: "PoddleScreen")
        // Sample data only when asked for: `-PoddleMock YES`, `-PoddleRealAudio YES`, or a screenshot run
        // without `-PoddleLive YES`. Otherwise it's LiveStore.
        let realAudio = defaults.bool(forKey: "PoddleRealAudio")
        let mock = defaults.bool(forKey: "PoddleMock") || realAudio || (screen != nil && !defaults.bool(forKey: "PoddleLive"))
        // Fake playback and downloads on screenshot runs, unless `-PoddleMockPlayer NO`; `-PoddleMockPlayer YES`
        // forces it on any launch. Otherwise the real engine plays.
        let fakePlayback = defaults.object(forKey: "PoddleMockPlayer") != nil ? defaults.bool(forKey: "PoddleMockPlayer") : screen != nil

        let store: PoddleStore
        if mock {
            var seed = MockData.snapshot()
            if realAudio { seed = MockData.withRealAudio(seed) }
            store = MockStore.makeStore(seed: seed, downloads: fakePlayback ? MockData.downloads() : [:])
        } else {
            store = Self.liveStore()
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
        if fakePlayback ? mock && defaults.string(forKey: "PoddlePaused") == nil : defaults.bool(forKey: "PoddleAutoplay") {
            player.resume()
        }
        #if DEBUG
        AudioCheck.run(services)
        #endif

        _store = State(initialValue: store)
        _app = State(initialValue: app)
        _push = State(initialValue: services.push)
        self.player = player
    }

    /// The Convex-backed store, seeded from the on-disk cache so the first frame has data.
    private static func liveStore() -> PoddleStore {
        // Built without Config/Secrets.xcconfig and nothing pasted in Settings yet: connect to
        // nothing and let the Settings "Connection" row fix it.
        let config = LiveConfigStore.resolve()
            ?? LiveConfig(deploymentURL: URL(string: "https://unconfigured.convex.cloud")!, token: "")
        let live = LiveStore(deploymentURL: config.deploymentURL, token: config.token, deviceId: LiveConfigStore.deviceId())
        let seed = LiveStore.cachedSnapshot(disk: .forDeployment(config.deploymentURL))
        return PoddleStore(dataSource: live, seed: seed, deviceId: live.deviceId)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(\.player, player)
                .environment(app)
                .environment(push)
                .preferredColorScheme(Self.forcedScheme)
                .tint(Palette.tomato)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    // Foreground: ask Convex to re-check feeds not checked in the last 2 minutes.
                    case .active: Task { await store.refresh() }
                    case .background: if let live = store.dataSource as? LiveStore { Task { await live.flush() } }
                    default: break
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 780)
        .commands { PlaybackCommands(player: player, store: store) }
        #endif
    }

    /// `-PoddleAppearance dark|light` for screenshots.
    static var forcedScheme: ColorScheme? {
        switch UserDefaults.standard.string(forKey: "PoddleAppearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
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
