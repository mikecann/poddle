import SwiftUI
import PoddleKit

// MARK: - Pins and badges

/// The gold pin: this show has its own setting. "⌒ 1.2×" on rows, "Dwarkesh" in the speed sheet.
struct OverridePin: View {
    var text: String?
    var onDark = false

    var body: some View {
        HStack(spacing: 2) {
            PinGlyph().frame(width: 11, height: 11)
            if let text { Text(text).font(.rounded(11, .bold)) }
        }
        .padding(.leading, 4)
        .padding(.trailing, text == nil ? 4 : 6)
        .padding(.vertical, 1.5)
        .foregroundStyle(onDark ? Color(hex: 0xF2C979) : Palette.goldInk)
        .background(onDark ? Color(hex: 0xE7B24A, alpha: 0.18) : Palette.goldBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .textCase(nil)
        .accessibilityLabel(text.map { "Show's own setting, \($0)" } ?? "Show's own setting")
    }
}

struct PrivateBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock").font(.system(size: 9.5, weight: .bold))
            Text("Private").font(.rounded(11, .bold))
        }
        .padding(.leading, 4).padding(.trailing, 6).padding(.vertical, 1.5)
        .foregroundStyle(Palette.ink2)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .textCase(nil)
    }
}

struct NewDot: View {
    var body: some View { Circle().fill(Palette.tomato).frame(width: 7, height: 7) }
}

struct DownloadGlyph: View {
    var item: EpisodeItem
    var body: some View {
        if item.isDownloaded {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 14)).foregroundStyle(Palette.fern)
                .accessibilityLabel("Downloaded")
        } else if item.isDownloading {
            ProgressView(value: item.download?.progress ?? 0)
                .progressViewStyle(RingProgressStyle())
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "icloud.and.arrow.down").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink3)
                .accessibilityLabel("Not downloaded")
        }
    }
}

struct RingProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle().stroke(Palette.ink3.opacity(0.4), lineWidth: 2)
            Circle().trim(from: 0, to: configuration.fractionCompleted ?? 0)
                .stroke(Palette.fern, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Progress

struct ProgressBar: View {
    var value: Double
    var width: CGFloat? = 40
    var height: CGFloat = 4
    var tint: Color = Palette.tomato
    var track: Color = Palette.ink.opacity(0.12)

    var body: some View {
        Capsule().fill(track)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(tint).frame(width: max(height, geo.size.width * min(1, max(0, value))))
                }
            }
            .frame(width: width, height: height)
            .clipShape(Capsule())
    }
}

// MARK: - Chips

struct Chip: View {
    var title: String
    var count: Int?
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count {
                    Text("\(count)").foregroundStyle(isOn ? Palette.chipOnText.opacity(0.55) : Palette.ink3)
                }
            }
            .font(.text(13, .semibold))
            .foregroundStyle(isOn ? Palette.chipOnText : Palette.ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                if isOn {
                    Capsule().fill(Palette.chipOn).shadow(color: Color(hex: 0x28190F, alpha: 0.3), radius: 1, y: 1)
                }
            }
            .raised(Capsule(), fill: isOn ? .clear : Palette.card)
        }
        .buttonStyle(.pressable)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

/// Small grey tag: "Technology", "3 a week".
struct Tag: View {
    var text: String
    var body: some View {
        Text(text).font(.text(11.5, .semibold)).foregroundStyle(Palette.ink2)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - Buttons

/// Round raised icon button for headers (sort, share, more).
struct RoundIconButton: View {
    var systemImage: String
    var size: CGFloat = 36
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(Palette.tomato)
                .frame(width: size, height: size)
                .raised(Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
    }
}

/// Header text button: "Edit", "Done", "Cancel".
struct TextButton: View {
    var title: String
    var bold = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.text(17, bold ? .semibold : .regular)).foregroundStyle(Palette.tomato)
                .padding(.horizontal, 8).frame(minHeight: 44)
        }
        .buttonStyle(.pressable)
    }
}

struct PoddleButton: View {
    enum Kind { case card, primary, quiet }
    var title: String
    var systemImage: String?
    var kind: Kind = .card
    var large = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: large ? 18 : 15, weight: .semibold)) }
                Text(title)
            }
            .font(.text(large ? 17 : 15, .semibold))
            .foregroundStyle(kind == .primary ? Palette.creamWhite : kind == .quiet ? Palette.tomato : Palette.ink)
            .padding(.horizontal, 14)
            .frame(maxWidth: large ? .infinity : nil)
            .frame(height: large ? 50 : 36)
            .background {
                let shape = RoundedRectangle(cornerRadius: large ? 16 : 12, style: .continuous)
                switch kind {
                case .primary:
                    shape.fill(Fills.tomato)
                        .overlay(shape.inset(by: 0.5).stroke(LinearGradient(colors: [.white.opacity(0.3), .clear, Color(hex: 0x781E0A, alpha: 0.2)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                        .shadow(color: Color(hex: 0xA03C14, alpha: 0.3), radius: 2, y: 2)
                        .shadow(color: Color(hex: 0xA03C14, alpha: 0.18), radius: 7, y: 6)
                case .quiet:
                    shape.fill(Palette.tomato.opacity(0.1))
                case .card:
                    Color.clear.raised(shape)
                }
            }
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - Steppers, segments, toggles

/// "− 45 s +" in a pressed well. Press and hold to repeat.
struct WellStepper: View {
    var text: String
    var muted = false
    var gold = false
    var onDecrement: () -> Void
    var onIncrement: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            RepeatButton(systemImage: "minus", label: "Less", action: onDecrement)
            Text(text)
                .font(.rounded(14, .bold)).monospacedDigit()
                .foregroundStyle(muted ? Palette.ink3 : gold ? Palette.goldInk : Palette.ink)
                .frame(minWidth: 46)
                .contentTransition(.numericText())
            RepeatButton(systemImage: "plus", label: "More", action: onIncrement)
        }
        .frame(height: 32)
        .well(cornerRadius: 10)
    }
}

/// A button that fires once on tap and keeps firing while held.
struct RepeatButton: View {
    var systemImage: String
    var label: String
    var action: () -> Void
    @State private var timer: Task<Void, Never>?
    @State private var ticks = 0

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Palette.ink)
            .frame(width: 34, height: 32)
            .contentShape(Rectangle())
            .onTapGesture { fire() }
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 30) {
            } onPressingChanged: { pressing in
                timer?.cancel()
                guard pressing else { return }
                timer = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    while !Task.isCancelled {
                        fire()
                        try? await Task.sleep(for: .milliseconds(110))
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: ticks)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { fire() }
    }

    private func fire() {
        action()
        ticks += 1
    }
}

/// Segmented control in a pressed well, the selected segment raised on card.
struct PoddleSegmented<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value
    var height: CGFloat = 40
    var fontSize: CGFloat = 14
    var pinned: Value? = nil
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = value }
                } label: {
                    HStack(spacing: 5) {
                        if pinned == value {
                            PinGlyph().frame(width: 15, height: 15).foregroundStyle(Palette.goldInk)
                        }
                        Text(title).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .font(.text(fontSize, .semibold))
                    .foregroundStyle(on ? Palette.ink : Palette.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: height * 0.25, style: .continuous)
                                .fill(Palette.card)
                                .shadow(color: Palette.shadow.opacity(0.18), radius: 1.5, y: 1)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: height)
        .well(cornerRadius: height * 0.32)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Fern when on, a pressed oat track when off.
struct PoddleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill((configuration.isOn ? Palette.fern : Palette.switchOff).shadow(.inner(color: .black.opacity(0.18), radius: 1, y: 1)))
                    .frame(width: 51, height: 31)
                Circle().fill(Color(hex: 0xFFFCF7))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 2)
                    .frame(width: 27, height: 27)
                    .padding(2)
            }
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { configuration.isOn.toggle() }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isOn)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

extension ToggleStyle where Self == PoddleToggleStyle {
    static var poddle: PoddleToggleStyle { PoddleToggleStyle() }
}

// MARK: - Headers

/// "Up Next" style large title with an optional subtitle.
struct LargeTitle: View {
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.rounded(34, .heavy)).tracking(-0.34).foregroundStyle(Palette.ink)
            if let subtitle {
                Text(subtitle).font(.text(14, .medium)).foregroundStyle(Palette.ink2).contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

/// Header row of top bar buttons (right aligned by default).
struct TopBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer()
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }
}

extension TopBar where Leading == EmptyView {
    init(@ViewBuilder trailing: () -> Trailing) {
        self.leading = EmptyView()
        self.trailing = trailing()
    }
}

/// "< Library" back button.
struct BackButton: View {
    var title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold))
                Text(title).font(.text(17))
            }
            .foregroundStyle(Palette.tomato)
            .frame(minHeight: 44)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

/// Section label above a grouped card: "PLAYBACK".
struct GroupLabel: View {
    var text: String
    var body: some View {
        Text(text).capsLabel(12).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 14).padding(.bottom, 6)
    }
}

/// A grouped settings card. Rows are separated with inset hairlines.
struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { i, sub in
                    if i > 0 { Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, 16) }
                    sub
                }
            }
        }
        .card(cornerRadius: 16)
        .padding(.horizontal, 16)
    }
}

/// A plain settings row: label left, accessory right.
struct Cell<Accessory: View>: View {
    var title: String
    var subtitle: String?
    var icon: String?
    var iconTint: Color = Palette.tomato
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.creamWhite)
                    .frame(width: 30, height: 30)
                    .background(iconTint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.text(16)).foregroundStyle(Palette.ink)
                if let subtitle { Text(subtitle).font(.text(12.5)).foregroundStyle(Palette.ink2) }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 16)
        .frame(minHeight: subtitle == nil ? 50 : 60)
    }
}

/// "Default (on)" / "Off for this show" menu value with up-down chevrons.
struct MenuValue: View {
    var text: String
    var isOverride: Bool
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.text(16, isOverride ? .medium : .regular)).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink3)
        }
        .foregroundStyle(isOverride ? Palette.goldInk : Palette.ink2)
    }
}

/// The gold pin's glyph: a little dial arc with its needle.
struct PinGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let c = CGPoint(x: w / 2, y: size.height * 0.78)
            let r = w * 0.4
            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
            var needle = Path()
            needle.move(to: c)
            needle.addLine(to: CGPoint(x: c.x + r * 0.55, y: c.y - r * 0.75))
            let style = StrokeStyle(lineWidth: w * 0.2, lineCap: .round)
            ctx.stroke(arc, with: .foreground, style: style)
            ctx.stroke(needle, with: .foreground, style: style)
        }
        .accessibilityHidden(true)
    }
}
