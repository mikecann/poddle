import SwiftUI
import PoddleKit

/// The walnut mini player that sits above the tab bar on every tab.
/// Tap or swipe up to expand, swipe sideways to skip, long press for the queue.
struct MiniPlayer: View {
    @Environment(\.player) private var player
    @Environment(AppModel.self) private var app
    @State private var drag: CGSize = .zero
    @State private var skipped = 0

    var body: some View {
        if let item = player.item {
            HStack(spacing: 12) {
                ArtworkView(podcast: item.podcast, size: 44, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.episode.title).font(.text(15, .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(Format.timeLeft(player.remaining, rate: player.rate)).monospacedDigit()
                        if item.speed.isOverride { OverridePin(text: nil, onDark: true) }
                    }
                    .font(.text(12.5, .medium))
                    .foregroundStyle(Palette.cream.opacity(0.6))
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                        .frame(width: 44, height: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skipForwardTapped() } label: {
                    Image(systemName: "goforward.\(Int(player.skipForward))")
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Skip forward \(Int(player.skipForward)) seconds")
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Palette.cream)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 64)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Fills.mini)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).inset(by: 0.5).stroke(.white.opacity(0.08), lineWidth: 1).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
                    .shadow(color: Color(hex: 0x321E0F, alpha: 0.28), radius: 10, y: 8)
                    .shadow(color: Color(hex: 0x321E0F, alpha: 0.2), radius: 2, y: 2)
            }
            .overlay(alignment: .bottomLeading) {
                ProgressBar(value: player.progress, width: nil, height: 3, tint: Palette.mustard, track: Palette.cream.opacity(0.12))
                    .padding(.leading, 66).padding(.trailing, 16).padding(.bottom, 6)
            }
            .offset(x: drag.width * 0.25, y: min(0, drag.height) * 0.3)
            .contentShape(RoundedRectangle(cornerRadius: 20))
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
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Paper tab bar with a hairline on top. Tomato for the selected tab.
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
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 22, weight: .regular))
                            .frame(height: 27)
                        Text(tab.title).font(.text(10, .semibold))
                    }
                    .foregroundStyle(on ? Palette.tomato : Palette.ink3)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.top, 7)
        .padding(.bottom, 2)
        .background {
            Palette.paper.opacity(0.96)
                .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}
