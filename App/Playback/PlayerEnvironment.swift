import SwiftUI
import PoddleKit

private struct PlayerKey: EnvironmentKey {
    static let defaultValue: (any PoddlePlayer)? = nil
}

extension EnvironmentValues {
    /// The player every screen uses: `EnginePlayer`, or `MockPlayer` for previews and screenshots.
    /// Falls back to the app's player where SwiftUI reads a fresh environment (some presentations do).
    var player: any PoddlePlayer {
        get {
            if let player = self[PlayerKey.self] { return player }
            guard let player = MainActor.assumeIsolated({ AppServices.current?.player }) else {
                fatalError("No player in the environment")
            }
            return player
        }
        set { self[PlayerKey.self] = newValue }
    }
}
