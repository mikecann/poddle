import SwiftUI
import PoddleKit

@main
struct PoddleApp: App {
    @State private var store: PoddleStore
    @State private var player: MockPlayer
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let defaults = UserDefaults.standard
        let arguments = ProcessInfo.processInfo.arguments
        let screen = defaults.string(forKey: "PoddleScreen")
        // Sample data only when asked for: `-PoddleMock YES`, or a screenshot run (`-PoddleScreen`)
        // without `-PoddleLive YES`.
        let mock = arguments.contains("-PoddleMock") || (screen != nil && !arguments.contains("-PoddleLive"))

        let store = mock ? MockStore.makeStore() : Self.liveStore()
        let player = MockPlayer(store: store)
        if mock {
            player.routeName = "Kitchen"
            player.load(MockData.playingEpisodeId, smartSaved: 252)
        } else if let head = store.queue.first {
            player.load(head.id)
        }
        _store = State(initialValue: store)
        _player = State(initialValue: player)

        let app = AppModel()
        app.isMock = mock
        if let screen {
            app.applyLaunchScreen(screen, player: player, store: store)
        }
        _app = State(initialValue: app)
        if mock && defaults.string(forKey: "PoddlePaused") == nil {
            player.resume()
        }
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
                .environment(player)
                .environment(app)
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
    var player: MockPlayer
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
