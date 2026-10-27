import SwiftUI
import PoddleKit

/// Blush Now Playing (warm plum in dark mode), three pages like Overcast (decisions.md): show notes and chapters on the
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
                    Button("Close") { dismiss() }.foregroundStyle(Palette.tomatoText)
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
        .sheet(item: $app.nowPlayingSheet) { SheetHost(route: $0) }
        .presentationBackground(.clear)
        .onDisappear { app.nowPlayingPage = .player }
    }

    /// Swipe down to close. Only acts on mostly vertical drags, so it never fights the pages.
    /// Measured in global space: the view moves with the finger, so local translations would feed
    /// back into themselves and make the sheet jiggle while it's held.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
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
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(NP.fg)
                        .frame(width: 42, height: 42)
                        .raised(Circle(), fill: NP.util)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("nowPlaying.close")
                Spacer()
                VStack(spacing: 1) {
                    Text(title).font(.rounded(19, .heavy)).foregroundStyle(NP.fg)
                    Text(upNext.isEmpty ? "Last one" : "\(upNext.count) more · \(Format.duration(store.wallTime(upNext)))")
                        .font(.text(13.5, .semibold)).foregroundStyle(NP.fg2)
                }
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: app.nowPlayingPage)
                Spacer()
                moreMenu(item)
            }
            .foregroundStyle(NP.fg)
            .padding(.horizontal, 12)
            .frame(height: 56)
            .padding(.top, 4)
        }
    }

    private var title: String {
        switch app.nowPlayingPage {
        case .notes: "Show notes"
        case .player: "Now Playing"
        case .settings: "Playback settings"
        }
    }

    private func moreMenu(_ item: EpisodeItem) -> some View {
        Menu {
            Button { store.toggleStar(item.id) } label: { Label(item.isStarred ? "Unstar" : "Star", systemImage: "star") }
            Button { app.nowPlayingSheet = .queue } label: { Label("Up Next", systemImage: "list.bullet.indent") }
            Button { app.nowPlayingSheet = .showSettings(podcastId: item.podcast.id) } label: { Label("All show settings", systemImage: "slider.horizontal.3") }
            Button { app.goToShow(item.podcast.id) } label: { Label("Go to show", systemImage: "rectangle.stack") }
            if ShareLinks.canShare(item.podcast) {
                ShareLink(item: ShareLinks.episode(item.id), subject: Text(item.episode.title)) {
                    Label("Share episode", systemImage: "square.and.arrow.up")
                }
                if player.position >= 1 {
                    ShareLink(item: ShareLinks.episode(item.id, at: player.position), subject: Text(item.episode.title)) {
                        Label("Share from \(Format.clock(player.position))", systemImage: "clock")
                    }
                }
            }
            Divider()
            Button { markPlayedAndSkip(item) } label: { Label("Mark played and skip", systemImage: "checkmark.circle") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 18, weight: .heavy))
                .foregroundStyle(NP.fg)
                .frame(width: 42, height: 42)
                .raised(Circle(), fill: NP.util)
                .frame(width: 48, height: 48)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .accessibilityIdentifier("nowPlaying.more")
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

/// Now Playing's colours, on blush (light) or warm plum (dark). Ink on the deepest blush is 10:1,
/// fg2 5.2:1; accents use `Palette.tomatoText` for text.
enum NP {
    static let fg = Palette.ink
    static let fg2 = Color(light: 0x6A4036, dark: 0xFBEDE2, darkAlpha: 0.74)
    static let fg3 = Color(light: 0x6A4036, lightAlpha: 0.4, dark: 0xFBEDE2, darkAlpha: 0.36)
    /// The curl scrubber's unfilled curls, and puffy buttons on blush.
    static let track = Color(light: 0xFFF6EF, dark: 0x4D302A)
    static let util = Color(light: 0xFFF8F2, dark: 0x3F2622)
    static let wellBg = Color(light: 0xF3C7B7, dark: 0x1A0F0E)
}

struct NowPlayingBackground: View {
    var body: some View {
        Fills.nowPlaying.ignoresSafeArea()
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
                    .fill(on ? Palette.chipOn : NP.fg3)
                    .frame(width: on ? 22 : 8, height: 8)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { selection = page } }
                    .accessibilityElement()
                    .accessibilityLabel(page.label)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("nowPlaying.page.\(page)")
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
                    Text(item.episode.title).font(.rounded(24, .heavy)).tracking(-0.3).lineLimit(2)
                        .foregroundStyle(NP.fg)
                    Button { app.goToShow(item.podcast.id) } label: {
                        Text(item.podcast.title).font(.text(17, .bold)).foregroundStyle(Palette.tomatoText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("nowPlaying.show")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Scrubber().padding(.horizontal, 22).padding(.top, 8)
            Transport().padding(.top, 6)
            UtilityRow(item: item).padding(.horizontal, 10).padding(.top, 16)
            Spacer(minLength: 8)
        }
    }

    @ViewBuilder private var chapterPill: some View {
        if let chapter = player.currentChapter, let i = player.currentChapterIndex {
            Button { withAnimation { app.nowPlayingPage = .notes } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.tomato)
                    Text("Ch \(i + 1) of \(player.chapters.count)").foregroundStyle(NP.fg).fontWeight(.bold)
                    Text("· \(chapter.title)").foregroundStyle(NP.fg2).fontWeight(.medium).lineLimit(1)
                }
                .font(.text(13.5, .semibold))
                .padding(.leading, 12).padding(.trailing, 14)
                .frame(height: 34)
                .raised(Capsule(), fill: NP.util)
                .contentTransition(.opacity)
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("nowPlaying.chapter")
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
        let cloud = CloudShape(cornerRadius: 40, scallop: 46, depth: 4)
        ArtworkView(podcast: item.podcast, size: size, cornerRadius: 0, shadow: false)
            .clipShape(cloud)
            .background { cloud.fill(Palette.cardEdge).offset(y: 5) }
            .floatShadow(18, y: 14, opacity: 0.22)
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
            .accessibilityIdentifier("nowPlaying.artwork")
            .overlay(alignment: .bottomTrailing) { ListeningCompanion().offset(x: 30, y: 18) }
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

/// Poddle by the artwork: bopping while it plays, asleep once it's been paused a while.
private struct ListeningCompanion: View {
    @Environment(AppModel.self) private var app
    @AppStorage(CompanionSettings.showKey) private var show = true

    var body: some View {
        if show {
            let mood = app.companion.mood
            Companion(pose: mood == .dozing ? .sleeping : .listening,
                      motion: mood == .dozing ? .breathe : mood == .bopping ? .bop(bpm: 96) : .still,
                      size: 104)
                .frame(width: 110, height: 96, alignment: .bottom)
                .animation(.easeInOut(duration: 0.3), value: mood)
        }
    }
}

/// The curl scrubber: a line of curls that fills in tomato as you listen, with a cream puff for
/// the playhead. The touch target is the full 44 pt band, not just the curls. Drag to seek; drag
/// your finger further down to scrub finer. Small notches under the curls mark chapters.
private struct Scrubber: View {
    @Environment(\.player) private var player
    @State private var dragPosition: Double?
    @State private var startPosition: Double = 0

    var body: some View {
        let duration = max(1, player.duration)
        let position = dragPosition ?? player.position
        VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width
                let fraction = min(1, max(0, position / duration))
                let knob: CGFloat = dragPosition == nil ? 26 : 32
                ZStack(alignment: .leading) {
                    CurlLine().fill(NP.track)
                        .overlay(CurlLine().stroke(NP.fg3.opacity(0.5), lineWidth: 0.75))
                    CurlLine(fraction: fraction).fill(Palette.tomato)
                    ForEach(chapterMarks(duration), id: \.self) { mark in
                        Circle().fill(NP.fg3).frame(width: 4, height: 4)
                            .offset(x: w * mark - 2, y: 13)
                    }
                    Circle().fill(Palette.creamWhite)
                        .overlay(Circle().stroke(Palette.cardEdge, lineWidth: 1.5))
                        .frame(width: knob, height: knob)
                        .floatShadow(3, y: 2, opacity: 0.3)
                        .offset(x: w * fraction - knob / 2)
                        .animation(.spring(response: 0.2), value: dragPosition == nil)
                }
                .frame(height: 16)
                .frame(maxHeight: .infinity)
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
            .frame(height: 44)
            HStack {
                Text(Format.clock(position)).font(.rounded(13, .bold))
                Spacer()
                Text(Format.timeLeft(max(0, duration - position), rate: player.rate)).font(.text(13.5, .bold)).foregroundStyle(NP.fg)
                Spacer()
                Text(Format.remainingClock(max(0, duration - position))).font(.rounded(13, .bold))
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
        .accessibilityIdentifier("nowPlaying.scrubber")
    }

    /// Where each chapter after the first starts, as a fraction of the episode.
    private func chapterMarks(_ duration: Double) -> [Double] {
        let chapters = player.chapters
        guard chapters.count > 1 else { return [] }
        return chapters.dropFirst().map { $0.start / duration }.filter { $0 > 0 && $0 < 1 }
    }
}

private struct Transport: View {
    @Environment(\.player) private var player
    @State private var pressed = 0

    var body: some View {
        HStack(spacing: 30) {
            skip(back: true)
            Button { player.togglePlayPause(); pressed += 1 } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(Palette.onTomato)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 88, height: 88)
                    .background {
                        Circle().fill(Fills.bigPlay)
                            .overlay(Circle().inset(by: 1.5).stroke(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center), lineWidth: 2.5))
                            .background(Circle().fill(Color(hex: 0x9E2412)).offset(y: 4))
                            .floatShadow(12, y: 10, opacity: 0.3)
                    }
            }
            .buttonStyle(PressableStyle(scale: 0.93))
            .sensoryFeedback(.impact(weight: .medium), trigger: pressed)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("nowPlaying.playPause")
            skip(back: false)
        }
    }

    private func skip(back: Bool) -> some View {
        let seconds = Int(back ? player.skipBack : player.skipForward)
        return Button { back ? player.skipBackTapped() : player.skipForwardTapped() } label: {
            Image(systemName: back ? "gobackward.\(seconds)" : "goforward.\(seconds)")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(NP.fg)
                .frame(width: 66, height: 66)
                .raised(Circle(), fill: NP.util)
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
        .accessibilityIdentifier(back ? "nowPlaying.skipBack" : "nowPlaying.skipForward")
    }
}

/// Speed, sleep timer, AirPlay and the queue, on puffy cream tiles. Poodle Trim, Even Volume and
/// the rest live on the settings page; tapping the speed goes there.
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
                        .font(.rounded(18, .heavy)).monospacedDigit().tracking(-0.3)
                        .foregroundStyle(Palette.tomato)
                        .contentTransition(.numericText(value: resolved.speed.value))
                        .frame(width: 60, height: 50)
                        .raised(RoundedRectangle(cornerRadius: 18, style: .continuous), fill: custom ? Palette.goldBg : NP.util)
                    VStack(spacing: 0) {
                        Text("Speed").fontWeight(.bold).foregroundStyle(NP.fg)
                        Text(resolved.smartSpeed.value ? "\(Format.saved(player.smartSaved)) saved" : custom ? "This show" : "Default")
                            .lineLimit(1)
                    }
                    .font(.text(11.5, .semibold))
                    .foregroundStyle(NP.fg2)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Speed \(Format.speed(resolved.speed.value)). Playback settings")
            .accessibilityIdentifier("nowPlaying.speed")
            SleepMenu()
            AirPlayUtil()
            Button { app.nowPlayingSheet = .queue } label: {
                UtilityLabel(title: "Up Next", detail: "\(store.upNext(excluding: item.id).count) more", icon: "list.bullet", on: false)
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("nowPlaying.queue")
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
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(on ? Palette.tomato : NP.fg)
                .frame(width: 50, height: 50)
                .raised(RoundedRectangle(cornerRadius: 18, style: .continuous), fill: on ? Palette.blush : NP.util)
            VStack(spacing: 0) {
                Text(title).fontWeight(.bold).foregroundStyle(NP.fg)
                Text(detail).lineLimit(1)
            }
            .font(.text(11.5, .semibold))
            .foregroundStyle(NP.fg2)
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
            VStack(spacing: 5) {
                // Asleep and breathing while a timer's running.
                Companion(pose: .sleeping, motion: player.sleepTimer == .off ? .still : .breathe, size: 46, tappable: false)
                    .frame(width: 50, height: 50)
                    .background {
                        if player.sleepTimer != .off {
                            Color.clear.raised(RoundedRectangle(cornerRadius: 18, style: .continuous), fill: Palette.blush)
                        }
                    }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 0) {
                        Text("Sleep").fontWeight(.bold).foregroundStyle(NP.fg)
                        Text(detail).foregroundStyle(NP.fg2)
                    }
                    .font(.text(11.5, .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("nowPlaying.sleep")
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
            .overlay(alignment: .top) { RoutePicker().frame(width: 50, height: 50) }
            .accessibilityIdentifier("nowPlaying.airplay")
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
