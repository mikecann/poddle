import SwiftUI
import PoddleKit

/// Playback speed: a knob that clicks in 0.05× detents, presets, and a scope switch that defaults
/// to "Just this show" if the show already has its own speed, otherwise "All podcasts".
struct SpeedSheet: View {
    var podcastId: String
    @Environment(PoddleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double = 1
    @State private var scope: SpeedScope = .allPodcasts
    @State private var originalGlobal: Double = 1
    @State private var loaded = false

    private var podcast: Podcast? { store.podcast(podcastId) }
    private var showName: String { podcast.map { $0.title.split(separator: " ").first.map(String.init) ?? $0.title } ?? "This show" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextButton(title: "Reset") { reset() }
                Spacer()
                Text("Playback speed").font(.text(17, .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                TextButton(title: "Done", bold: true) { dismiss() }
            }
            .padding(.horizontal, 8)
            .frame(height: 48)
            .padding(.top, 14)

            readout
            ZStack {
                SpeedDial(value: $value, defaultSpeed: store.global.speed, onCommit: commit)
                HStack {
                    stepButton(-1)
                    Spacer()
                    stepButton(1)
                }
                .padding(.horizontal, 22)
                .offset(y: -2)
            }
            .frame(height: 236)
            .padding(.top, 4)

            presets.padding(.top, 6)

            PoddleSegmented(
                options: [(SpeedScope.allPodcasts, "All podcasts"), (SpeedScope.show(podcastId), "Just this show")],
                selection: Binding(get: { scope }, set: { changeScope($0) }),
                pinned: .show(podcastId)
            )
            .padding(.horizontal, 16)
            .padding(.top, 16)

            toggles.padding(.top, 16)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "tuningfork").font(.system(size: 14)).foregroundStyle(Palette.ink3)
                Text("Pitch is corrected at every speed, so nobody sounds like a chipmunk. Not even at 3×.")
                    .font(.text(12.5)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .poddleSheet(detents: [.fraction(0.86), .large])
        .task {
            guard !loaded else { return }
            loaded = true
            scope = store.defaultSpeedScope(for: podcastId)
            value = store.resolved(podcastId).speed.value
            originalGlobal = store.global.speed
            if store.stats == nil { await store.loadStats(year: Calendar.current.component(.year, from: .now)) }
        }
    }

    private var readout: some View {
        VStack(spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(Format.speedPrecise(value))
                    .font(.rounded(54, .heavy)).tracking(-1.6).monospacedDigit()
                    .contentTransition(.numericText(value: value))
                Text("×").font(.rounded(30, .bold)).foregroundStyle(Palette.ink2)
            }
            .foregroundStyle(Palette.ink)
            HStack(spacing: 6) {
                if case .show = scope { OverridePin(text: showName) }
                Text(scope == .allPodcasts ? "For every show without its own speed" : "Your default is \(Format.speedPrecise(store.global.speed))×")
                    .font(.text(13.5, .medium)).foregroundStyle(Palette.ink2)
            }
        }
        .animation(.snappy(duration: 0.15), value: value)
    }

    private func stepButton(_ direction: Int) -> some View {
        VStack(spacing: 4) {
            RepeatButton(systemImage: direction < 0 ? "minus" : "plus", label: direction < 0 ? "Slower" : "Faster") {
                set(value + Double(direction) * 0.05)
            }
            .frame(width: 48, height: 48)
            .raised(Circle())
            Text("0.05×").font(.rounded(11, .semibold)).foregroundStyle(Palette.ink3)
        }
        .offset(y: 16)
    }

    private var presets: some View {
        HStack(spacing: 6) {
            ForEach(Speed.presets, id: \.self) { p in
                let on = abs(p - value) < 0.001
                Button { set(p) } label: {
                    Text(Format.speedNumber(p))
                        .font(.rounded(14, .bold)).monospacedDigit()
                        .foregroundStyle(on ? Palette.chipOnText : Palette.ink)
                        .padding(.horizontal, 9)
                        .frame(minWidth: 44, minHeight: 34)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.chipOn) }
                        }
                        .raised(RoundedRectangle(cornerRadius: 12, style: .continuous), fill: on ? .clear : Palette.card)
                        .overlay(alignment: .topTrailing) {
                            if abs(p - store.global.speed) < 0.001 && scope != .allPodcasts {
                                Circle().fill(Palette.mustard).frame(width: 5, height: 5).padding(4)
                            }
                        }
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.horizontal, 16)
    }

    private var toggles: some View {
        let r = store.resolved(podcastId)
        let saved = store.stats.map { Format.saved($0.savedBySmartSpeedSeconds) } ?? "27h"
        return GroupCard {
            Toggle(isOn: Binding(get: { r.smartSpeed.value }, set: { v in setFlag(\.smartSpeed, v) })) {
                cellLabel("Smart Speed", "Trims silences · saved \(saved) this year", icon: "waveform.path", tint: Palette.mustard)
            }
            .toggleStyle(.poddle)
            .padding(.horizontal, 16).frame(minHeight: 60)
            Toggle(isOn: Binding(get: { r.voiceBoost.value }, set: { v in setFlag(\.voiceBoost, v) })) {
                cellLabel("Voice Boost", "Evens out loud and quiet voices", icon: "speaker.wave.2", tint: Palette.fern)
            }
            .toggleStyle(.poddle)
            .padding(.horizontal, 16).frame(minHeight: 60)
        }
    }

    private func cellLabel(_ title: String, _ subtitle: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.creamWhite)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.text(16)).foregroundStyle(Palette.ink)
                Text(subtitle).font(.text(12.5)).foregroundStyle(Palette.ink2)
            }
        }
    }

    // MARK: - Applying

    private func set(_ v: Double) {
        value = Speed.snap(v)
        commit()
    }

    private func commit() { store.setSpeed(value, scope: scope) }

    private func changeScope(_ new: SpeedScope) {
        guard new != scope else { return }
        switch new {
        case .allPodcasts:
            // The show goes back to following the default, which takes this speed.
            store.updateSettings(podcastId) { $0.speed = nil }
            store.setSpeed(value, scope: .allPodcasts)
        case .show:
            store.setSpeed(value, scope: .show(podcastId))
            store.setSpeed(originalGlobal, scope: .allPodcasts)
        }
        scope = new
    }

    private func reset() {
        switch scope {
        case .allPodcasts:
            store.resetSpeed(scope: .allPodcasts)
            value = store.resolved(podcastId).speed.value
        case .show:
            store.resetSpeed(scope: scope)
            value = store.global.speed
            scope = .allPodcasts
        }
    }

    private func setFlag(_ key: WritableKeyPath<PodcastSettings, Bool?>, _ v: Bool) {
        switch scope {
        case .show: store.updateSettings(podcastId) { $0[keyPath: key] = v }
        case .allPodcasts:
            store.updateGlobal { g in
                if key == \PodcastSettings.smartSpeed { g.smartSpeed = v } else { g.voiceBoost = v }
            }
        }
    }
}

/// The rotary knob: 0.5× to 3.0× over a 270° sweep, clicking every 0.05× with a firmer bump at
/// 1.0× and at your default (the gold dot).
struct SpeedDial: View {
    @Binding var value: Double
    var defaultSpeed: Double
    var onCommit: () -> Void
    @State private var detent = 0
    @State private var bump = 0

    private let radius: CGFloat = 118

    private func angle(for v: Double) -> Double { -135 + (v - 0.5) / 0.05 * 5.4 }

    var body: some View {
        ZStack {
            scale
            // Knurled ring
            Circle()
                .fill(AngularGradient(
                    gradient: Gradient(stops: (0..<60).flatMap { i -> [Gradient.Stop] in
                        let a = Double(i) / 60
                        return [
                            .init(color: Color(hex: 0xD6C6AE), location: a),
                            .init(color: Color(hex: 0xD6C6AE), location: a + 2.5 / 360),
                            .init(color: Color(hex: 0xF4EBDD), location: a + 2.5 / 360),
                            .init(color: Color(hex: 0xF4EBDD), location: a + 6 / 360),
                        ]
                    }),
                    center: .center
                ))
                .frame(width: 150, height: 150)
                .shadow(color: Color(hex: 0x462814, alpha: 0.28), radius: 13, y: 14)
                .shadow(color: Color(hex: 0x462814, alpha: 0.2), radius: 3, y: 3)
            // Knob
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFFFCF6), Color(hex: 0xF3EADC), Color(hex: 0xDDCDB6)],
                                     center: UnitPoint(x: 0.38, y: 0.3), startRadius: 0, endRadius: 90))
                .overlay(Circle().stroke(.white, lineWidth: 2).blur(radius: 1).offset(y: 1).mask(Circle()))
                .shadow(color: Color(hex: 0x462814, alpha: 0.25), radius: 1, y: 1)
                .frame(width: 128, height: 128)
                .overlay {
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: 0xE8673F), Color(hex: 0xC9461F)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 7, height: 22)
                        .offset(y: -64 + 10 + 11)
                        .rotationEffect(.degrees(angle(for: value)))
                }
                .overlay {
                    Circle()
                        .fill(RadialGradient(colors: [Color(hex: 0xFBF5EC), Color(hex: 0xEADFCF)], center: UnitPoint(x: 0.6, y: 0.7), startRadius: 0, endRadius: 40))
                        .shadow(color: Color(hex: 0x5A3C1E, alpha: 0.18), radius: 2, y: 2)
                        .frame(width: 60, height: 60)
                }
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let dx = g.location.x - radius, dy = g.location.y - radius
                    var deg = atan2(dx, -dy) * 180 / .pi // 0 at the top, clockwise
                    deg = min(135, max(-135, deg))
                    let v = Speed.snap(0.5 + (deg + 135) / 5.4 * 0.05)
                    if v != value {
                        value = v
                        if abs(v - 1) < 0.001 || abs(v - defaultSpeed) < 0.001 { bump += 1 } else { detent += 1 }
                    }
                }
                .onEnded { _ in onCommit() }
        )
        .sensoryFeedback(.selection, trigger: detent)
        .sensoryFeedback(.impact(weight: .heavy), trigger: bump)
        .animation(.spring(response: 0.2, dampingFraction: 0.75), value: value)
        .accessibilityElement()
        .accessibilityLabel("Speed dial")
        .accessibilityValue(Format.speed(value))
        .accessibilityAdjustableAction { dir in
            value = Speed.snap(value + (dir == .increment ? 0.05 : -0.05))
            onCommit()
        }
    }

    private var scale: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for i in 0...50 {
                let v = 0.5 + Double(i) * 0.05
                let a = (-135 + Double(i) * 5.4) * .pi / 180
                let major = i % 10 == 0, mid = i % 5 == 0
                let r1: CGFloat = 114, r2: CGFloat = major ? 100 : mid ? 104 : 108
                let on = v <= value + 1e-6
                var p = Path()
                p.move(to: CGPoint(x: c.x + r1 * sin(a), y: c.y - r1 * cos(a)))
                p.addLine(to: CGPoint(x: c.x + r2 * sin(a), y: c.y - r2 * cos(a)))
                let color: Color = on ? Palette.tomato : Palette.ink3.opacity(major ? 1 : 0.7)
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: major ? 2.5 : mid ? 2 : 1.4, lineCap: .round))
                if major {
                    let lr: CGFloat = 88
                    let label = v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v)
                    ctx.draw(Text(label).font(.rounded(10, .semibold)).foregroundStyle(Palette.ink3),
                             at: CGPoint(x: c.x + lr * sin(a), y: c.y - lr * cos(a)))
                }
            }
            let da = (-135 + (defaultSpeed - 0.5) / 0.05 * 5.4) * .pi / 180
            let dr: CGFloat = 121
            ctx.fill(Path(ellipseIn: CGRect(x: c.x + dr * sin(da) - 3.5, y: c.y - dr * cos(da) - 3.5, width: 7, height: 7)), with: .color(Palette.mustard))
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}
