import SwiftUI
import PoddleKit

/// Generated artwork tiles, drawn to match the design's CSS art. Real artwork (when a show has an
/// `artworkURL`) replaces the generated tile once its thumbnail is in.
struct ArtworkView: View {
    var title: String
    var artworkURL: String? = nil
    var size: CGFloat
    var cornerRadius: CGFloat? = nil
    var shadow = true

    init(podcast: Podcast, size: CGFloat, cornerRadius: CGFloat? = nil, shadow: Bool = true) {
        self.title = podcast.title
        self.artworkURL = podcast.artworkURL
        self.size = size
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    init(title: String, artworkURL: String? = nil, size: CGFloat, cornerRadius: CGFloat? = nil, shadow: Bool = true) {
        self.title = title
        self.artworkURL = artworkURL
        self.size = size
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    var body: some View {
        let radius = cornerRadius ?? size * 0.2
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let artworkURL, let url = URL(string: artworkURL) {
                RemoteArtwork(url: url, size: size) { GeneratedArt(style: ArtStyle(title: title), title: title, s: size) }
            } else {
                GeneratedArt(style: ArtStyle(title: title), title: title, s: size)
            }
        }
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.stroke(.black.opacity(0.14), lineWidth: 0.5))
            .shadow(color: shadow ? Color(hex: 0x3C2314, alpha: 0.18) : .clear, radius: 1, y: 1)
            .accessibilityLabel(Text("\(title) artwork"))
    }
}

enum ArtStyle {
    case syntax, hardFork, conan, latent, mike, atp, dwarkesh, changelog, lex, practical, cogRev, noPriors
    case generated(Int)

    init(title: String) {
        let t = title.lowercased()
        switch true {
        case t.contains("syntax"): self = .syntax
        case t.contains("hard fork"): self = .hardFork
        case t.contains("conan"): self = .conan
        case t.contains("latent"): self = .latent
        case t.contains("mike pod"): self = .mike
        case t.contains("accidental tech"), t == "atp": self = .atp
        case t.contains("dwarkesh"): self = .dwarkesh
        case t.contains("changelog"): self = .changelog
        case t.contains("lex fridman"): self = .lex
        case t.contains("practical ai"): self = .practical
        case t.contains("cognitive revolution"): self = .cogRev
        case t.contains("no priors"): self = .noPriors
        default: self = .generated(t.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0xFFFFFF })
        }
    }
}

private struct GeneratedArt: View {
    var style: ArtStyle
    var title: String
    var s: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch style {
            case .syntax:
                Color(hex: 0xF3C53E)
                Text("{ }").font(.system(size: s * 0.15, weight: .heavy, design: .monospaced)).foregroundStyle(Color(hex: 0x1B1A17))
                    .offset(x: s * 0.11, y: s * 0.09)
                stack(["syn", "tax"], size: s * 0.31, weight: .black, color: Color(hex: 0x1B1A17), lineHeight: 0.82, tracking: -0.04)
                    .bottomLeading(s, x: 0.11, y: 0.09)
            case .hardFork:
                Color(hex: 0xD8432E)
                HStack(spacing: s * 0.03) {
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(Color(hex: 0xF7EAD7)).frame(width: s * 0.04, height: s * 0.22) }
                }
                .offset(x: s * 0.65, y: s * 0.12)
                stack(["HARD", "FORK"], size: s * 0.2, weight: .black, color: Color(hex: 0xF7EAD7), lineHeight: 0.88, tracking: -0.01)
                    .bottomLeading(s, x: 0.11, y: 0.10)
            case .conan:
                Color(hex: 0xEF8A26)
                VStack(spacing: s * 0.03) {
                    Text("CONAN").font(.rounded(s * 0.25, .black)).tracking(-s * 0.25 * 0.03)
                    Text("needs a friend").font(.system(size: s * 0.095, weight: .bold, design: .serif)).italic()
                }
                .foregroundStyle(Color(hex: 0x1F2A44))
                .frame(width: s, height: s)
            case .latent:
                Color(hex: 0x123F3F)
                DotGrid(spacing: s * 0.125, dot: s * 0.125 * 0.13, color: Color(hex: 0xF0E4CE, alpha: 0.32))
                stack(["latent", "space"], size: s * 0.18, weight: .bold, color: Color(hex: 0xF2E6D0), lineHeight: 0.95, tracking: -0.02)
                    .bottomLeading(s, x: 0.11, y: 0.10)
            case .mike:
                Color(hex: 0x2B2320)
                stack(["Mike", "Pod"], size: s * 0.2, weight: .black, color: Color(hex: 0xF2C14E), lineHeight: 0.9, tracking: -0.02)
                    .offset(x: s * 0.11, y: s * 0.11)
                Waveform(color: Color(hex: 0xE5623B))
                    .frame(width: s * 0.78, height: s * 0.30)
                    .offset(x: s * 0.11, y: s * 0.58)
            case .atp:
                Color(hex: 0x1E2B47)
                VStack(spacing: 0) {
                    Color.clear.frame(height: s * 0.56)
                    Color(hex: 0xE0812F).frame(height: s * 0.07)
                    Color(hex: 0xF2E6D0).frame(height: s * 0.07)
                    Color(hex: 0x3E8C86).frame(height: s * 0.07)
                    Color.clear
                }
                Text("ATP").font(.rounded(s * 0.27, .black)).tracking(-s * 0.27 * 0.02).foregroundStyle(Color(hex: 0xF2E6D0))
                    .offset(x: s * 0.11, y: s * 0.09)
            case .dwarkesh:
                Color(hex: 0xEADBC0)
                Circle().fill(Color(hex: 0x8F3326).opacity(0.9)).frame(width: s * 0.52, height: s * 0.52)
                    .offset(x: s * 0.6, y: s * 0.6)
                Text("Dwarkesh").font(.system(size: s * 0.175, weight: .semibold, design: .serif)).italic()
                    .foregroundStyle(Color(hex: 0x5A1F18)).fixedSize()
                    .offset(x: s * 0.11, y: s * 0.32)
                Rectangle().fill(Color(hex: 0x8F3326)).frame(width: s * 0.3, height: max(1, s * 0.018))
                    .offset(x: s * 0.11, y: s * 0.54)
                Text("PODCAST").font(.system(size: s * 0.075, weight: .bold)).tracking(s * 0.075 * 0.2)
                    .foregroundStyle(Color(hex: 0x5A1F18)).fixedSize()
                    .offset(x: s * 0.11, y: s * 0.58)
            case .changelog:
                Color(hex: 0x1E3A32)
                ForEach(1..<9) { i in
                    Circle().stroke(Color(hex: 0x2E5A4C), lineWidth: s * 0.02)
                        .frame(width: CGFloat(i) * s * 0.16, height: CGFloat(i) * s * 0.16)
                        .position(x: s * 0.85, y: s * 0.85)
                }
                stack(["the", "change", "log"], size: s * 0.17, weight: .heavy, color: Color(hex: 0xEFE4CF), lineHeight: 0.95, tracking: 0)
                    .offset(x: s * 0.11, y: s * 0.11)
            case .lex:
                Color(hex: 0x141414)
                Circle().stroke(Color(hex: 0xEDE3D3), lineWidth: s * 0.012 + 0.5)
                    .frame(width: s * 0.5, height: s * 0.5)
                    .offset(x: s * 0.25, y: s * 0.18)
                Text("LEX FRIDMAN").font(.system(size: s * 0.075, weight: .semibold)).tracking(s * 0.075 * 0.24)
                    .foregroundStyle(Color(hex: 0xEDE3D3)).fixedSize()
                    .frame(width: s).offset(y: s * 0.8)
            case .practical:
                Color(hex: 0x2D4C7C)
                Circle().fill(Color(hex: 0xEF8A26)).frame(width: s * 0.2, height: s * 0.2).offset(x: s * 0.68, y: s * 0.12)
                stack(["Practical", "AI"], size: s * 0.17, weight: .heavy, color: Color(hex: 0xF4EADB), lineHeight: 0.92, tracking: 0)
                    .bottomLeading(s, x: 0.11, y: 0.10)
            case .cogRev:
                Color(hex: 0xC9D4BD)
                Circle().trim(from: 0, to: 0.75).stroke(Color(hex: 0x4E6A47), lineWidth: s * 0.03)
                    .rotationEffect(.degrees(45))
                    .frame(width: s * 0.34, height: s * 0.34).offset(x: s * 0.11, y: s * 0.12)
                stack(["The Cognitive", "Revolution"], size: s * 0.112, weight: .bold, design: .serif, color: Color(hex: 0x263022), lineHeight: 1, tracking: 0)
                    .bottomLeading(s, x: 0.11, y: 0.10)
            case .noPriors:
                Color(hex: 0xF1ECE2)
                stack(["No", "Priors"], size: s * 0.21, weight: .bold, design: .serif, color: Color(hex: 0x151515), lineHeight: 0.92, tracking: 0)
                    .offset(x: s * 0.11, y: s * 0.14)
                Rectangle().fill(Color(hex: 0x151515)).frame(width: s * 0.78, height: s * 0.03).offset(x: s * 0.11, y: s * 0.83)
            case let .generated(hash):
                let palette: [(UInt32, UInt32)] = [
                    (0x2D4C7C, 0xF4EADB), (0xC9D4BD, 0x263022), (0x8F3326, 0xF7EAD7), (0xF3C53E, 0x1B1A17),
                    (0x123F3F, 0xF2E6D0), (0xEF8A26, 0x1F2A44), (0x3F7F6B, 0xFFF6EC), (0xEADBC0, 0x5A1F18),
                ]
                let (bg, fg) = palette[hash % palette.count]
                Color(hex: bg)
                Circle().fill(Color(hex: fg).opacity(0.18)).frame(width: s * 0.6, height: s * 0.6)
                    .offset(x: s * (0.45 + Double(hash % 3) * 0.05), y: -s * 0.12)
                let words = title.split(separator: " ").prefix(3).map(String.init)
                stack(words.isEmpty ? ["?"] : words, size: s * (words.count > 2 ? 0.15 : 0.19), weight: .heavy, color: Color(hex: fg), lineHeight: 0.95, tracking: -0.01)
                    .bottomLeading(s, x: 0.11, y: 0.10)
            }
        }
        .frame(width: s, height: s, alignment: .topLeading)
    }

    private func stack(
        _ lines: [String], size: CGFloat, weight: Font.Weight, design: Font.Design = .rounded,
        color: Color, lineHeight: CGFloat, tracking: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: size, weight: weight, design: design))
                    .tracking(tracking * size)
                    .fixedSize()
                    .frame(height: size * lineHeight)
            }
        }
        .foregroundStyle(color)
        .lineLimit(1)
    }
}

private extension View {
    func bottomLeading(_ s: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        frame(width: s, height: s, alignment: .bottomLeading)
            .padding(.leading, s * x)
            .padding(.bottom, s * y)
            .frame(width: s, height: s, alignment: .bottomLeading)
    }
}

private struct DotGrid: View {
    var spacing: CGFloat
    var dot: CGFloat
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2)), with: .color(color))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

/// Mike Pod's striped waveform.
private struct Waveform: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let heights: [CGFloat] = [0.16, 0.56, 0.08, 1, 0.4, 0.76, 0.28, 0.9, 0.48, 0.68, 0.2, 0.52, 0.12]
            let bar = size.width * 0.04
            for (i, h) in heights.enumerated() {
                let x = CGFloat(i) * size.width / CGFloat(heights.count - 1) - bar / 2
                let height = max(bar, size.height * h)
                ctx.fill(Path(roundedRect: CGRect(x: x, y: (size.height - height) / 2, width: bar, height: height), cornerRadius: bar / 2), with: .color(color))
            }
        }
    }
}

#Preview {
    let titles = ["Syntax", "Hard Fork", "Conan O'Brien Needs a Friend", "Latent Space", "Mike Pod", "Accidental Tech Podcast",
                  "Dwarkesh Podcast", "The Changelog", "Lex Fridman Podcast", "Practical AI", "The Cognitive Revolution", "No Priors", "Acquired"]
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))]) {
        ForEach(titles, id: \.self) { ArtworkView(title: $0, size: 90) }
    }
    .padding()
    .background(PaperBackground())
}
