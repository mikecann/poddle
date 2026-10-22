import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Tokens from designs/c-earful-warm.html. Warm paper and deep ink, a tomato needle for "now",
// a gold pin wherever a show has its own settings, and fern for "on".

extension Color {
    nonisolated init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// A colour with a warm-dark variant. Nonisolated with a `@Sendable` provider, because
    /// SwiftUI resolves colours off the main thread while animating, and a main-actor closure
    /// there trips Swift's executor check and crashes.
    nonisolated init(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        #if os(iOS)
        self.init(uiColor: UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { @Sendable appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
        #endif
    }
}

#if os(iOS)
extension UIColor {
    nonisolated convenience init(hex: UInt32, alpha: Double) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#else
extension NSColor {
    nonisolated convenience init(hex: UInt32, alpha: Double) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#endif

/// Poddle's palette. Use `Palette.paper` etc.
enum Palette {
    static let paper = Color(light: 0xF5EEE3, dark: 0x1E1713)
    static let paper2 = Color(light: 0xEDE3D4, dark: 0x261D18)
    static let card = Color(light: 0xFBF7F0, dark: 0x2C231E)
    static let well = Color(light: 0xE6DAC8, dark: 0x15100D)
    static let ink = Color(light: 0x2B2320, dark: 0xF4EADB)
    static let ink2 = Color(light: 0x6E6259, dark: 0xF4EADB, darkAlpha: 0.62)
    static let ink3 = Color(light: 0xA39587, dark: 0xF4EADB, darkAlpha: 0.38)
    static let line = Color(light: 0x462D19, lightAlpha: 0.12, dark: 0xF4EADB, darkAlpha: 0.10)
    static let body = Color(light: 0x4A3F38, dark: 0xF4EADB, darkAlpha: 0.78)

    static let tomato = Color(light: 0xDD5530, dark: 0xE5623B)
    static let tomatoDark = Color(light: 0xB9411F, dark: 0xF07A52)
    static let mustard = Color(hex: 0xE7B24A)
    static let goldBg = Color(light: 0xF5E1B3, dark: 0xE7B24A, darkAlpha: 0.18)
    static let goldInk = Color(light: 0x7E5410, dark: 0xF2C979)
    static let fern = Color(light: 0x3F7F6B, dark: 0x5A9C86)
    static let teal = Color(hex: 0x2E6E68)
    static let walnut = Color(hex: 0x211915)
    static let switchOff = Color(light: 0xDED2C0, dark: 0x4A3E36)
    static let chipOn = Color(light: 0x2B2320, dark: 0xF4EADB)
    static let chipOnText = Color(light: 0xF4EADB, dark: 0x2B2320)
    /// Dark cream text used on walnut surfaces in both modes.
    static let cream = Color(hex: 0xF4EADB)
    static let creamWhite = Color(hex: 0xFFF6EC)
    static let shadow = Color(hex: 0x462814)
    static let wash = Color(light: 0x2B2320, lightAlpha: 0.07, dark: 0xF4EADB, darkAlpha: 0.08)
}

/// Gradients for actions and the big play button.
enum Fills {
    static let tomato = LinearGradient(colors: [Color(hex: 0xE5623B), Color(hex: 0xCF4A25)], startPoint: .top, endPoint: .bottom)
    static let actionTomato = LinearGradient(colors: [Color(hex: 0xE3613B), Color(hex: 0xC9461F)], startPoint: .top, endPoint: .bottom)
    static let actionFern = LinearGradient(colors: [Color(hex: 0x4A8C78), Color(hex: 0x3A7563)], startPoint: .top, endPoint: .bottom)
    static let actionGold = LinearGradient(colors: [Color(hex: 0xEDBE5A), Color(hex: 0xDDA43A)], startPoint: .top, endPoint: .bottom)
    static let actionInk = LinearGradient(colors: [Color(hex: 0x4A3F38), Color(hex: 0x2B2320)], startPoint: .top, endPoint: .bottom)
    static let mini = LinearGradient(colors: [Color(hex: 0x352B26), Color(hex: 0x271F1B)], startPoint: .top, endPoint: .bottom)
    static let bigPlay = RadialGradient(
        colors: [Color(hex: 0xEE7149), Color(hex: 0xD24C26), Color(hex: 0xB53D1C)],
        center: UnitPoint(x: 0.4, y: 0.3), startRadius: 0, endRadius: 52
    )
    /// Now Playing's warm dark backdrop.
    static let nowPlaying = RadialGradient(
        stops: [
            .init(color: Color(hex: 0x6A2C22), location: 0),
            .init(color: Color(hex: 0x3A231C), location: 0.45),
            .init(color: Color(hex: 0x211915), location: 0.75),
            .init(color: Color(hex: 0x1C1512), location: 1),
        ],
        center: UnitPoint(x: 0.5, y: 0.24), startRadius: 0, endRadius: 620
    )
}

extension Font {
    /// SF Pro Rounded, for headings and numbers.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// SF Pro Text, for everything else.
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// SF Mono, for receipts.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

extension View {
    /// Small uppercase label: "PLAYBACK", "LISTENED".
    func capsLabel(_ size: CGFloat = 12, color: Color = Palette.ink2) -> some View {
        font(.rounded(size, .bold)).tracking(size * 0.08).textCase(.uppercase).foregroundStyle(color)
    }
}
