import SwiftUI
import PoddleKit

/// Everything that can differ per show. Rows still following your defaults say "Default" in grey,
/// anything overridden turns gold.
struct ShowSettingsSheet: View {
    var podcastId: String
    @Environment(PoddleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var s: PodcastSettings { store.settings(for: podcastId) }
    private var r: ResolvedSettings { store.resolved(podcastId) }
    private var g: GlobalSettings { store.global }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                head
                GroupLabel(text: "Playback")
                GroupCard {
                    VStack(spacing: 0) {
                        PoddleSegmented(
                            options: [(false, "Use default · \(Format.speed(g.speed))"), (true, "Custom")],
                            selection: Binding(get: { s.speed != nil }, set: { custom in
                                update { $0.speed = custom ? ($0.speed ?? g.speed) : nil }
                            }),
                            pinned: true
                        )
                        .padding(.horizontal, 16).padding(.top, 12)
                        SpeedSliderRow(value: r.speed.value, isCustom: s.speed != nil, defaultSpeed: g.speed) { v in
                            update { $0.speed = v }
                        }
                    }
                    boolMenu("Smart Speed", key: \.smartSpeed, global: g.smartSpeed)
                    boolMenu("Voice Boost", key: \.voiceBoost, global: g.voiceBoost)
                }

                GroupLabel(text: "Skip")
                GroupCard {
                    Cell(title: "Skip first", subtitle: s.skipIntro.map { $0 > 0 ? "Jumps the cold-open ads" : nil } ?? nil) {
                        WellStepper(text: secondsText(r.skipIntro.value), muted: r.skipIntro.value == 0, gold: s.skipIntro != nil,
                                    onDecrement: { stepSeconds(\.skipIntro, -5) }, onIncrement: { stepSeconds(\.skipIntro, 5) })
                    }
                    Cell(title: "Skip last", subtitle: (s.skipOutro ?? 0) > 0 ? "Stops before the outro" : nil) {
                        WellStepper(text: secondsText(r.skipOutro.value), muted: r.skipOutro.value == 0, gold: s.skipOutro != nil,
                                    onDecrement: { stepSeconds(\.skipOutro, -5) }, onIncrement: { stepSeconds(\.skipOutro, 5) })
                    }
                }

                GroupLabel(text: "New episodes")
                PoddleSegmented(
                    options: [(AutoAdd.inbox, "Inbox"), (.upNextTop, "Top"), (.upNextBottom, "Bottom"), (.dontAdd, "Don't add")],
                    selection: Binding(get: { r.autoAdd.value }, set: { v in update { $0.autoAdd = v == g.autoAdd ? nil : v } }),
                    height: 40, fontSize: 13
                )
                .padding(6)
                .card(cornerRadius: 16)
                .padding(.horizontal, 16)
                Text(r.isPriority ? "A priority show: new episodes skip the Inbox." : "New episodes wait in the Inbox for you.")
                    .font(.text(12.5)).foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32).padding(.top, 8)

                GroupLabel(text: "Library")
                GroupCard {
                    Toggle(isOn: Binding(get: { r.autoDownload.value }, set: { v in update { $0.autoDownload = v == g.autoDownload ? nil : v } })) {
                        label("Auto-download", isOverride: s.autoDownload != nil)
                    }
                    .toggleStyle(.poddle).padding(.horizontal, 16).frame(minHeight: 50)
                    Cell(title: "Keep latest") {
                        WellStepper(text: "\(r.keepLatest.value) eps", gold: s.keepLatest != nil,
                                    onDecrement: { stepKeep(-1) }, onIncrement: { stepKeep(1) })
                    }
                    enumMenu("Episode order", key: \.episodeOrder, all: EpisodeOrder.allCases, global: g.episodeOrder, label: \.label)
                    Toggle(isOn: Binding(get: { r.notifications.value }, set: { v in update { $0.notifications = v == g.notifications ? nil : v } })) {
                        label("Notifications", isOverride: s.notifications != nil)
                    }
                    .toggleStyle(.poddle).padding(.horizontal, 16).frame(minHeight: 50)
                    enumMenu("Auto-archive unplayed", key: \.autoArchive, all: AutoArchive.allCases, global: g.autoArchive, label: \.label)
                }

                GroupLabel(text: "Advanced")
                GroupCard {
                    enumMenu("Time-pitch", key: \.timePitch, all: TimePitchAlgorithm.allCases, global: g.timePitch, label: \.label)
                }

                if s.hasOverrides {
                    Button {
                        withAnimation { store.updateSettings(podcastId) { $0 = PodcastSettings(podcastId: $0.podcastId) } }
                    } label: {
                        Text("Reset everything to my defaults").font(.text(15, .semibold)).foregroundStyle(Palette.tomato)
                            .frame(maxWidth: .infinity).frame(height: 48)
                    }
                    .padding(.top, 18)
                }
                Spacer(minLength: 30)
            }
        }
        .scrollContentBackground(.hidden)
        .poddleSheet(detents: [.large])
        .animation(.snappy, value: s)
    }

    private var head: some View {
        HStack(spacing: 12) {
            if let p = store.podcast(podcastId) { ArtworkView(podcast: p, size: 52, cornerRadius: 12) }
            VStack(alignment: .leading, spacing: 1) {
                Text(store.podcast(podcastId)?.title ?? "").font(.rounded(17, .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text("Settings for this show only").font(.text(13, .medium)).foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 4)
            TextButton(title: "Done", bold: true) { dismiss() }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.top, 26).padding(.bottom, 4)
    }

    private func update(_ change: (inout PodcastSettings) -> Void) { store.updateSettings(podcastId, change) }

    private func label(_ title: String, isOverride: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.text(16)).foregroundStyle(Palette.ink)
            if isOverride { PinGlyph().frame(width: 12, height: 12).foregroundStyle(Palette.goldInk) }
        }
    }

    private func secondsText(_ v: Double) -> String { v == 0 ? "Off" : "\(Int(v)) s" }

    private func stepSeconds(_ key: WritableKeyPath<PodcastSettings, Double?>, _ delta: Double) {
        update { s in
            let current = s[keyPath: key] ?? 0
            let next = min(600, max(0, current + delta))
            s[keyPath: key] = next == 0 ? nil : next
        }
    }

    private func stepKeep(_ delta: Int) {
        update { s in
            let next = min(50, max(1, (s.keepLatest ?? g.keepLatest) + delta))
            s.keepLatest = next == g.keepLatest ? nil : next
        }
    }

    private func boolMenu(_ title: String, key: WritableKeyPath<PodcastSettings, Bool?>, global: Bool) -> some View {
        let current = s[keyPath: key]
        let text = current.map { $0 ? "On for this show" : "Off for this show" } ?? "Default (\(global ? "on" : "off"))"
        return Menu {
            Picker(title, selection: Binding(get: { current }, set: { v in update { $0[keyPath: key] = v } })) {
                Text("Use default (\(global ? "on" : "off"))").tag(Bool?.none)
                Text("On for this show").tag(Bool?.some(true))
                Text("Off for this show").tag(Bool?.some(false))
            }
        } label: {
            Cell(title: title) { MenuValue(text: text, isOverride: current != nil) }
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
    }

    private func enumMenu<V: Hashable>(_ title: String, key: WritableKeyPath<PodcastSettings, V?>, all: [V], global: V, label: KeyPath<V, String>) -> some View {
        let current = s[keyPath: key]
        let text = current.map { $0[keyPath: label] } ?? "\(global[keyPath: label]) (default)"
        return Menu {
            Picker(title, selection: Binding(get: { current }, set: { v in update { $0[keyPath: key] = v } })) {
                Text("Use default (\(global[keyPath: label]))").tag(V?.none)
                ForEach(all, id: \.self) { Text($0[keyPath: label]).tag(V?.some($0)) }
            }
        } label: {
            Cell(title: title) { MenuValue(text: text, isOverride: current != nil) }
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
    }
}

/// "Speed  − 1.20× +" plus a 0.5–3.0× slider with a DEFAULT marker.
private struct SpeedSliderRow: View {
    var value: Double
    var isCustom: Bool
    var defaultSpeed: Double
    var onChange: (Double) -> Void
    @State private var drag: Double?

    var body: some View {
        let shown = drag ?? value
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Text("Speed").font(.text(16)).foregroundStyle(Palette.ink)
                HStack {
                    RepeatButton(systemImage: "minus", label: "Slower") { onChange(Speed.snap(value - 0.05)) }
                    Spacer()
                    Text(Format.speedPrecise(shown) + "×").font(.rounded(17, .heavy)).monospacedDigit()
                        .foregroundStyle(isCustom ? Palette.ink : Palette.ink3)
                        .contentTransition(.numericText(value: shown))
                    Spacer()
                    RepeatButton(systemImage: "plus", label: "Faster") { onChange(Speed.snap(value + 0.05)) }
                }
                .frame(height: 40)
                .well(cornerRadius: 12)
            }
            .padding(.top, 12)

            GeometryReader { geo in
                let w = geo.size.width
                let x = { (v: Double) -> CGFloat in CGFloat((v - 0.5) / 2.5) * w }
                ZStack(alignment: .topLeading) {
                    Text("DEFAULT").font(.rounded(9, .bold)).tracking(0.36).foregroundStyle(Palette.ink3)
                        .fixedSize().position(x: x(defaultSpeed), y: 0)
                    Capsule().fill(Palette.well.shadow(.inner(color: Color(hex: 0x5A3719, alpha: 0.15), radius: 1, y: 1)))
                        .frame(height: 5).offset(y: 17)
                    Capsule().fill(Palette.mustard).frame(width: max(5, x(shown)), height: 5).offset(y: 17)
                    ForEach(0..<11) { i in
                        Rectangle().fill(Palette.ink3.opacity(0.6)).frame(width: 1, height: 5)
                            .offset(x: w * CGFloat(i) / 10, y: 26)
                    }
                    Circle()
                        .fill(RadialGradient(colors: [.white, Color(hex: 0xEFE5D6)], center: UnitPoint(x: 0.4, y: 0.3), startRadius: 0, endRadius: 16))
                        .shadow(color: Color(hex: 0x462814, alpha: 0.3), radius: 3, y: 2)
                        .overlay(Capsule().fill(Palette.tomato).frame(width: 2, height: 12))
                        .frame(width: 26, height: 26)
                        .position(x: x(shown), y: 19.5)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in drag = Speed.snap(0.5 + Double(g.location.x / w) * 2.5) }
                        .onEnded { _ in
                            if let d = drag { onChange(d) }
                            drag = nil
                        }
                )
            }
            .frame(height: 34)
            .padding(.top, 10)
            HStack {
                ForEach(["0.5×", "1.0×", "1.5×", "2.0×", "2.5×", "3.0×"], id: \.self) { l in
                    Text(l)
                    if l != "3.0×" { Spacer() }
                }
            }
            .font(.rounded(10.5, .semibold)).foregroundStyle(Palette.ink3)
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
        .sensoryFeedback(.selection, trigger: Speed.detent(shown))
        .opacity(isCustom ? 1 : 0.55)
        .disabled(!isCustom)
    }
}
