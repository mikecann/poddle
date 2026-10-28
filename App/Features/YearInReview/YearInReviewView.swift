import SwiftUI
import PoddleKit

/// Your year printed as a till receipt (or a ticket, or a cassette), exported at 1080×1920.
struct YearInReviewView: View {
    @Environment(PoddleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var style: CardStyle = .receipt
    @State private var includePrivate = false
    @State private var rendered: CGImage?
    @State private var copied = 0

    enum CardStyle: String, CaseIterable, Identifiable {
        case receipt = "Receipt", ticket = "Ticket", cassette = "Cassette"
        var id: String { rawValue }
    }

    private var year: Int { Calendar.current.component(.year, from: .now) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .heavy))
                        .frame(width: 42, height: 42)
                        .raised(Circle(), fill: NP.util)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("yearInReview.close")
                Spacer()
                Text("Your \(String(year))").font(.rounded(19, .heavy))
                Spacer()
                Menu {
                    Toggle("Include private shows", isOn: $includePrivate)
                } label: {
                    Image(systemName: includePrivate ? "lock.open" : "lock").font(.system(size: 15, weight: .heavy))
                        .frame(width: 42, height: 42)
                        .raised(Circle(), fill: NP.util)
                }
                .menuStyle(.button).buttonStyle(.plain)
                .accessibilityLabel("Private shows")
                .accessibilityIdentifier("yearInReview.private")
            }
            .foregroundStyle(NP.fg)
            .padding(.horizontal, 14)
            .frame(height: 56)

            if let review = store.yearInReview {
                TabView(selection: $style) {
                    ForEach(CardStyle.allCases) { s in
                        GeometryReader { geo in
                            let scale = min(geo.size.width / YearCard.size.width, geo.size.height / YearCard.size.height)
                            YearCard(review: review, style: s, includePrivate: includePrivate)
                                .clipShape(RoundedRectangle(cornerRadius: 24 / scale * 0.85, style: .continuous))
                                .scaleEffect(scale)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .floatShadow(20, y: 18, opacity: 0.3)
                        }
                        .padding(.horizontal, 40)
                        .padding(.vertical, 6)
                        .tag(s)
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
                .frame(maxHeight: 560)

                PoddleSegmented(options: CardStyle.allCases.map { ($0, $0.rawValue) }, selection: $style, height: 38, fontSize: 14)
                    .frame(maxWidth: 320)
                    .padding(.top, 16)
                    .accessibilityIdentifier("yearInReview.style")
                .sensoryFeedback(.selection, trigger: style)

                HStack(spacing: 10) {
                    Button { copy() } label: {
                        Label(copied > 0 ? "Copied" : "Copy image", systemImage: copied > 0 ? "checkmark" : "doc.on.doc")
                            .font(.text(17, .bold)).foregroundStyle(NP.fg)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .raised(Capsule(), fill: NP.util)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.pressable)
                    .sensoryFeedback(.success, trigger: copied)
                    .accessibilityIdentifier("yearInReview.copy")

                    if let rendered {
                        let image = Image(decorative: rendered, scale: 1)
                        ShareLink(item: image, subject: Text("My \(String(year)) in podcasts"), message: Text(shareText(review)),
                                  preview: SharePreview("My \(String(year)) in podcasts", image: image)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.text(17, .bold)).foregroundStyle(Palette.onTomato)
                                .frame(maxWidth: .infinity).frame(height: 52)
                                .background(Fills.tomato, in: Capsule())
                                .floatShadow(7, y: 5, opacity: 0.25)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("yearInReview.share")
                    }
                }
                .padding(.horizontal, 20).padding(.top, 14)
                Spacer(minLength: 10)
            } else {
                Spacer()
                TrotStrip(message: "Printing your year…")
                Spacer()
            }
        }
        .background { NowPlayingBackground() }
        .task(id: store.accountGeneration) { await store.loadYearInReview(year: year) }
        .task(id: "\(style.rawValue)-\(includePrivate)-\(store.yearInReview?.year ?? 0)") { render() }
    }

    /// Lays the card out at 360×640 points and renders it at 3× for a 1080×1920 PNG.
    @MainActor private func render() {
        guard let review = store.yearInReview else { return }
        let renderer = ImageRenderer(content: YearCard(review: review, style: style, includePrivate: includePrivate)
            .environment(\.colorScheme, .light))
        renderer.scale = 1080 / YearCard.size.width
        renderer.proposedSize = ProposedViewSize(YearCard.size)
        rendered = renderer.cgImage
    }

    private func copy() {
        render()
        guard let rendered else { return }
        #if os(iOS)
        UIPasteboard.general.image = UIImage(cgImage: rendered)
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))])
        #endif
        copied += 1
    }

    private func shareText(_ r: YearInReview) -> String {
        "I listened to \(Format.hours(r.listenedSeconds)) of podcasts in \(r.year) and got \(Format.hours(r.savedSeconds)) back with speed and Poodle Trim."
    }
}

/// One share card, laid out at a fixed 360×640 (9:16).
struct YearCard: View {
    static let size = CGSize(width: 360, height: 640)
    var review: YearInReview
    var style: YearInReviewView.CardStyle
    var includePrivate: Bool

    var body: some View {
        Group {
            switch style {
            case .receipt: ReceiptCard(review: review, shows: shows)
            case .ticket: TicketCard(review: review, shows: shows)
            case .cassette: CassetteCard(review: review, shows: shows)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    /// Top shows for the card. Private feeds stay off share cards unless you opt in.
    var shows: (top: [TopShow], otherCount: Int, otherSeconds: Double) {
        var top = review.topShows
        var otherCount = review.otherShowCount
        var otherSeconds = review.otherShowsSeconds
        if !includePrivate {
            for p in top where p.isPrivate {
                otherCount += 1
                otherSeconds += p.seconds
            }
            top.removeAll(where: \.isPrivate)
        }
        return (Array(top.prefix(5)), otherCount, otherSeconds)
    }
}

private struct CardHeader: View {
    var review: YearInReview
    var ink: Color = Color(hex: 0xFFF3E4)
    var accent: Color = Color(hex: 0xF7CF6E)
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Poddle · \(String(review.year))")
                Spacer()
                Text(String(format: "No. %04d", review.serial))
            }
            .font(.rounded(12, .heavy)).tracking(1.9).textCase(.uppercase).opacity(0.85)
            Text("\(review.listenerName) listened for\n\(Text("\(Int((review.listenedSeconds / 3600).rounded())) hours.").foregroundStyle(accent))")
                .font(.rounded(41, .heavy)).tracking(-1.2)
                .lineSpacing(-6)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 26).padding(.top, 26)
    }
}

private struct CardFooter: View {
    var review: YearInReview
    var ink: Color = Color(hex: 0xFFF3E4)
    var body: some View {
        HStack {
            HStack(spacing: 7) {
                AppMark(size: 22)
                Text("Poddle").font(.rounded(17, .heavy))
            }
            Spacer()
            Text("\(Int((review.savedSeconds / 3600).rounded())) hours back. Not bad.").font(.rounded(13, .bold)).tracking(0.5)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 26).padding(.bottom, 22)
    }
}

private struct Sunburst: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height * 1.02)
            let r = size.height * 1.5
            for i in stride(from: 0, to: 360, by: 12) {
                let a1 = Double(i) * .pi / 180, a2 = Double(i + 6) * .pi / 180
                var p = Path()
                p.move(to: c)
                p.addLine(to: CGPoint(x: c.x + r * cos(a1), y: c.y + r * sin(a1)))
                p.addLine(to: CGPoint(x: c.x + r * cos(a2), y: c.y + r * sin(a2)))
                p.closeSubpath()
                ctx.fill(p, with: .color(color))
            }
        }
    }
}

private struct ReceiptCard: View {
    var review: YearInReview
    var shows: (top: [TopShow], otherCount: Int, otherSeconds: Double)

    private let paper = Color(hex: 0xFFFCF5)
    private let ink = Color(hex: 0x2B2320)
    private let muted = Color(hex: 0x8A7B6C)

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: 0xDD5530)
            Sunburst(color: Color(hex: 0xFFECD2, alpha: 0.09))
            GrainOverlay(opacity: 0.45)
            VStack(spacing: 0) {
                CardHeader(review: review)
                receipt
                    .rotationEffect(.degrees(-2.2))
                    .padding(.top, 20)
                Spacer(minLength: 0)
                CardFooter(review: review)
            }
        }
    }

    private var receipt: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text("PODDLE").font(.rounded(18, .heavy)).tracking(4.3)
                Text("LISTENING RECEIPT · \(String(review.year))").foregroundStyle(muted)
            }
            dash
            ForEach(shows.top) { show in
                line(show.title.uppercased().replacingOccurrences(of: " PODCAST", with: "") + (show.isPrivate ? " (PRIVATE)" : ""), Format.hours(show.seconds))
            }
            // Hidden when every show you heard is already listed above.
            if let others = Format.otherShows(shows.otherCount) {
                line(others, Format.hours(shows.otherSeconds)).foregroundStyle(muted)
            }
            dash
            line("TOTAL LISTENED", Format.hours(review.listenedSeconds)).font(.mono(14, .heavy))
            line("SAVED BY SPEED", "−" + Format.hours(review.savedBySpeedSeconds)).foregroundStyle(Color(hex: 0xB9411F))
            line("SAVED BY POODLE TRIM", "−" + Format.hours(review.savedBySmartSpeedSeconds)).foregroundStyle(Color(hex: 0xB9411F))
            dash
            line("USUAL SPEED", Format.speed(review.usualSpeed))
            line("PEAK HOUR", review.peakHourLabel.uppercased())
            line("LONGEST STREAK", "\(review.longestStreakDays) DAYS")
            Barcode().frame(height: 34).padding(.horizontal, 7).padding(.top, 10).padding(.bottom, 5)
            Text("THANKS FOR LISTENING · COME AGAIN").foregroundStyle(muted)
            if review.includesEstimates {
                Text("INCLUDES ESTIMATED OVERCAST HISTORY").font(.mono(9)).foregroundStyle(muted).padding(.top, 2)
            }
        }
        .font(.mono(12, .medium))
        .foregroundStyle(ink)
        .lineLimit(1)
        .padding(.horizontal, 17).padding(.top, 17).padding(.bottom, 14)
        .frame(width: 283)
        .background(ReceiptShape(tooth: 9, depth: 7, tornTop: true).fill(paper))
        .shadow(color: Color(hex: 0x501405, alpha: 0.55), radius: 12, y: 14)
        .shadow(color: Color(hex: 0x501405, alpha: 0.25), radius: 2, y: 2)
    }

    private var dash: some View {
        HLine().stroke(Color(hex: 0xBFAF98), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    private func line(_ left: String, _ right: String) -> some View {
        HStack {
            Text(left).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(right)
        }
        .frame(height: 17.4)
    }
}

private struct Barcode: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 0
            var i = 0
            let pattern: [CGFloat] = [1, 2, 1, 1, 3, 1, 2, 2, 1, 3, 1, 1, 2, 1, 1, 2, 3, 1]
            while x < size.width {
                let w = pattern[i % pattern.count]
                if i % 2 == 0 { ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Color(hex: 0x2B2320))) }
                x += w + (i % 3 == 0 ? 1 : 0)
                i += 1
            }
        }
    }
}

private struct TicketCard: View {
    var review: YearInReview
    var shows: (top: [TopShow], otherCount: Int, otherSeconds: Double)

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: 0x2E6E68)
            GrainOverlay(opacity: 0.45)
            VStack(spacing: 0) {
                CardHeader(review: review, accent: Color(hex: 0xF2C14E))
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("ADMIT ONE").font(.rounded(12, .heavy)).tracking(2)
                        Spacer()
                        Text("SEASON \(String(review.year))").font(.rounded(12, .heavy)).tracking(2)
                    }
                    .foregroundStyle(Color(hex: 0x7E5410))
                    HStack(spacing: 0) {
                        stat("\(Int((review.savedSeconds / 3600).rounded()))h", "saved")
                        stat(Format.speed(review.usualSpeed), "usual speed")
                        stat("\(review.longestStreakDays)", "day streak")
                    }
                    .padding(.vertical, 14)
                    Text("HEADLINERS").font(.rounded(11, .heavy)).tracking(1.6).foregroundStyle(Color(hex: 0x7E5410))
                    ForEach(Array(shows.top.prefix(3).enumerated()), id: \.offset) { i, s in
                        HStack {
                            Text("\(i + 1). \(s.title)").font(.rounded(16, .bold)).lineLimit(1)
                            Spacer()
                            Text(Format.hours(s.seconds)).font(.rounded(15, .heavy)).monospacedDigit()
                        }
                        .padding(.top, 6)
                    }
                }
                .foregroundStyle(Color(hex: 0x3B2A0B))
                .padding(20)
                .background(TicketShape(notchFromTrailing: 30).fill(LinearGradient(colors: [Color(hex: 0xEDBE5A), Color(hex: 0xE2A93E)], startPoint: .top, endPoint: .bottom)))
                .rotationEffect(.degrees(1.5))
                .padding(.horizontal, 24).padding(.top, 26)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 12)
                Spacer(minLength: 0)
                CardFooter(review: review)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.rounded(26, .heavy)).monospacedDigit()
            Text(label).font(.text(11, .semibold)).opacity(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CassetteCard: View {
    var review: YearInReview
    var shows: (top: [TopShow], otherCount: Int, otherSeconds: Double)

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: 0x211915)
            GrainOverlay(dark: true)
            VStack(spacing: 0) {
                CardHeader(review: review, accent: Color(hex: 0xE5623B))
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SIDE A · \(String(review.year))").font(.rounded(11, .heavy)).tracking(1.5).foregroundStyle(Color(hex: 0xB9411F))
                        ForEach(shows.top.prefix(3)) { s in
                            Text(s.title).font(.system(size: 15, weight: .semibold, design: .serif)).italic().lineLimit(1)
                        }
                    }
                    .foregroundStyle(Color(hex: 0x2B2320))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(hex: 0xF5E1B3), in: RoundedRectangle(cornerRadius: 6))
                    HStack(spacing: 50) { reel; reel }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color(hex: 0x15100D), in: RoundedRectangle(cornerRadius: 10))
                    Text("\(Format.hours(review.listenedSeconds)) · \(Format.speed(review.usualSpeed)) · \(review.longestStreakDays) DAY STREAK")
                        .font(.mono(11, .bold)).foregroundStyle(Color(hex: 0xF4EADB, alpha: 0.7))
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [Color(hex: 0xE5623B), Color(hex: 0xB9411F)], startPoint: .top, endPoint: .bottom)))
                .padding(.horizontal, 26).padding(.top, 26)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 12)
                Spacer(minLength: 0)
                CardFooter(review: review)
            }
        }
    }

    private var reel: some View {
        ZStack {
            Circle().fill(Color(hex: 0xF4EADB)).frame(width: 54, height: 54)
            ForEach(0..<6) { i in
                Capsule().fill(Color(hex: 0x15100D)).frame(width: 5, height: 14).offset(y: -15).rotationEffect(.degrees(Double(i) * 60))
            }
            Circle().fill(Color(hex: 0x15100D)).frame(width: 12, height: 12)
        }
    }
}

nonisolated struct HLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}
