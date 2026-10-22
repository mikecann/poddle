import SwiftUI
import Charts
import PoddleKit

struct StatsView: View {
    @Environment(PoddleStore.self) private var store
    @Environment(AppModel.self) private var app
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var showAllShows = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TopBar {
                    BrandLockup()
                } trailing: {
                    Menu {
                        Picker("Year", selection: $year) {
                            ForEach(store.years.isEmpty ? [year] : store.years, id: \.self) { Text(String($0)).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(String(year)).font(.rounded(16, .heavy)).monospacedDigit()
                            Image(systemName: "chevron.down").font(.system(size: 12, weight: .heavy))
                        }
                        .foregroundStyle(Palette.tomato)
                        .padding(.horizontal, 16).frame(height: 40)
                        .raised(Capsule())
                    }
                    .menuStyle(.button).buttonStyle(.plain).padding(.horizontal, 6)
                    .accessibilityIdentifier("stats.year")
                }
                .frame(height: 52)
                LargeTitle(title: "Stats").padding(.top, 2)

                if let stats = store.stats {
                    content(stats)
                } else {
                    TrotStrip(message: "Counting up your listening…").padding(.vertical, 50)
                }
            }
            .padding(.bottom, 24)
        }
        // Again for whoever signs in next: signing in clears the store's stats.
        .task(id: "\(year)-\(store.accountGeneration)") { await store.loadStats(year: year) }
        .sheet(isPresented: $showAllShows) {
            if let stats = store.stats { AllShowsSheet(stats: stats) }
        }
    }

    @ViewBuilder private func content(_ s: StatsSummary) -> some View {
        Button { app.showYearInReview = true } label: { ticket }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("stats.yearInReview")
            .padding(.horizontal, 16).padding(.top, 12)

        HStack(alignment: .top, spacing: 10) {
            tile {
                Text("Listened").capsLabel(11)
                bigNumber(Int((s.listenedSeconds / 3600).rounded()), unit: "h")
                Text("About \(Int(s.listenedSeconds / 86_400)) days of ears, \(year == Calendar.current.component(.year, from: .now) ? "this year" : "in \(String(year))")")
                    .font(.text(12.5, .medium)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            tile {
                Text("Time saved").capsLabel(11)
                bigNumber(Int((s.savedSeconds / 3600).rounded()), unit: "h")
                GeometryReader { geo in
                    let speedShare = s.savedSeconds > 0 ? s.savedBySpeedSeconds / s.savedSeconds : 0
                    HStack(spacing: 2) {
                        Palette.tomato.frame(width: max(0, (geo.size.width - 2) * speedShare))
                        Palette.mustard
                    }
                    .accessibilityHidden(true)
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                .padding(.vertical, 6)
                HStack(alignment: .top, spacing: 10) {
                    legend("Speed", Format.hours(s.savedBySpeedSeconds), Palette.tomato)
                    legend("Smart", Format.hours(s.savedBySmartSpeedSeconds), Palette.mustard)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12)

        streak(s).padding(.horizontal, 16).padding(.top, 10)
        heatmap(s).padding(.horizontal, 16).padding(.top, 10)
        topShows(s).padding(.horizontal, 16).padding(.top, 10)

        if let before = s.estimatedBefore {
            Text("Includes estimated history from Overcast before \(Format.monthYear(before)).")
                .font(.text(12.5, .medium)).foregroundStyle(Palette.ink3)
                .padding(.horizontal, 32).padding(.top, 12)
        }
    }

    private var ticket: some View {
        HStack(spacing: 0) {
            Image("Mascot/celebrate").resizable().scaledToFit()
                .frame(width: 58, height: 58)
                .padding(.leading, 12)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Freshly printed").font(.rounded(11, .heavy)).tracking(1.3).textCase(.uppercase).opacity(0.85)
                Text("Your \(String(year)) in review").font(.rounded(19, .heavy)).tracking(-0.19)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 2) {
                Image(systemName: "gift").font(.system(size: 19, weight: .semibold))
                Text("Open").font(.rounded(13, .heavy))
            }
            .frame(width: 84)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Line().stroke(Palette.onTomato.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [4, 3])).frame(width: 2).padding(.vertical, 10)
            }
        }
        .foregroundStyle(Palette.onTomato)
        .frame(height: 80)
        .background {
            TicketShape(notchFromTrailing: 84)
                .fill(Fills.tomato)
                .background(TicketShape(notchFromTrailing: 84).fill(Color(hex: 0x9E2412)).offset(y: 3))
                .floatShadow(9, y: 7, opacity: 0.2)
        }
    }

    private func tile<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
            .card()
    }

    private func bigNumber(_ n: Int, unit: String) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text("\(n)").font(.rounded(34, .heavy)).tracking(-1).monospacedDigit().contentTransition(.numericText(value: Double(n)))
            Text(unit).font(.rounded(18, .bold)).foregroundStyle(Palette.ink2)
        }
        .foregroundStyle(Palette.ink)
        .padding(.top, 2)
    }

    private func legend(_ name: String, _ value: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) { Text(name); Text(value) }
        }
        .font(.text(11, .semibold)).foregroundStyle(Palette.ink2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func streak(_ s: StatsSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.tomato)
                .frame(width: 36, height: 36)
                .background(Palette.blush, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(s.currentStreakDays > 0 ? "\(s.currentStreakDays)-day streak" : "Best streak: \(s.bestStreakDays) days")
                    .font(.rounded(16, .heavy)).foregroundStyle(Palette.ink)
                Text(s.isBestStreak && s.currentStreakDays > 0 ? "Your best ever. Previous was \(s.previousBestStreakDays)." : "At least 10 minutes a day keeps it going.")
                    .font(.text(12, .medium)).foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                ForEach(Array(s.recentDays.enumerated()), id: \.offset) { _, minutes in
                    Capsule().fill(Palette.tomato)
                        .frame(width: 7, height: 18)
                        .opacity(minutes < 45 ? 0.45 : 1)
                }
            }
            .accessibilityLabel("Last ten days")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .card()
    }

    private struct HeatCell: Identifiable {
        var day: Int
        var hour: Int
        var level: Int
        var id: Int { day * 24 + hour }
    }

    private static let heatColors: [Color] = [
        Color(light: 0xEFE6D8, dark: 0x3A2E27), Color(light: 0xF4D5B8, dark: 0x6E4A36),
        Color(hex: 0xEEAA80), Color(hex: 0xE47C51), Color(hex: 0xD2502A),
    ]
    private static let dayLetters = ["M", "T", "W", "T", "F", "S", "S"]

    private func heatmap(_ s: StatsSummary) -> some View {
        let cells = s.heatmap.enumerated().flatMap { d, row in
            row.enumerated().map { h, v in
                HeatCell(day: d, hour: h, level: v <= 0 ? 0 : v < 0.2 ? 1 : v < 0.45 ? 2 : v < 0.75 ? 3 : 4)
            }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("When you listen").font(.rounded(16, .heavy)).foregroundStyle(Palette.ink)
                Spacer()
                Text("Peak: \(s.peakLabel)").font(.text(12, .medium)).foregroundStyle(Palette.ink2)
            }
            Chart(cells) { c in
                RectangleMark(
                    xStart: .value("Hour", Double(c.hour) + 0.06), xEnd: .value("Hour end", Double(c.hour) + 0.94),
                    yStart: .value("Day", Double(6 - c.day) + 0.08), yEnd: .value("Day end", Double(6 - c.day) + 0.92)
                )
                .foregroundStyle(Self.heatColors[c.level])
                .clipShape(RoundedRectangle(cornerRadius: 2.5))
            }
            .chartXScale(domain: 0...24)
            .chartYScale(domain: 0...7)
            .chartYAxis {
                AxisMarks(position: .leading, values: Array(0..<7).map { Double($0) + 0.5 }) { v in
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(Self.dayLetters[6 - min(6, Int(d))]).font(.rounded(8.5, .bold)).foregroundStyle(Palette.ink3)
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 86)
            .accessibilityLabel("Listening by hour and weekday. Peak \(s.peakLabel).")
            HStack {
                ForEach(["12a", "6a", "12p", "6p", "11p"], id: \.self) { l in
                    Text(l)
                    if l != "11p" { Spacer() }
                }
            }
            .font(.rounded(9, .semibold)).foregroundStyle(Palette.ink3)
            .padding(.leading, 20).padding(.top, -4)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .card()
    }

    private func topShows(_ s: StatsSummary) -> some View {
        let maxSeconds = s.topShows.first?.seconds ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Top shows").font(.rounded(16, .heavy)).foregroundStyle(Palette.ink)
                Spacer()
                Button("See all \(s.showCount)") { showAllShows = true }
                    .font(.text(13.5, .bold)).foregroundStyle(Palette.tomato)
                    .accessibilityIdentifier("stats.seeAll")
            }
            .padding(.bottom, 6)
            ForEach(Array(s.topShows.prefix(5).enumerated()), id: \.element.id) { i, show in
                TopShowRow(rank: i + 1, show: show, fraction: show.seconds / maxSeconds)
                    .contentShape(Rectangle())
                    .onTapGesture { if store.podcast(show.podcastId) != nil { app.goToShow(show.podcastId) } }
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
        .card()
    }
}

struct TopShowRow: View {
    var rank: Int
    var show: TopShow
    var fraction: Double
    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)").font(.rounded(13, .heavy)).foregroundStyle(Palette.ink3).frame(width: 14)
            ArtworkView(title: show.title, size: 32, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(show.title).font(.text(14, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    Spacer()
                    Text(Format.hours(show.seconds)).font(.rounded(13, .bold)).monospacedDigit().foregroundStyle(Palette.ink2)
                }
                ProgressBar(value: fraction, width: nil, height: 5)
            }
        }
        .frame(height: 44)
    }
}

private struct AllShowsSheet: View {
    var stats: StatsSummary
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Top shows").font(.rounded(22, .heavy)).foregroundStyle(Palette.ink)
                Spacer()
                TextButton(title: "Done", bold: true, pill: true) { dismiss() }
            }
            .padding(.leading, 20).padding(.trailing, 8).padding(.top, 18)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(stats.topShows.enumerated()), id: \.element.id) { i, show in
                        TopShowRow(rank: i + 1, show: show, fraction: show.seconds / (stats.topShows.first?.seconds ?? 1))
                    }
                    Text("Plus \(stats.showCount - stats.topShows.count) more you dipped into.")
                        .font(.text(13)).foregroundStyle(Palette.ink3).padding(.top, 14)
                }
                .padding(.horizontal, 20)
            }
        }
        .poddleSheet(detents: [.medium, .large])
    }
}

/// A ticket stub: rounded rectangle with a semicircle bitten out of the top and bottom edges.
nonisolated struct TicketShape: Shape {
    var notchFromTrailing: CGFloat
    var radius: CGFloat = 9
    func path(in rect: CGRect) -> Path {
        let base = Path(roundedRect: rect, cornerRadius: 16, style: .continuous)
        let x = rect.maxX - notchFromTrailing
        var notches = Path()
        notches.addEllipse(in: CGRect(x: x - radius, y: rect.minY - radius, width: radius * 2, height: radius * 2))
        notches.addEllipse(in: CGRect(x: x - radius, y: rect.maxY - radius, width: radius * 2, height: radius * 2))
        return base.subtracting(notches)
    }
}

nonisolated struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}
