import SwiftUI

// Cloud Fluff: depth comes from puffy surfaces sitting on a solid, slightly lower copy of their own
// shape (cheap, no blur), pressed-in wells, and a real soft shadow only on the few things that float.

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

/// Flat cream, for screen backgrounds. (The v1 paper grain is gone: Cloud Fluff is clean, and a
/// full-screen blend over a scrolling list costs a compositing pass every frame.)
struct PaperBackground: View {
    var color: Color = Palette.paper
    var body: some View {
        color.ignoresSafeArea()
    }
}

extension View {
    /// A puffy raised surface for buttons, chips and pills: fill, a soft top highlight, and a solid
    /// copy of the shape just below it in place of a blurred shadow.
    func raised<S: InsettableShape>(_ shape: S, fill: Color = Palette.card) -> some View {
        background {
            ZStack {
                shape.fill(Palette.cardEdge).offset(y: 2)
                shape.fill(fill)
                shape.inset(by: 0.5).stroke(
                    LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0)], startPoint: .top, endPoint: .center),
                    lineWidth: 1
                )
                .modifier(DarkDim())
            }
        }
    }

    func raised(cornerRadius: CGFloat, fill: Color = Palette.card) -> some View {
        raised(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), fill: fill)
    }

    /// A cloud card, for grouped settings and stats tiles.
    func card(cornerRadius: CGFloat = 22) -> some View {
        cloudCard(cornerRadius: cornerRadius, scallop: 34, depth: 1.8)
    }

    /// A pressed-in well, for steppers, search fields and segmented tracks.
    func well<S: Shape>(_ shape: S, fill: Color = Palette.well) -> some View {
        background {
            shape.fill(fill.shadow(.inner(color: Palette.shadow.opacity(0.16), radius: 1.5, y: 1)))
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

/// Puffy buttons squash a little when you press them.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .offset(y: configuration.isPressed ? 1.5 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}
