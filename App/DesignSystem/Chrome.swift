import SwiftUI
import PoddleKit

/// The cloud mini player that sits above the tab bar on every tab, with Poddle peeking over its
/// top edge. Tap or swipe up to expand, swipe sideways to skip, long press for the queue.
struct MiniPlayer: View {
    @Environment(\.player) private var player
    @Environment(AppModel.self) private var app
    @AppStorage(CompanionSettings.showKey) private var showPoddle = true
    @State private var drag: CGSize = .zero
    @State private var skipped = 0

    var body: some View {
        if let item = player.item {
            let roomForPoddle = showPoddle && !app.companion.keyboardUp
            let peeking = roomForPoddle && !app.showNowPlaying && !app.companion.celebrating
            card(item)
                .overlay(alignment: .topTrailing) {
                    if peeking {
                        // His paws rest on the card's top edge, above the transport buttons' hit area.
                        MiniPlayerPeek()
                            .padding(.trailing, 22)
                            .offset(y: 7 - MiniPlayerPeek.frameHeight)
                    }
                }
                .offset(x: drag.width * 0.25, y: min(0, drag.height) * 0.3)
                .padding(.top, roomForPoddle ? MiniPlayerPeek.height : 0)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: peeking)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func card(_ item: EpisodeItem) -> some View {
        HStack(spacing: 12) {
            ArtworkView(podcast: item.podcast, size: 46, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.episode.title).font(.text(15.5, .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                HStack(spacing: 5) {
                    Text(Format.timeLeft(player.remaining, rate: player.rate)).monospacedDigit()
                    if item.speed.isOverride { OverridePin(text: nil) }
                }
                .font(.text(13, .semibold))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                CurlProgressBar(value: player.progress, height: 7)
                    .padding(.top, 3)
                    .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(Palette.tomato)
                    .frame(width: 44, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("miniPlayer.playPause")
            Button { player.skipForwardTapped() } label: {
                Image(systemName: "goforward.\(Int(player.skipForward))")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Skip forward \(Int(player.skipForward)) seconds")
            .accessibilityIdentifier("miniPlayer.skipForward")
        }
        .buttonStyle(.pressable)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 70)
        .background {
            CloudShape(cornerRadius: 24, scallop: 30, depth: 2.2)
                .fill(Palette.card)
                .overlay(CloudShape(cornerRadius: 24, scallop: 30, depth: 2.2).stroke(Palette.line, lineWidth: 0.75))
                .floatShadow(10, y: 6, opacity: 0.2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .onTapGesture { app.showNowPlaying = true }
        .onLongPressGesture { app.sheet = .queue }
        .gesture(
            DragGesture(minimumDistance: 14)
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    let t = v.translation
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = .zero }
                    if t.height < -40, abs(t.height) > abs(t.width) {
                        app.showNowPlaying = true
                    } else if abs(t.width) > 60 {
                        if t.width < 0 { player.skipForwardTapped() } else { player.skipBackTapped() }
                        skipped += 1
                    }
                }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: skipped)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open Now Playing") { app.showNowPlaying = true }
        .accessibilityIdentifier("miniPlayer")
    }
}

/// Cream tab bar with a curl-edged top. Tomato for the selected tab.
struct PoddleTabBar: View {
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                let on = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: on ? tab.selectedImage : tab.systemImage)
                            .font(.system(size: 22, weight: on ? .bold : .medium))
                            .frame(height: 27)
                        Text(tab.title).font(.text(11, on ? .heavy : .semibold))
                    }
                    .foregroundStyle(on ? Palette.tomato : Palette.ink3)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("tab.\(tab.rawValue)")
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 0)
        .background {
            CloudShape(cornerRadius: 0, scallop: 34, depth: 2.4, edges: .top)
                .fill(Palette.card)
                .overlay(CloudShape(cornerRadius: 0, scallop: 34, depth: 2.4, edges: .top).stroke(Palette.line, lineWidth: 0.75))
                .ignoresSafeArea(edges: .bottom)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}
