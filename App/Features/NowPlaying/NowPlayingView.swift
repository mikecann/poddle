import SwiftUI
import PoddleKit

/// Warm dark Now Playing, three pages like Overcast (decisions.md): show notes and chapters on the
/// left, the player in the middle, playback settings on the right. Swipe sideways to change page,
/// swipe down on the player or the header to drop back to the mini player.
struct NowPlayingView: View {
    @Environment(PoddleStore.self) private var store
    @Environment(\.player) private var player
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
        .overlay(alignment: .bottom) {
            UndoToastView().padding(.horizontal, 16).padding(.bottom, 8)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.undo.toast?.id)
        }
        .background { NowPlayingBackground() }
        .offset(y: dragY)
        .environment(\.colorScheme, .dark)
        .sheet(item: $app.nowPlayingSheet) { SheetHost(route: $0).environment(\.colorScheme, PoddleApp.forcedScheme ?? .light) }
        .presentationBackground(.clear)
        .onDisappear { app.nowPlayingPage = .player }
    }

    /// Swipe down to close. Only acts on mostly vertical drags, so it never fights the pages.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in if v.translation.height > 0 && abs(v.translation.height) > abs(v.translation.width) * 1.5 { dragY = v.translation.height } }
            .onEnded { v in
                if dragY > 0, v.translation.height > 140 || v.predictedEndTranslation.height > 400 { dismiss() }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
            }
    }

    @ViewBuilder private func content(_ item: EpisodeItem) -> some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            header(item)
                .contentShape(Rectangle())
                .gesture(dismissDrag)
            PageDots(selection: $app.nowPlayingPage)
            pages(item)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func pages(_ item: EpisodeItem) -> some View {
        @Bindable var app = app
        #if os(iOS)
        TabView(selection: $app.nowPlayingPage) {
            NotesPage(item: item).tag(NowPlayingPage.notes)
            PlayerPage(item: item).simultaneousGesture(dismissDrag).tag(NowPlayingPage.player)
            PlaybackSettingsPage(podcastId: item.podcast.id).tag(NowPlayingPage.settings)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        Group {
            switch app.nowPlayingPage {
            case .notes: NotesPage(item: item)
            case .player: PlayerPage(item: item)
            case .settings: PlaybackSettingsPage(podcastId: item.podcast.id)
            }
        }
        .frame(maxHeight: .infinity)
        .transition(.opacity)
        #endif
    }

    private func header(_ item: EpisodeItem) -> some View {
        let upNext = store.upNext(excluding: item.id)
        return VStack(spacing: 0) {
            Capsule().fill(NP.fg3).frame(width: 36, height: 5).padding(.top, 6)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
                Spacer()
                VStack(spacing: 1) {
                    Text(title).font(.rounded(10.5, .bold)).tracking(1.26).textCase(.uppercase).foregroundStyle(NP.fg2)
                    Text(upNext.isEmpty ? "Last one" : "\(upNext.count) more · \(Format.duration(store.wallTime(upNext)))")
                        .font(.text(13, .semibold))
                }
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: app.nowPlayingPage)
                Spacer()
                moreMenu(item)
            }
            .foregroundStyle(NP.fg)
            .padding(.horizontal, 8)
            .frame(height: 44)
        }
    }

    private var title: String {
        switch app.nowPlayingPage {
        case .notes: "Show notes"
        case .player: "Playing from Up Next"
        case .settings: "Playback settings"
        }
    }

    private func moreMenu(_ item: EpisodeItem) -> some View {
        Menu {
            Button { store.toggleStar(item.id) } label: { Label(item.isStarred ? "Unstar" : "Star", systemImage: "star") }
            Button { app.nowPlayingSheet = .queue } label: { Label("Up Next", systemImage: "list.bullet.indent") }
            Button { app.nowPlayingSheet = .showSettings(podcastId: item.podcast.id) } label: { Label("All show settings", systemImage: "slider.horizontal.3") }
            Button { app.goToShow(item.podcast.id) } label: { Label("Go to show", systemImage: "rectangle.stack") }
            ShareLink(item: URL(string: item.episode.enclosureURL)!) { Label("Share episode", systemImage: "square.and.arrow.up") }
            Divider()
            Button { markPlayedAndSkip(item) } label: { Label("Mark played and skip", systemImage: "checkmark.circle") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold)).frame(width: 44, height: 44)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }

    /// Undo brings it back: unplayed, at its old position, playing again.
    private func markPlayedAndSkip(_ item: EpisodeItem) {
        let point = store.restorePoint([item.id])
        let id = item.id
        player.playNextInQueue()
        store.markPlayed(id)
        app.undo.show("Played", item.episode.title) { [store, player] in
            store.restore(point)
            player.play(id)
        }
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

/// Three dots under the header. Tap one to jump to that page.
private struct PageDots: View {
    @Binding var selection: NowPlayingPage

    var body: some View {
        HStack(spacing: 7) {
            ForEach(NowPlayingPage.allCases, id: \.self) { page in
                let on = page == selection
                Capsule()
                    .fill(on ? NP.fg : NP.fg3)
                    .frame(width: on ? 18 : 7, height: 7)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { selection = page } }
                    .accessibilityElement()
                    .accessibilityLabel(page.label)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension NowPlayingPage {
    var label: String {
        switch self {
        case .notes: "Show notes"
        case .player: "Player"
        case .settings: "Playback settings"
        }
    }
}

/// The middle page: artwork, title, scrubber, transport, then speed, sleep, AirPlay and Up Next.
private struct PlayerPage: View {
    var item: EpisodeItem
    @Environment(\.player) private var player
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)
            ArtworkTaps(item: item)
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
            UtilityRow(item: item).padding(.horizontal, 10).padding(.top, 18)
            Spacer(minLength: 8)
        }
    }

    @ViewBuilder private var chapterPill: some View {
        if let chapter = player.currentChapter, let i = player.currentChapterIndex {
            Button { withAnimation { app.nowPlayingPage = .notes } } label: {
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
}

/// Artwork: tap to play or pause, double-tap a half to skip back or forward. No drag gestures at
/// all (decisions.md): sideways swipes belong to the pages, and nothing here archives, deletes,
/// skips an episode or marks it played.
private struct ArtworkTaps: View {
    var item: EpisodeItem
    @Environment(\.player) private var player
    @State private var bumped = 0
    @State private var flash: Edge?

    var body: some View {
        let size: CGFloat = 268
        ArtworkView(podcast: item.podcast, size: size, cornerRadius: 26, shadow: false)
            .shadow(color: .black.opacity(0.6), radius: 25, y: 30)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 8)
            .scaleEffect(player.isPlaying ? 1 : 0.9)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
            .overlay {
                HStack(spacing: 0) {
                    tapZone(.leading)
                    tapZone(.trailing)
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: bumped)
            .accessibilityElement()
            .accessibilityLabel("\(item.podcast.title) artwork")
            .accessibilityHint("Tap to play or pause.")
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
    @Environment(\.player) private var player
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
    @Environment(\.player) private var player
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

/// Speed, sleep timer, AirPlay and the queue. Smart Speed, Voice Boost and the rest live on the
/// settings page; tapping the speed goes there.
private struct UtilityRow: View {
    var item: EpisodeItem
    @Environment(PoddleStore.self) private var store
    @Environment(\.player) private var player
    @Environment(AppModel.self) private var app

    var body: some View {
        let resolved = store.resolved(item.podcast.id)
        let custom = store.customizesPlayback(item.podcast.id)
        HStack(alignment: .top, spacing: 0) {
            Button { withAnimation { app.nowPlayingPage = .settings } } label: {
                VStack(spacing: 5) {
                    Text(Format.speed(resolved.speed.value))
                        .font(.rounded(15, .heavy)).monospacedDigit().tracking(-0.3)
                        .foregroundStyle(custom ? Palette.mustard : NP.fg)
                        .contentTransition(.numericText(value: resolved.speed.value))
                        .frame(width: 52, height: 44)
                        .background(custom ? Palette.mustard.opacity(0.2) : NP.util, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(spacing: 0) {
                        Text("Speed").fontWeight(.bold)
                        Text(resolved.smartSpeed.value ? "\(Format.saved(player.smartSaved)) saved" : custom ? "This show" : "Default")
                            .lineLimit(1)
                    }
                    .font(.text(10.5, .semibold))
                    .foregroundStyle(NP.fg2)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Speed \(Format.speed(resolved.speed.value)). Playback settings")
            SleepMenu()
            AirPlayUtil()
            Button { app.nowPlayingSheet = .queue } label: {
                UtilityLabel(title: "Up Next", detail: "\(store.upNext(excluding: item.id).count) more", icon: "list.bullet.indent", on: false)
            }
            .buttonStyle(.pressable)
        }
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
    @Environment(\.player) private var player

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
    @Environment(\.player) private var player
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
    @Environment(\.player) private var player
    var body: some View {
        UtilityLabel(title: "AirPlay", detail: player.routeName, icon: "airplay.audio", on: false)
    }
}
#endif
