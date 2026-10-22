import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Tokens for "Cloud Fluff" (designs/explore-poodle/fluff.jpg, decisions.md "Look, v2"): warm cream,
// apricot and blush, deep cocoa ink, and tomato as the one strong accent. Body text on every
// surface clears WCAG AA (4.5:1) in both modes; the pairs are noted beside the colours.

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
    /// Screen background: cream, or warm cocoa in dark mode.
    static let paper = Color(light: 0xFDF4E8, dark: 0x1F1613)
    /// Sidebars and sheets' wells: apricot cream.
    static let paper2 = Color(light: 0xFAE6D2, dark: 0x271B17)
    /// Cloud cards, the mini player and puffy buttons.
    static let card = Color(light: 0xFFFAF3, dark: 0x2E211C)
    /// The cheap "shadow": a solid copy of a card's shape drawn a couple of points lower.
    static let cardEdge = Color(light: 0xEED3BF, dark: 0x120B09)
    static let well = Color(light: 0xF7E4D3, dark: 0x170F0D)
    /// Ink on cream 13.8:1, ink2 7.1:1, ink3 4.9:1 (and 5.6:1 on cocoa).
    static let ink = Color(light: 0x3B1F18, dark: 0xFBEDE2)
    static let ink2 = Color(light: 0x6E4A3F, dark: 0xFBEDE2, darkAlpha: 0.74)
    static let ink3 = Color(light: 0x85625A, dark: 0xFBEDE2, darkAlpha: 0.56)
    static let line = Color(light: 0x6E3A22, lightAlpha: 0.11, dark: 0xFBEDE2, darkAlpha: 0.10)
    static let body = Color(light: 0x4E3229, dark: 0xFBEDE2, darkAlpha: 0.82)

    /// The one strong accent. 4.7:1 on cream, 5.1:1 under white text; brighter on cocoa (6.3:1).
    static let tomato = Color(light: 0xCF331C, dark: 0xFF6B4E)
    /// Tomato for small text on blush (Now Playing): 5.2:1.
    static let tomatoText = Color(light: 0xA92815, dark: 0xFF8A70)
    static let tomatoDark = Color(light: 0xA92815, dark: 0xFF8A70)
    /// Soft tints: chips' counts, selected rows, the curl bar's track.
    static let apricot = Color(light: 0xFBDDBF, dark: 0x4A2E22)
    static let blush = Color(light: 0xFBE2D8, dark: 0x3A2320)
    static let blushDeep = Color(light: 0xF6CDBE, dark: 0x4A2A25)
    static let mustard = Color(light: 0xD08221, dark: 0xF0B862)
    static let goldBg = Color(light: 0xFBE5C2, dark: 0xF0B862, darkAlpha: 0.18)
    static let goldInk = Color(light: 0x7A4E0E, dark: 0xF5CC85)
    /// "Downloaded" and "following": status, never decoration.
    static let fern = Color(light: 0x2F7A5F, dark: 0x6CC09F)
    static let teal = Color(hex: 0x2E6E68)
    static let walnut = Color(hex: 0x3B1F18)
    static let switchOff = Color(light: 0xEBD3C2, dark: 0x4A3630)
    static let chipOn = Color(hex: 0xCF331C)
    static let chipOnText = Color.white
    /// Text and glyphs on a tomato fill (5.1:1).
    static let onTomato = Color.white
    /// Toasts are the one inverted surface, so they stand apart from the cream mini player.
    static let inverse = Color(light: 0x3B1F18, dark: 0xFBEDE2)
    static let inverseInk = Color(light: 0xFBEDE2, dark: 0x3B1F18)
    static let inverseAccent = Color(light: 0xFFB59E, dark: 0xCF331C)
    static let cream = Color(hex: 0xFBEDE2)
    static let creamWhite = Color(hex: 0xFFFAF3)
    static let shadow = Color(light: 0x8A4A2C, dark: 0x000000)
    static let wash = Color(light: 0x8A4A2C, lightAlpha: 0.08, dark: 0xFBEDE2, darkAlpha: 0.08)
}

/// Gradients for actions and the big play button.
enum Fills {
    static let tomato = LinearGradient(colors: [Color(hex: 0xDA3F25), Color(hex: 0xC62F19)], startPoint: .top, endPoint: .bottom)
    static let actionTomato = LinearGradient(colors: [Color(hex: 0xDA3F25), Color(hex: 0xC62F19)], startPoint: .top, endPoint: .bottom)
    static let actionFern = LinearGradient(colors: [Color(hex: 0x3D8A6D), Color(hex: 0x2F7259)], startPoint: .top, endPoint: .bottom)
    static let actionGold = LinearGradient(colors: [Color(hex: 0xF7C98A), Color(hex: 0xF0B26A)], startPoint: .top, endPoint: .bottom)
    static let actionInk = LinearGradient(colors: [Color(hex: 0x5A3A30), Color(hex: 0x3B1F18)], startPoint: .top, endPoint: .bottom)
    static let mini = LinearGradient(colors: [Palette.inverse, Palette.inverse], startPoint: .top, endPoint: .bottom)
    static let bigPlay = RadialGradient(
        colors: [Color(hex: 0xEC5A3C), Color(hex: 0xD63A21), Color(hex: 0xBF2D18)],
        center: UnitPoint(x: 0.4, y: 0.3), startRadius: 0, endRadius: 52
    )
    /// Now Playing's blush backdrop: pale blush at the top, deeper towards the controls.
    static let nowPlaying = LinearGradient(
        stops: [
            .init(color: Color(light: 0xFCE6DC, dark: 0x3F2420), location: 0),
            .init(color: Color(light: 0xFADDD0, dark: 0x301C1A), location: 0.55),
            .init(color: Color(light: 0xF9D8CA, dark: 0x24171A), location: 1),
        ],
        startPoint: .top, endPoint: .bottom
    )
}

extension Font {
    /// SF Pro Rounded, for headings and numbers.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Everything else, also rounded so the whole app matches the chunky wordmark. Scales with
    /// Dynamic Type from the given size.
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
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
