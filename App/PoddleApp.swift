import SwiftUI
import PoddleKit

@main
struct PoddleApp: App {
    @State private var store: PoddleStore
    @State private var player: MockPlayer
    @State private var app = AppModel()

    init() {
        // TODO(LiveStore wiring): swap in PoddleStore(dataSource: LiveStore(...), seed: cachedSnapshot)
        // once the Convex API is ready.
        let store = MockStore.makeStore()
        let player = MockPlayer(store: store)
        player.routeName = "Kitchen"
        player.load(MockData.playingEpisodeId, smartSaved: 252)
        _store = State(initialValue: store)
        _player = State(initialValue: player)

        let defaults = UserDefaults.standard
        let app = AppModel()
        if let screen = defaults.string(forKey: "PoddleScreen") {
            app.applyLaunchScreen(screen, player: player)
        }
        _app = State(initialValue: app)
        if defaults.string(forKey: "PoddlePaused") == nil {
            player.resume()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(player)
                .environment(app)
                .preferredColorScheme(Self.forcedScheme)
                .tint(Palette.tomato)
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
