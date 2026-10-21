import SwiftUI
import PoddleKit

/// Warm dark Now Playing. Swipe down anywhere to drop back to the mini player.
struct NowPlayingView: View {
    @Environment(PoddleStore.self) private var store
    @Environment(MockPlayer.self) private var player
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var dragY: CGFloat = 0

    var body: some View {
        @Bindable var app = app
        Group {
            if let item = player.item {
                content(item)
            } else {
                VStack(spacing: 12) {
                    Text("Nothing playing").font(.rounded(22, .bold))
                    Button("Close") { dismiss() }.foregroundStyle(Palette.mustard)
                }
                .foregroundStyle(NP.fg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background { NowPlayingBackground() }
        .offset(y: dragY)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { v in if v.translation.height > 0 && abs(v.translation.height) > abs(v.translation.width) { dragY = v.translation.height } }
                .onEnded { v in
                    if v.translation.height > 140 || v.predictedEndTranslation.height > 400 { dismiss() }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
                }
        )
        .environment(\.colorScheme, .dark)
        .sheet(item: $app.nowPlayingSheet) { SheetHost(route: $0).environment(\.colorScheme, PoddleApp.forcedScheme ?? .light) }
        .presentationBackground(.clear)
    }

    @ViewBuilder private func content(_ item: EpisodeItem) -> some View {
        let upNext = store.upNext(excluding: item.id)
        VStack(spacing: 0) {
            Capsule().fill(NP.fg3).frame(width: 36, height: 5).padding(.top, 6)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
                Spacer()
                VStack(spacing: 1) {
                    Text("Playing from Up Next").font(.rounded(10.5, .bold)).tracking(1.26).textCase(.uppercase).foregroundStyle(NP.fg2)
                    Text(upNext.isEmpty ? "Last one" : "\(upNext.count) more · \(Format.duration(store.wallTime(upNext)))")
                        .font(.text(13, .semibold))
                }
                Spacer()
                moreMenu(item)
            }
            .foregroundStyle(NP.fg)
            .padding(.horizontal, 8)
            .frame(height: 44)

            Spacer(minLength: 4)
            ArtworkGestures(item: item)
            chapterPill.padding(.top, 18)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.episode.title).font(.rounded(22, .bold)).tracking(-0.22).lineLimit(2)
                        .foregroundStyle(NP.fg)
                    Button { app.goToShow(item.podcast.id) } label: {
                        Text(item.podcast.title).font(.text(16, .medium)).foregroundStyle(Palette.mustard)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Scrubber().padding(.horizontal, 24).padding(.top, 16)
            Transport().padding(.top, 10)
            TuningStrip(podcastId: item.podcast.id).padding(.horizontal, 16).padding(.top, 14)
            UtilityRow(item: item).padding(.horizontal, 10).padding(.top, 14)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var chapterPill: some View {
        if let chapter = player.currentChapter, let i = player.currentChapterIndex {
            Button { app.nowPlayingSheet = .queueAndChapters } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.mustard)
                    Text("Ch \(i + 1) of \(player.chapters.count)").foregroundStyle(NP.fg)
                    Text("· \(chapter.title)").foregroundStyle(NP.fg2).fontWeight(.medium).lineLimit(1)
                }
                .font(.text(12.5, .semibold))
                .padding(.leading, 8).padding(.trailing, 12)
                .frame(height: 28)
                .background(NP.util, in: Capsule())
                .contentTransition(.opacity)
            }
            .buttonStyle(.pressable)
            .padding(.horizontal, 24)
        } else {
            Color.clear.frame(height: 28)
        }
    }

    private func moreMenu(_ item: EpisodeItem) -> some View {
        Menu {
            Button { store.toggleStar(item.id) } label: { Label(item.isStarred ? "Unstar" : "Star", systemImage: "star") }
            Button { app.nowPlayingSheet = .showSettings(podcastId: item.podcast.id) } label: { Label("Show settings", systemImage: "slider.horizontal.3") }
            Button { app.goToShow(item.podcast.id) } label: { Label("Go to show", systemImage: "rectangle.stack") }
            ShareLink(item: URL(string: item.episode.enclosureURL)!) { Label("Share episode", systemImage: "square.and.arrow.up") }
            Divider()
            Button { player.playNextInQueue(); store.markPlayed(item.id) } label: { Label("Mark played and skip", systemImage: "checkmark.circle") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold)).frame(width: 44, height: 44)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }
}

/// Now Playing's fixed warm-dark colours.
enum NP {
    static let fg = Color(hex: 0xF4EADB)
    static let fg2 = Color(hex: 0xF4EADB, alpha: 0.62)
    static let fg3 = Color(hex: 0xF4EADB, alpha: 0.34)
    static let track = Color(hex: 0xF4EADB, alpha: 0.16)
    static let util = Color(hex: 0xF4EADB, alpha: 0.07)
    static let wellBg = Color.black.opacity(0.32)
}

struct NowPlayingBackground: View {
    var body: some View {
        Fills.nowPlaying
            .overlay(GrainOverlay(dark: true))
            .ignoresSafeArea()
    }
}

/// Artwork: tap to play/pause, double-tap a half to skip, swipe sideways for chapters.
private struct ArtworkGestures: View {
    var item: EpisodeItem
    @Environment(MockPlayer.self) private var player
    @State private var swipeX: CGFloat = 0
    @State private var bumped = 0
    @State private var flash: Edge?

    var body: some View {
        let size: CGFloat = 268
        ArtworkView(podcast: item.podcast, size: size, cornerRadius: 26, shadow: false)
            .shadow(color: .black.opacity(0.6), radius: 25, y: 30)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 8)
            .scaleEffect(player.isPlaying ? 1 : 0.9)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
            .offset(x: swipeX)
            .overlay {
                HStack(spacing: 0) {
                    tapZone(.leading)
                    tapZone(.trailing)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { v in if abs(v.translation.width) > abs(v.translation.height) { swipeX = v.translation.width * 0.4 } }
                    .onEnded { v in
                        if v.translation.width < -70 { player.nextChapter(); bumped += 1 }
                        else if v.translation.width > 70 { player.previousChapter(); bumped += 1 }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { swipeX = 0 }
                    }
            )
            .sensoryFeedback(.impact(weight: .medium), trigger: bumped)
            .accessibilityElement()
            .accessibilityLabel("\(item.podcast.title) artwork")
            .accessibilityHint("Tap to play or pause. Swipe for chapters.")
            .accessibilityAction { player.togglePlayPause() }
    }

    private func tapZone(_ edge: Edge) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay {
                if flash == edge {
                    Image(systemName: edge == .leading ? "gobackward.\(Int(player.skipBack))" : "goforward.\(Int(player.skipForward))")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(18)
                        .background(.black.opacity(0.35), in: Circle())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .onTapGesture(count: 2) {
                edge == .leading ? player.skipBackTapped() : player.skipForwardTapped()
                withAnimation(.spring(response: 0.25)) { flash = edge }
                bumped += 1
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    withAnimation { flash = nil }
                }
            }
            .onTapGesture { player.togglePlayPause() }
    }
}

/// Chapters are gaps in the scrubber. Drag to seek; drag your finger further down to scrub finer.
private struct Scrubber: View {
    @Environment(MockPlayer.self) private var player
    @State private var dragPosition: Double?
    @State private var startPosition: Double = 0

    var body: some View {
        let duration = max(1, player.duration)
        let position = dragPosition ?? player.position
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let segments = segmentFractions(duration)
                let gap: CGFloat = 3
                let usable = w - gap * CGFloat(segments.count - 1)
                let fraction = position / duration
                ZStack(alignment: .leading) {
                    HStack(spacing: gap) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                            let segW = max(2, usable * (seg.1 - seg.0))
                            let fill = min(1, max(0, (fraction - seg.0) / max(0.0001, seg.1 - seg.0)))
                            Capsule().fill(NP.track)
                                .overlay(alignment: .leading) { Capsule().fill(NP.fg).frame(width: segW * fill) }
                                .clipShape(Capsule())
                                .frame(width: segW, height: 6)
                        }
                    }
                    Circle().fill(NP.fg)
                        .frame(width: dragPosition == nil ? 16 : 22, height: dragPosition == nil ? 16 : 22)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                        .offset(x: w * fraction - (dragPosition == nil ? 8 : 11))
                        .animation(.spring(response: 0.2), value: dragPosition == nil)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if dragPosition == nil { startPosition = Double(v.startLocation.x / w) * duration }
                            // The further down you drag, the finer the scrub.
                            let fine = max(1, 1 + Double(max(0, v.translation.height - 30)) / 40)
                            let delta = Double(v.translation.width / w) * duration / fine
                            dragPosition = min(duration, max(0, startPosition + delta))
                        }
                        .onEnded { _ in
                            if let p = dragPosition { player.seek(to: p) }
                            dragPosition = nil
                        }
                )
            }
            .frame(height: 22)
            HStack {
                Text(Format.clock(position)).font(.rounded(12, .semibold))
                Spacer()
                Text(Format.timeLeft(max(0, duration - position), rate: player.rate)).font(.text(12, .semibold)).foregroundStyle(NP.fg)
                Spacer()
                Text(Format.remainingClock(max(0, duration - position))).font(.rounded(12, .semibold))
            }
            .monospacedDigit()
            .foregroundStyle(NP.fg2)
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Format.clock(position)) of \(Format.clock(duration))")
        .accessibilityAdjustableAction { dir in
            dir == .increment ? player.skipForwardTapped() : player.skipBackTapped()
        }
    }

    private func segmentFractions(_ duration: Double) -> [(Double, Double)] {
        let chapters = player.chapters
        guard chapters.count > 1 else {
            // No chapters: still break the bar into even dashes, like the design.
            return [(0, 1)]
        }
        return chapters.map { c in (c.start / duration, (c.end ?? duration) / duration) }
    }
}

private struct Transport: View {
    @Environment(MockPlayer.self) private var player
    @State private var pressed = 0

    var body: some View {
        HStack(spacing: 36) {
            skip(back: true)
            Button { player.togglePlayPause(); pressed += 1 } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Palette.creamWhite)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 80, height: 80)
                    .background {
                        Circle().fill(Fills.bigPlay)
                            .overlay(Circle().inset(by: 1).stroke(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center), lineWidth: 2))
                            .shadow(color: .black.opacity(0.35), radius: 11, y: 10)
                            .background(Circle().fill(Palette.tomato.opacity(0.14)).padding(-6))
                    }
            }
            .buttonStyle(PressableStyle(scale: 0.94))
            .sensoryFeedback(.impact(weight: .medium), trigger: pressed)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            skip(back: false)
        }
    }

    private func skip(back: Bool) -> some View {
        let seconds = Int(back ? player.skipBack : player.skipForward)
        return Button { back ? player.skipBackTapped() : player.skipForwardTapped() } label: {
            Image(systemName: back ? "gobackward.\(seconds)" : "goforward.\(seconds)")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(NP.fg)
                .frame(width: 64, height: 64)
        }
        .buttonStyle(.pressable)
        .contextMenu {
            Section("Skip \(back ? "back" : "forward") this session") {
                ForEach([5, 10, 15, 30, 45, 60], id: \.self) { s in
                    Button("\(s) seconds") {
                        if back { player.skipBackOverride = Double(s) } else { player.skipForwardOverride = Double(s) }
                    }
                }
            }
        }
        .accessibilityLabel(back ? "Skip back \(seconds) seconds" : "Skip forward \(seconds) seconds")
    }
}

/// The speed control: a tuning strip. Flick it sideways to nudge in 0.05× clicks, tap for the
/// full sheet. The gold pin says this speed is the show's own; the faint "default" mark shows
/// where you'd normally sit.
private struct TuningStrip: View {
    var podcastId: String
    @Environment(PoddleStore.self) private var store
    @Environment(AppModel.self) private var app
    @State private var dragStart: Double?
    @State private var preview: Double?

    private let stepWidth: CGFloat = 8 // points per 0.05×
    private let needleX: CGFloat = 100

    var body: some View {
        let resolved = store.resolved(podcastId).speed
        let speed = preview ?? resolved.value
        let showName = store.podcast(podcastId).map { shortName($0.title) } ?? "This show"
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.speed(speed))
                    .font(.rounded(26, .heavy)).tracking(-0.5).monospacedDigit()
                    .contentTransition(.numericText(value: speed))
                    .foregroundStyle(NP.fg)
                HStack(spacing: 3) {
                    if resolved.isOverride { PinGlyph().frame(width: 11, height: 11) } else { Image(systemName: "globe").font(.system(size: 10, weight: .bold)) }
                    Text(resolved.isOverride ? "\(showName) only" : "Your default")
                }
                .font(.rounded(11, .bold))
                .foregroundStyle(resolved.isOverride ? Palette.mustard : NP.fg2)
                .lineLimit(1)
            }
            .frame(width: 118, alignment: .leading)
            .padding(.leading, 16)

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    scale(speed: speed, width: geo.size.width)
                    if resolved.isOverride {
                        defaultMark.offset(x: needleX + CGFloat((store.global.speed - speed) / 0.05) * stepWidth - 22, y: 7)
                    }
                    needle.offset(x: needleX - 1.5, y: 8)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
            }
            .padding(.trailing, 8)
        }
        .frame(height: 64)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(NP.wellBg.shadow(.inner(color: .black.opacity(0.35), radius: 3, y: 2)))
        }
        .contentShape(Rectangle())
        .onTapGesture { app.nowPlayingSheet = .speed(podcastId: podcastId) }
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { v in
                    let start = dragStart ?? resolved.value
                    dragStart = start
                    preview = Speed.snap(start - Double(v.translation.width / stepWidth) * 0.05)
                }
                .onEnded { _ in
                    if let p = preview { store.setSpeed(p, scope: store.defaultSpeedScope(for: podcastId)) }
                    preview = nil
                    dragStart = nil
                }
        )
        .sensoryFeedback(.selection, trigger: Speed.detent(speed))
        .accessibilityElement()
        .accessibilityLabel("Playback speed")
        .accessibilityValue(Format.speed(speed))
        .accessibilityAdjustableAction { dir in
            store.setSpeed(resolved.value + (dir == .increment ? 0.05 : -0.05), scope: store.defaultSpeedScope(for: podcastId))
        }
        .accessibilityAction(named: "Speed options") { app.nowPlayingSheet = .speed(podcastId: podcastId) }
    }

    private func shortName(_ title: String) -> String {
        let first = title.split(separator: " ").first.map(String.init) ?? title
        return first.count <= 3 ? title : first
    }

    private func scale(speed: Double, width: CGFloat) -> some View {
        Canvas { ctx, size in
            let originX = needleX - CGFloat((speed - 0.5) / 0.05) * stepWidth
            for i in 0...50 {
                let x = originX + CGFloat(i) * stepWidth
                guard x > -20 && x < size.width + 20 else { continue }
                let major = i % 2 == 0
                let h: CGFloat = major ? 15 : 8
                let rect = CGRect(x: x - (major ? 0.75 : 0.5), y: size.height - 18 - h, width: major ? 1.5 : 1, height: h)
                ctx.fill(Path(rect), with: .color(major ? NP.fg2 : NP.fg3))
                if i % 4 == 2 {
                    let value = 0.5 + Double(i) * 0.05
                    let text = Text(Format.speedNumber(value)).font(.rounded(10, .semibold)).foregroundStyle(NP.fg2)
                    ctx.draw(text, at: CGPoint(x: x, y: size.height - 8))
                }
            }
        }
    }

    private var needle: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3).fill(Palette.tomato).frame(width: 10, height: 6)
            RoundedRectangle(cornerRadius: 2).fill(Palette.tomato).frame(width: 3, height: 36).padding(.top, -2)
        }
        .offset(x: -3.5)
        .shadow(color: Palette.tomato.opacity(0.6), radius: 4)
    }

    private var defaultMark: some View {
        VStack(spacing: 2) {
            Text("DEFAULT").font(.rounded(8.5, .bold)).tracking(0.5)
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 6))
        }
        .foregroundStyle(NP.fg2)
        .frame(width: 44)
    }
}

private struct UtilityRow: View {
    var item: EpisodeItem
    @Environment(PoddleStore.self) private var store
    @Environment(MockPlayer.self) private var player
    @Environment(AppModel.self) private var app

    var body: some View {
        let resolved = store.resolved(item.podcast.id)
        HStack(alignment: .top, spacing: 0) {
            util("Smart", detail: resolved.smartSpeed.value ? "\(Format.saved(player.smartSaved)) saved" : "Off",
                 icon: "waveform.path", on: resolved.smartSpeed.value) {
                toggle(\.smartSpeed, current: resolved.smartSpeed)
            }
            util("Boost", detail: resolved.voiceBoost.value ? "On" : "Off", icon: "speaker.wave.2", on: resolved.voiceBoost.value) {
                toggle(\.voiceBoost, current: resolved.voiceBoost)
            }
            SleepMenu()
            AirPlayUtil()
            util("Queue", detail: "& chapters", icon: "list.bullet.indent", on: false) { app.nowPlayingSheet = .queueAndChapters }
        }
    }

    /// Flips the setting where it lives: the show's override if it has one, otherwise the default.
    private func toggle(_ key: WritableKeyPath<PodcastSettings, Bool?>, current: Resolved<Bool>) {
        if current.isOverride {
            store.updateSettings(item.podcast.id) { $0[keyPath: key] = !current.value }
        } else {
            store.updateGlobal { g in
                switch key {
                case \PodcastSettings.smartSpeed: g.smartSpeed.toggle()
                default: g.voiceBoost.toggle()
                }
            }
        }
    }

    private func util(_ title: String, detail: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            UtilityLabel(title: title, detail: detail, icon: icon, on: on)
        }
        .buttonStyle(.pressable)
        .sensoryFeedback(.selection, trigger: on)
    }
}

struct UtilityLabel: View {
    var title: String
    var detail: String
    var icon: String
    var on: Bool
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(on ? Palette.mustard : NP.fg)
                .frame(width: 44, height: 44)
                .background(on ? Palette.mustard.opacity(0.2) : NP.util, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(spacing: 0) {
                Text(title).fontWeight(.bold)
                Text(detail).lineLimit(1)
            }
            .font(.text(10.5, .semibold))
            .foregroundStyle(on ? NP.fg : NP.fg2)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SleepMenu: View {
    @Environment(MockPlayer.self) private var player

    var body: some View {
        Menu {
            Button { player.setSleepTimer(.endOfEpisode) } label: { Label("End of episode", systemImage: "stop.circle") }
            if !player.chapters.isEmpty {
                Button { player.setSleepTimer(.endOfChapter) } label: { Label("End of chapter", systemImage: "list.bullet") }
            }
            Section {
                ForEach(SleepTimer.presets, id: \.self) { m in
                    Button("\(m) minutes") { player.setSleepMinutes(m) }
                }
            }
            if player.sleepTimer != .off {
                Button(role: .destructive) { player.setSleepTimer(.off) } label: { Label("Turn off", systemImage: "xmark") }
            }
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                UtilityLabel(title: "Sleep", detail: detail, icon: player.sleepTimer == .off ? "moon" : "moon.zzz.fill", on: player.sleepTimer != .off)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var detail: String {
        switch player.sleepTimer {
        case .off: "Off"
        case .endOfEpisode: "End of ep"
        case .endOfChapter: "End of ch"
        case .minutes: Format.countdown(player.sleepRemaining ?? 0)
        }
    }
}

#if os(iOS)
import AVKit

/// AirPlay: the label shows the current route, and the real route picker sits on top of it.
private struct AirPlayUtil: View {
    @Environment(MockPlayer.self) private var player
    var body: some View {
        UtilityLabel(title: "AirPlay", detail: player.routeName, icon: "airplay.audio", on: false)
            .overlay(alignment: .top) { RoutePicker().frame(width: 44, height: 44) }
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .clear
        v.activeTintColor = .clear
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
private struct AirPlayUtil: View {
    @Environment(MockPlayer.self) private var player
    var body: some View {
        UtilityLabel(title: "AirPlay", detail: player.routeName, icon: "airplay.audio", on: false)
    }
}
#endif
