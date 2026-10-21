import SwiftUI

// Depth comes from soft shadows, pressed-in wells and a fine paper grain instead of glass.

/// A tileable fractal-ish noise tile, tinted warm brown like the design's feTurbulence grain.
enum Grain {
    static let image: CGImage = {
        let size = 180
        var rng = SplitMix(seed: 0x9D0D1E)
        // Two octaves of value noise so it reads as paper fibre, not TV static.
        let coarse = (0..<(size * size / 4)).map { _ in Double(rng.next() % 1000) / 1000 }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let fine = Double(rng.next() % 1000) / 1000
                let c = coarse[(y / 2) * (size / 2) + (x / 2)]
                let n = max(0, min(1, fine * 0.65 + c * 0.35))
                let a = n * 0.55
                let i = (y * size + x) * 4
                // Premultiplied rgba of (0.35, 0.22, 0.10) at alpha a.
                pixels[i] = UInt8(255 * 0.35 * a)
                pixels[i + 1] = UInt8(255 * 0.22 * a)
                pixels[i + 2] = UInt8(255 * 0.10 * a)
                pixels[i + 3] = UInt8(255 * a)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }()

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}

/// The paper grain, laid over a surface. Multiply on paper, soft light on walnut.
struct GrainOverlay: View {
    var opacity: Double = 0.32
    var dark = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(decorative: Grain.image, scale: 2)
            .resizable(resizingMode: .tile)
            .blendMode(dark || scheme == .dark ? .softLight : .multiply)
            .opacity(dark || scheme == .dark ? 0.5 : opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Paper plus grain, for screen backgrounds.
struct PaperBackground: View {
    var color: Color = Palette.paper
    var body: some View {
        color.overlay(GrainOverlay()).ignoresSafeArea()
    }
}

extension View {
    /// A raised card surface: highlight on top, soft two-layer shadow below (the design's --raise).
    func raised<S: InsettableShape>(_ shape: S, fill: Color = Palette.card) -> some View {
        background {
            shape.fill(fill)
                .overlay {
                    shape.inset(by: 0.5).stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.85), location: 0),
                                .init(color: .white.opacity(0), location: 0.25),
                                .init(color: .clear, location: 0.8),
                                .init(color: Color(hex: 0x5A3C1E, alpha: 0.06), location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .modifier(DarkDim())
                }
                .shadow(color: Palette.shadow.opacity(0.16), radius: 1, y: 1)
                .shadow(color: Palette.shadow.opacity(0.07), radius: 5, y: 4)
        }
    }

    func raised(cornerRadius: CGFloat, fill: Color = Palette.card) -> some View {
        raised(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), fill: fill)
    }

    /// A flat card with a hairline, for grouped settings and stats tiles.
    func card(cornerRadius: CGFloat = 16) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Palette.card)
                .shadow(color: Palette.shadow.opacity(0.08), radius: 1, y: 1)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Palette.shadow.opacity(0.06), lineWidth: 0.5)
                }
        }
    }

    /// A pressed-in well, for steppers, search fields and segmented tracks.
    func well<S: Shape>(_ shape: S, fill: Color = Palette.well) -> some View {
        background {
            shape.fill(fill.shadow(.inner(color: Color(hex: 0x5A3719, alpha: 0.16), radius: 1.5, y: 1)))
        }
    }

    func well(cornerRadius: CGFloat, fill: Color = Palette.well) -> some View {
        well(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), fill: fill)
    }
}

/// The white top highlight is too bright on warm dark.
private struct DarkDim: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View { content.opacity(scheme == .dark ? 0.1 : 1) }
}

/// Buttons sink a point when you press them.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}
