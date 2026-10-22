import SwiftUI
import PoddleKit

// Poddle, the little poodle who follows you round the app (decisions.md, "Look, v2"). `Companion`
// draws one pose with a light, looping motion; `CompanionModel` decides what he's up to (bopping
// while audio plays, dozing when it's been paused a while, celebrating a finished episode).
//
// Kept light on purpose: every motion is a plain SwiftUI animation of a transform (rotation, offset,
// scale) on one image, so it runs in the render server's animation path with no timers. Motion
// stops when he's off screen (`companionActive`), when Reduce Motion is on, and when "Show Poddle"
// is off in Profile.

extension EnvironmentValues {
    /// False on tabs that are alive but hidden, and under Now Playing, so loops there don't run.
    @Entry var companionActive = true
}

/// "Show Poddle" in Profile. Stored on this device only.
enum CompanionSettings {
    static let showKey = "showPoddle"
}

/// How the companion moves while a pose is showing.
enum CompanionMotion: Equatable {
    case still
    /// A soft rotate and bounce about his feet, once per beat.
    case bop(bpm: Double)
    /// Slow sleepy breathing.
    case breathe
    case wave
    /// A puzzled head tilt every few seconds.
    case tilt
    /// A gentle side to side, for searching and waiting.
    case sway
    /// Trots across the width he's given.
    case trot
    /// A pop and a couple of hops (celebrating).
    case hop

    /// What each illustration does by default.
    static func natural(for pose: Mascot.Pose) -> CompanionMotion {
        switch pose {
        case .listening: .bop(bpm: 96)
        case .sleeping, .empty, .peekSleepy: .breathe
        case .waving: .wave
        case .confused: .tilt
        case .searching: .sway
        case .trot: .trot
        case .celebrate: .hop
        case .peek: .still
        }
    }
}

/// One pose of the poodle, moving the way `motion` says. Tap him and he wiggles with a few
/// floating notes and hearts; the tap stops here and never reaches what's underneath.
struct Companion: View {
    var pose: Mascot.Pose
    var motion: CompanionMotion = .still
    /// The box he's drawn in; the image fits inside it.
    var size: CGFloat = 80
    var tappable = true
    /// The point he rotates and squashes about. His feet, usually.
    var anchor: UnitPoint = .bottom

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionActive) private var active
    @AppStorage(CompanionSettings.showKey) private var enabled = true
    /// Bumped per tap; drives the wiggle (not with Reduce Motion) and the haptic.
    @State private var wiggles = 0
    @State private var taps = 0
    @State private var bursts: [Burst] = []

    private var moving: Bool { active && enabled && !reduceMotion }

    var body: some View {
        image
            .modifier(CompanionLoop(motion: moving ? motion : .still, anchor: anchor))
            .keyframeAnimator(initialValue: 0.0, trigger: wiggles) { content, angle in
                content.rotationEffect(.degrees(angle), anchor: anchor)
            } keyframes: { _ in
                SpringKeyframe(-12, duration: 0.09)
                SpringKeyframe(10, duration: 0.11)
                SpringKeyframe(-7, duration: 0.11)
                SpringKeyframe(4, duration: 0.1)
                SpringKeyframe(0, duration: 0.2)
            }
            .overlay(alignment: .top) {
                ZStack {
                    ForEach(bursts) { FloatingNote(burst: $0, rises: !reduceMotion) }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { if tappable { tapped() } }
            .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: taps)
            .accessibilityElement()
            .accessibilityLabel("Poddle")
            .accessibilityHint(tappable ? "Tap to make him wiggle." : "")
            .accessibilityAddTraits(tappable ? .isButton : [])
            .accessibilityAction { if tappable { tapped() } }
            .accessibilityHidden(!tappable)
            .accessibilityIdentifier("companion-\(pose.rawValue)")
    }

    private var image: some View {
        Image("Mascot/\(pose.rawValue)")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: size, maxHeight: size, alignment: .bottom)
    }

    private func tapped() {
        taps += 1
        if !reduceMotion { wiggles += 1 }
        let symbols = ["music.note", "heart.fill", "music.note", "heart.fill"]
        var new: [Burst] = []
        for i in 0..<3 {
            let x: CGFloat = CGFloat(i - 1) * size * 0.28 + CGFloat.random(in: -6...6)
            new.append(Burst(symbol: symbols[(taps + i) % symbols.count], x: x, delay: Double(i) * 0.08))
        }
        bursts.append(contentsOf: new)
        let ids = Set(new.map { $0.id })
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            bursts.removeAll { ids.contains($0.id) }
        }
    }

    struct Burst: Identifiable {
        let id = UUID()
        var symbol: String
        var x: CGFloat
        var delay: Double
    }
}

/// A note or heart that floats up and fades. One-shot: it animates once on appear.
private struct FloatingNote: View {
    var burst: Companion.Burst
    var rises: Bool
    @State private var gone = false

    var body: some View {
        Image(systemName: burst.symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(burst.symbol.hasPrefix("heart") ? Palette.tomato : Palette.mustard)
            .offset(x: burst.x, y: gone && rises ? -44 : -4)
            .scaleEffect(gone ? 1.1 : 0.6)
            .opacity(gone ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 1.1).delay(burst.delay)) { gone = true }
            }
    }
}

/// The looping part of each motion. Each case is one `phaseAnimator` over a few transforms, so
/// switching motion (or to `.still`) just swaps which loop is attached.
private struct CompanionLoop: ViewModifier {
    var motion: CompanionMotion
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        switch motion {
        case .still:
            content
        case let .bop(bpm):
            let half = 30 / max(40, bpm)
            content.phaseAnimator([0, 1, 2, 3]) { view, phase in
                view
                    .rotationEffect(.degrees([-4, 0, 4, 0][phase]), anchor: anchor)
                    .offset(y: [0, -3, 0, -3][phase])
            } animation: { _ in .easeInOut(duration: half) }
        case .breathe:
            content.phaseAnimator([false, true]) { view, inhale in
                view.scaleEffect(x: inhale ? 1.02 : 1, y: inhale ? 1.045 : 1, anchor: anchor)
            } animation: { _ in .easeInOut(duration: 1.8) }
        case .wave:
            content.phaseAnimator([0, 1, 2, 3, 4]) { view, phase in
                view.rotationEffect(.degrees([0, -6, 5, -4, 0][phase]), anchor: anchor)
            } animation: { phase in phase == 0 ? .easeInOut(duration: 1.2) : .easeInOut(duration: 0.22) }
        case .tilt:
            content.phaseAnimator([0, 1, 2]) { view, phase in
                view.rotationEffect(.degrees([0, -9, 0][phase]), anchor: anchor)
            } animation: { phase in phase == 0 ? .spring(duration: 0.5).delay(2.2) : .spring(duration: 0.45, bounce: 0.4) }
        case .sway:
            content.phaseAnimator([false, true]) { view, right in
                view.rotationEffect(.degrees(right ? 3 : -3), anchor: anchor)
                    .offset(x: right ? 3 : -3)
            } animation: { _ in .easeInOut(duration: 1.4) }
        case .trot:
            content.modifier(TrotAcross())
        case .hop:
            content.phaseAnimator([0, 1, 2, 3]) { view, phase in
                view.offset(y: [0, -10, 0, -6][phase])
                    .scaleEffect(x: [1.04, 0.97, 1.04, 0.98][phase], y: [0.95, 1.04, 0.96, 1.02][phase], anchor: .bottom)
            } animation: { _ in .easeInOut(duration: 0.22) }
        }
    }
}

/// Runs left to right across whatever width he's in, bouncing a little each stride, then starts
/// again from the left edge. The view needs a width (e.g. `.frame(maxWidth: .infinity)`).
private struct TrotAcross: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .phaseAnimator([0, 1]) { view, phase in
                view.offset(y: phase == 1 ? -3 : 0)
            } animation: { _ in .easeInOut(duration: 0.16) }
            .phaseAnimator([false, true]) { view, across in
                view.offset(x: across ? width * 0.5 + 60 : -width * 0.5 - 60)
            } animation: { across in across ? .linear(duration: 2.6) : nil }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .clipped()
    }
}

// MARK: - State

/// What the roaming companion is up to. Driven by `CompanionDirector` from the player.
@MainActor
@Observable
final class CompanionModel {
    enum Mood: Equatable {
        /// Paused just now: still, eyes open.
        case awake
        /// Audio's playing.
        case bopping
        /// Paused for a while: the sleepy peek, breathing slowly.
        case dozing
    }

    /// How long paused before he dozes off.
    static let dozeAfter: Duration = .seconds(4)
    static let celebrateFor: Duration = .seconds(2.6)

    private(set) var mood: Mood = .dozing
    /// An episode just finished: the celebrate pose pops up for a moment.
    private(set) var celebrating = false
    private(set) var keyboardUp = false
    @ObservationIgnored private var dozeTask: Task<Void, Never>?
    @ObservationIgnored private var celebrateTask: Task<Void, Never>?

    func playbackChanged(isPlaying: Bool) {
        dozeTask?.cancel()
        if isPlaying {
            mood = .bopping
            return
        }
        if mood == .bopping { mood = .awake }
        // One sleep, not a timer: it's cancelled the moment playback resumes.
        dozeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dozeAfter)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.4)) { self.mood = .dozing }
        }
    }

    func celebrate() {
        celebrateTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { celebrating = true }
        celebrateTask = Task { [weak self] in
            try? await Task.sleep(for: Self.celebrateFor)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.35)) { self.celebrating = false }
        }
    }

    func setKeyboardUp(_ up: Bool) {
        if keyboardUp != up { keyboardUp = up }
    }

    /// The peeking pose for the current mood.
    var peekPose: Mascot.Pose { mood == .dozing ? .peekSleepy : .peek }
    var peekMotion: CompanionMotion {
        switch mood {
        case .bopping: .bop(bpm: 96)
        case .dozing: .breathe
        case .awake: .still
        }
    }
}

/// Watches the player for the companion: playing or paused, and an episode finishing (it ends,
/// gets marked played, and the player moves on or stops). Also tracks the keyboard so he can hide.
struct CompanionDirector: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(PoddleStore.self) private var store
    @Environment(\.player) private var player
    @State private var lastProgress: Double = 0

    func body(content: Content) -> some View {
        content
            .onAppear { app.companion.playbackChanged(isPlaying: player.isPlaying) }
            .onChange(of: player.isPlaying) { _, playing in app.companion.playbackChanged(isPlaying: playing) }
            // Sampled coarsely, so this doesn't add work on every position tick.
            .onChange(of: Int(player.progress * 50)) { _, _ in lastProgress = player.progress }
            .onChange(of: player.currentEpisodeId) { old, _ in
                defer { lastProgress = player.progress }
                guard let old, lastProgress > 0.8, store.item(old)?.state.played == true else { return }
                app.companion.celebrate()
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                app.companion.setKeyboardUp(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                app.companion.setKeyboardUp(false)
            }
            #endif
    }
}

// MARK: - Placements

/// Poddle peeking over the mini player's top edge, on the right. Sits in the strip the mini player
/// leaves for him, so he never covers its controls or the list's text at rest.
struct MiniPlayerPeek: View {
    @Environment(AppModel.self) private var app
    /// The strip the mini player leaves above itself for him.
    static let height: CGFloat = 34
    static let frameHeight: CGFloat = height + 10

    var body: some View {
        let c = app.companion
        Companion(pose: c.peekPose, motion: c.peekMotion, size: 66)
            .frame(width: 66, height: Self.frameHeight, alignment: .bottom)
            .animation(.easeInOut(duration: 0.3), value: c.peekPose)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// The celebrate pose with a little confetti, popped up over the bottom bar for a moment.
struct CelebrationPop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion { Confetti() }
            Companion(pose: .celebrate, motion: .hop, size: 92, tappable: false)
        }
        .frame(width: 150, height: 110)
        .allowsHitTesting(false)
        .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
        .accessibilityHidden(true)
        .onAppear { AccessibilityNotification.Announcement("Episode finished").post() }
    }
}

/// A one-shot burst of a dozen bits of confetti in the app's colours.
private struct Confetti: View {
    @State private var burst = false
    private static let colors: [Color] = [Palette.chipOn, Palette.mustard, Color(hex: 0xF6A38E), Palette.fern]
    private static let pieces: [(angle: Double, distance: CGFloat, spin: Double)] = (0..<14).map { piece($0) }

    nonisolated private static func piece(_ i: Int) -> (angle: Double, distance: CGFloat, spin: Double) {
        let angle: Double = Double(i) / 14 * 360 + Double((i * 37) % 17)
        let distance: CGFloat = 46 + CGFloat((i * 13) % 22)
        let spin: Double = Double((i * 71) % 360)
        return (angle, distance, spin)
    }

    var body: some View {
        ZStack {
            ForEach(Array(Self.pieces.enumerated()), id: \.offset) { i, p in
                let r: Double = p.angle * .pi / 180
                let x: CGFloat = burst ? CGFloat(cos(r)) * p.distance : 0
                let y: CGFloat = burst ? CGFloat(sin(r)) * p.distance * 0.7 + 14 : 0
                let square = i % 3 == 0
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Self.colors[i % Self.colors.count])
                    .frame(width: square ? 6 : 4, height: square ? 6 : 9)
                    .rotationEffect(.degrees(burst ? p.spin : 0))
                    .offset(x: x, y: y)
                    .opacity(burst ? 0 : 1)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 1.3)) { burst = true } }
    }
}

/// `trot` running across a strip: a first sync, a pull-to-refresh, stats loading.
struct TrotStrip: View {
    var message: String?
    var height: CGFloat = 56

    var body: some View {
        VStack(spacing: 4) {
            Companion(pose: .trot, motion: .trot, size: height, tappable: false)
                .frame(height: height)
            if let message {
                Text(message).font(.text(13, .semibold)).foregroundStyle(Palette.ink2)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message ?? "Loading")
        .accessibilityIdentifier("trot")
    }
}
