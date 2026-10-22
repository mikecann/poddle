import SwiftUI
import PoddleKit

/// Now Playing's right page: the playback settings for what's playing. The "Customize for <show>"
/// toggle at the top decides where edits go (decisions.md): off changes your defaults for every
/// show, on gives this show its own values (starting from the current ones). Turning it off
/// puts the show back on your defaults.
struct PlaybackSettingsPage: View {
    var podcastId: String
    @Environment(PoddleStore.self) private var store
    @Environment(\.player) private var player
    @Environment(AppModel.self) private var app
    /// The dial's value while it's being turned.
    @State private var dialing: Double?

    private var custom: Bool { store.customizesPlayback(podcastId) }
    private var r: ResolvedSettings { store.resolved(podcastId) }
    private var showName: String { store.podcast(podcastId)?.title ?? "this show" }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                customizeCard.padding(.top, 12)
                speed
                toggles.padding(.top, 14)
                method.padding(.top, 14)
                skips.padding(.top, 14)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "tuningfork").font(.system(size: 14)).foregroundStyle(NP.fg3)
                    Text("Pitch is corrected at every speed, so nobody sounds like a chipmunk. Not even at 3×.")
                        .font(.text(12.5)).foregroundStyle(NP.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .animation(.snappy, value: custom)
    }

    // MARK: - Customize toggle

    private var customizeCard: some View {
        HStack(spacing: 12) {
            if let p = store.podcast(podcastId) { ArtworkView(podcast: p, size: 40, cornerRadius: 9) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Customize for \(showName)").font(.text(15.5, .semibold)).foregroundStyle(NP.fg).lineLimit(2)
                HStack(spacing: 4) {
                    if custom { PinGlyph().frame(width: 11, height: 11) } else { Image(systemName: "globe").font(.system(size: 10, weight: .bold)) }
                    Text(custom ? "Just this show, not your defaults" : "Changing your defaults for all podcasts")
                        .lineLimit(2)
                }
                .font(.text(12.5, .medium))
                .foregroundStyle(custom ? Palette.mustard : NP.fg2)
            }
            Spacer(minLength: 4)
            Toggle(isOn: Binding(get: { custom }, set: setCustom)) { EmptyView() }
                .toggleStyle(.poddle)
                .fixedSize()
                .accessibilityLabel("Customize for \(showName)")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(custom ? Palette.mustard.opacity(0.14) : NP.util)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(custom ? Palette.mustard.opacity(0.45) : .clear, lineWidth: 1))
        }
        .padding(.horizontal, 16)
    }

    private func setCustom(_ on: Bool) {
        if on {
            store.setCustomizesPlayback(podcastId, true)
        } else {
            // Turning it off throws the show's own values away, so it gets an Undo.
            let previous = store.settings(for: podcastId)
            store.setCustomizesPlayback(podcastId, false)
            app.undo.show("Back to defaults", showName) { [store, podcastId] in
                store.updateSettings(podcastId) { $0 = previous }
            }
        }
    }

    // MARK: - Speed

    private var speed: some View {
        let value = dialing ?? r.speed.value
        return VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(Format.speedPrecise(value))
                    .font(.rounded(50, .heavy)).tracking(-1.5).monospacedDigit()
                    .contentTransition(.numericText(value: value))
                Text("×").font(.rounded(28, .bold)).foregroundStyle(NP.fg2)
            }
            .foregroundStyle(NP.fg)
            .animation(.snappy(duration: 0.15), value: value)
            .padding(.top, 14)
            Text(custom ? "Your default is \(Format.speedPrecise(store.global.speed))×" : "For every show without its own speed")
                .font(.text(13, .medium)).foregroundStyle(NP.fg2)

            ZStack {
                SpeedDial(
                    value: Binding(get: { dialing ?? r.speed.value }, set: { dialing = $0 }),
                    defaultSpeed: store.global.speed,
                    onCommit: {
                        if let d = dialing { store.setPlaybackSpeed(d, podcastId: podcastId) }
                        dialing = nil
                    }
                )
                HStack {
                    stepButton(-1)
                    Spacer()
                    stepButton(1)
                }
                .padding(.horizontal, 22)
                .offset(y: -2)
            }
            .frame(height: 236)
            .padding(.top, 2)

            presets(value).padding(.top, 6)
        }
    }

    private func stepButton(_ direction: Int) -> some View {
        VStack(spacing: 4) {
            RepeatButton(systemImage: direction < 0 ? "minus" : "plus", label: direction < 0 ? "Slower" : "Faster") {
                store.setPlaybackSpeed(r.speed.value + Double(direction) * Speed.step, podcastId: podcastId)
            }
            .frame(width: 48, height: 48)
            .background(NP.util, in: Circle())
            Text("0.05×").font(.rounded(11, .semibold)).foregroundStyle(NP.fg3)
        }
        .offset(y: 16)
    }

    private func presets(_ value: Double) -> some View {
        HStack(spacing: 6) {
            ForEach(Speed.presets, id: \.self) { p in
                let on = abs(p - value) < 0.001
                Button { store.setPlaybackSpeed(p, podcastId: podcastId) } label: {
                    Text(Format.speedNumber(p))
                        .font(.rounded(14, .bold)).monospacedDigit()
                        .foregroundStyle(on ? Palette.chipOnText : NP.fg)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 42, minHeight: 34)
                        .background(on ? Palette.chipOn : NP.util, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if custom && abs(p - store.global.speed) < 0.001 {
                                Circle().fill(Palette.mustard).frame(width: 5, height: 5).padding(4)
                            }
                        }
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - The rest

    private var toggles: some View {
        GroupCard {
            Toggle(isOn: Binding(get: { r.smartSpeed.value }, set: { v in edit({ $0.smartSpeed = v }, { $0.smartSpeed = v }) })) {
                cellLabel("Smart Speed", "Trims silences · \(Format.saved(player.smartSaved)) saved this episode", icon: "waveform.path", tint: Palette.mustard)
            }
            .toggleStyle(.poddle)
            .padding(.horizontal, 16).frame(minHeight: 60)
            Toggle(isOn: Binding(get: { r.voiceBoost.value }, set: { v in edit({ $0.voiceBoost = v }, { $0.voiceBoost = v }) })) {
                cellLabel("Voice Boost", "Evens out loud and quiet voices", icon: "speaker.wave.2", tint: Palette.fern)
            }
            .toggleStyle(.poddle)
            .padding(.horizontal, 16).frame(minHeight: 60)
        }
    }

    private var method: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speed-up method").font(.rounded(11, .bold)).tracking(1.1).textCase(.uppercase).foregroundStyle(NP.fg2)
                .padding(.horizontal, 32)
            PoddleSegmented(
                options: TimePitchAlgorithm.allCases.map { ($0, $0.label) },
                selection: Binding(get: { r.timePitch.value }, set: { v in edit({ $0.timePitch = v }, { $0.timePitch = v }) }),
                height: 40, fontSize: 13.5
            )
            .padding(.horizontal, 16)
        }
    }

    private var skips: some View {
        GroupCard {
            Cell(title: "Skip intro", subtitle: r.skipIntro.value > 0 ? "Jumps the cold-open ads" : nil) {
                WellStepper(text: secondsText(r.skipIntro.value), muted: r.skipIntro.value == 0, gold: custom,
                            onDecrement: { stepSeconds(\.skipIntro, \.skipIntro, r.skipIntro.value, -5) },
                            onIncrement: { stepSeconds(\.skipIntro, \.skipIntro, r.skipIntro.value, 5) })
            }
            Cell(title: "Skip outro", subtitle: r.skipOutro.value > 0 ? "Stops before the outro" : nil) {
                WellStepper(text: secondsText(r.skipOutro.value), muted: r.skipOutro.value == 0, gold: custom,
                            onDecrement: { stepSeconds(\.skipOutro, \.skipOutro, r.skipOutro.value, -5) },
                            onIncrement: { stepSeconds(\.skipOutro, \.skipOutro, r.skipOutro.value, 5) })
            }
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

    private func edit(_ show: (inout PodcastSettings) -> Void, _ global: (inout GlobalSettings) -> Void) {
        store.editPlayback(podcastId, show: show, global: global)
    }

    private func secondsText(_ v: Double) -> String { v == 0 ? "Off" : "\(Int(v)) s" }

    private func stepSeconds(_ show: WritableKeyPath<PodcastSettings, Double?>, _ global: WritableKeyPath<GlobalSettings, Double>, _ current: Double, _ delta: Double) {
        let next = min(600, max(0, current + delta))
        edit({ $0[keyPath: show] = next }, { $0[keyPath: global] = next })
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
                .shadow(color: .black.opacity(0.45), radius: 13, y: 14)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 3)
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
                let color: Color = on ? Palette.tomato : NP.fg3.opacity(major ? 1 : 0.7)
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: major ? 2.5 : mid ? 2 : 1.4, lineCap: .round))
                if major {
                    let lr: CGFloat = 88
                    let label = v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v)
                    ctx.draw(Text(label).font(.rounded(10, .semibold)).foregroundStyle(NP.fg2),
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
