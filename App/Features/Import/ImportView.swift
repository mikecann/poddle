import SwiftUI
import UniformTypeIdentifiers
import PoddleKit

/// One screen, three steps, no account linking: export from Overcast, pick the file, and watch the
/// receipt fill in as episodes are matched.
struct ImportView: View {
    @Environment(PoddleStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var file: PickedFile?
    @State private var pickingFile = false
    @State private var openedOvercast = false
    /// Mike's usual Overcast speed (decisions.md).
    @State private var speed = 2.0
    @State private var error: String?

    struct PickedFile: Equatable {
        var name: String
        var size: Int
        var folder: String
        var data: Data
    }

    private var progress: ImportProgress? { store.importProgress }
    private var started: Bool { progress != nil }
    private var done: Bool { progress?.phase == .done }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TopBar { BackButton(title: "Settings") } trailing: { EmptyView() }
                Text("Moving from Overcast").font(.rounded(34, .heavy)).tracking(-0.34).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 20).padding(.top, 6)
                Text("Bring your shows and every episode you've played. It takes about a minute.")
                    .font(.text(14.5)).foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 20).padding(.top, 2)

                VStack(alignment: .leading, spacing: 0) {
                    step(1, title: "Export from Overcast", state: openedOvercast || file != nil ? .done : .current) {
                        Text("Sign in at overcast.fm/account and tap \(Text("All data").fontWeight(.semibold).foregroundStyle(Palette.ink)) under OPML export. That one includes your play history.")
                            .font(.text(14)).foregroundStyle(Palette.ink2)
                        HStack(spacing: 8) {
                            Image(systemName: "lock").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink3)
                            Text("overcast.fm/account").font(.text(13.5, .medium)).foregroundStyle(Palette.ink)
                            Spacer()
                            Button {
                                openedOvercast = true
                                openURL(URL(string: "https://overcast.fm/account")!)
                            } label: {
                                HStack(spacing: 4) { Text("Open"); Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)) }
                                    .font(.text(13, .semibold)).foregroundStyle(Palette.tomato)
                                    .padding(.horizontal, 10).frame(height: 28)
                                    .background(Palette.tomato.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.pressable)
                        }
                        .padding(.leading, 12).padding(.trailing, 6).frame(height: 38)
                        .raised(cornerRadius: 12)
                        .padding(.top, 10)
                    }

                    step(2, title: "Choose the file", state: file != nil ? .done : (openedOvercast ? .current : .todo)) {
                        if let file {
                            HStack(spacing: 10) {
                                OPMLIcon()
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.name).font(.text(14, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)) · \(file.folder)")
                                        .font(.text(12)).foregroundStyle(Palette.ink2)
                                }
                                Spacer()
                                if !started {
                                    Button("Change") { pickingFile = true }.font(.text(14, .medium)).foregroundStyle(Palette.tomato)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .raised(cornerRadius: 12)
                            .padding(.top, 10)
                        } else {
                            PoddleButton(title: "Choose the OPML file", systemImage: "folder", kind: .card) { pickingFile = true }
                                .padding(.top, 10)
                        }
                        if let error {
                            Text(error).font(.text(13, .medium)).foregroundStyle(Palette.tomato).padding(.top, 6)
                        }
                    }

                    step(3, title: done ? "All moved in" : started ? "Moving in…" : "Your usual speed", state: done ? .current : (file != nil ? .current : .todo), last: true) {
                        if started {
                            receipt
                        } else {
                            speedQuestion
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 18)

                if done {
                    VStack(spacing: 4) {
                        PoddleButton(title: "See your stats", kind: .primary, large: true) {
                            app.tab = .stats
                        }
                        Button("Set per-show speeds next") { app.paths[.library] = []; app.tab = .library }
                            .font(.text(17, .semibold)).foregroundStyle(Palette.tomato).frame(height: 50)
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if file != nil && !started {
                    PoddleButton(title: "Import", kind: .primary, large: true) { start() }
                        .padding(.horizontal, 16).padding(.top, 8)
                }
                Spacer(minLength: 30)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: progress?.phase)
        .animation(.snappy, value: file)
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml, .data]) { result in
            pick(result)
        }
        .sensoryFeedback(.success, trigger: done)
        .onAppear {
            if app.importDemo && !started {
                // Screenshot mode: pretend the file's been picked and run the mock import.
                openedOvercast = true
                file = PickedFile(name: "overcast-all-data.opml", size: 2_300_000, folder: "Downloads", data: Data())
                speed = 1.8
                start()
            }
        }
    }

    private var speedQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Overcast's export has no listening log, so we estimate your hours from what you played. What speed did you usually listen at?")
                .font(.text(14)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach([1.0, 1.25, 1.5, 1.8, 2.0], id: \.self) { p in
                    let on = abs(p - speed) < 0.001
                    Button { speed = p } label: {
                        Text(Format.speed(p)).font(.rounded(14, .bold))
                            .foregroundStyle(on ? Palette.chipOnText : Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background { if on { RoundedRectangle(cornerRadius: 12).fill(Palette.chipOn) } }
                            .raised(RoundedRectangle(cornerRadius: 12, style: .continuous), fill: on ? .clear : Palette.card)
                    }
                    .buttonStyle(.pressable)
                }
            }
            HStack {
                Text("Something else").font(.text(14)).foregroundStyle(Palette.ink2)
                Spacer()
                WellStepper(text: Format.speedPrecise(speed) + "×",
                            onDecrement: { speed = Speed.snap(speed - 0.05) }, onIncrement: { speed = Speed.snap(speed + 0.05) })
            }
        }
        .padding(.top, 6)
        .sensoryFeedback(.selection, trigger: speed)
    }

    private var receipt: some View {
        let p = progress ?? ImportProgress(phase: .reading, fileName: "", importedAt: 0)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Import · \(Format.receiptDate(p.importedAt))")
                Spacer()
                Text(p.phase == .done ? "Done" : p.phase == .failed ? "Failed" : "\(Int(p.fraction * 100))%")
                    .contentTransition(.numericText())
            }
            .font(.mono(10, .semibold)).tracking(1).textCase(.uppercase).foregroundStyle(Palette.ink3)

            HStack(spacing: 0) {
                big(Format.count(p.podcasts), "podcasts")
                dashedRule(vertical: true)
                big(Format.count(p.playedEpisodes), "played episodes")
                dashedRule(vertical: true)
                big(Format.count(Int(p.hours)), "hours")
            }
            .padding(.vertical, 10)
            .overlay(alignment: .top) { dashedRule(vertical: false) }
            .overlay(alignment: .bottom) { dashedRule(vertical: false) }
            .padding(.top, 10)

            Group {
                if p.phase == .done {
                    Text("All of it is in your stats now, going back to \(Text(p.earliest.map { Format.monthYear($0) } ?? "the start").fontWeight(.semibold).foregroundStyle(Palette.ink)). \(p.halfFinished) half-finished episodes kept their place.")
                } else if p.phase == .failed {
                    Text(p.message ?? "Something went wrong.")
                } else {
                    Text("Matching episodes to their feeds… Played state, progress and stars all come across.")
                }
            }
            .font(.text(12.5)).foregroundStyle(Palette.ink2)
            .padding(.top, 10)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .padding(.bottom, 2)
        .background {
            ReceiptShape().fill(Color(hex: 0xFFFDF8))
                .shadow(color: Palette.shadow.opacity(0.14), radius: 8, y: 6)
                .shadow(color: Palette.shadow.opacity(0.12), radius: 1, y: 1)
        }
        .padding(.top, 10)
        .environment(\.colorScheme, .light)
    }

    private func big(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.rounded(22, .heavy)).tracking(-0.44).foregroundStyle(Palette.ink)
                .monospacedDigit().contentTransition(.numericText())
            Text(label).font(.text(11, .medium)).foregroundStyle(Palette.ink2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func dashedRule(vertical: Bool) -> some View {
        Path { p in
            p.move(to: .zero)
            p.addLine(to: vertical ? CGPoint(x: 0, y: 40) : CGPoint(x: 2000, y: 0))
        }
        .stroke(Color(hex: 0xD5C7B3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .frame(width: vertical ? 1 : nil, height: vertical ? 40 : 1)
        .clipped()
    }

    // MARK: Steps

    enum StepState { case done, current, todo }

    private func step<Content: View>(_ n: Int, title: String, state: StepState, last: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(state == .done ? Palette.fern : state == .current ? Palette.tomato : Palette.ink3.opacity(0.5))
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .black))
                } else {
                    Text("\(n)").font(.rounded(15, .heavy))
                }
            }
            .foregroundStyle(Palette.creamWhite)
            .frame(width: 32, height: 32)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(alignment: .top) {
                if !last {
                    Line().stroke(Color(hex: 0xCDBDA6), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 4]))
                        .frame(width: 2).padding(.top, 36).padding(.bottom, 2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rounded(16, .bold)).foregroundStyle(state == .todo ? Palette.ink3 : Palette.ink)
                    .contentTransition(.opacity)
                if state != .todo || n == 3 { content() }
            }
            .padding(.top, 5)
            .opacity(state == .todo ? 0.6 : 1)
        }
        .padding(.bottom, 18)
    }

    private func pick(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { error = "Couldn't read that file."; return }
            let text = String(decoding: data.prefix(400_000), as: UTF8.self)
            if !text.contains("<opml") {
                error = "That doesn't look like an OPML file."
                return
            }
            // Only the "All data" export has episode history.
            error = text.contains("podcast-episode") ? nil : "This is the plain export, with subscriptions only. Use \"All data\" to bring your history."
            file = PickedFile(name: url.lastPathComponent, size: data.count, folder: url.deletingLastPathComponent().lastPathComponent, data: data)
        case let .failure(e):
            error = e.localizedDescription
        }
    }

    private func start() {
        guard let file else { return }
        store.startImport(fileName: file.name, data: file.data, assumedSpeed: speed)
    }
}

private struct OPMLIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0xF3C53E), Color(hex: 0xE7A93A)], startPoint: .top, endPoint: .bottom))
            .frame(width: 30, height: 36)
            .overlay(alignment: .bottom) {
                Text("OPML").font(.rounded(7, .heavy)).foregroundStyle(Color(hex: 0x3B2A0B)).padding(.bottom, 5)
            }
    }
}

/// A till receipt: square top, torn zig-zag bottom edge.
nonisolated struct ReceiptShape: Shape {
    var tooth: CGFloat = 8
    var depth: CGFloat = 6
    var tornTop = false

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if tornTop {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            var x = rect.minX
            while x < rect.maxX {
                p.addLine(to: CGPoint(x: min(rect.maxX, x + tooth / 2), y: rect.minY - depth))
                p.addLine(to: CGPoint(x: min(rect.maxX, x + tooth), y: rect.minY))
                x += tooth
            }
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        var x = rect.maxX
        while x > rect.minX {
            p.addLine(to: CGPoint(x: max(rect.minX, x - tooth / 2), y: rect.maxY + depth))
            p.addLine(to: CGPoint(x: max(rect.minX, x - tooth), y: rect.maxY))
            x -= tooth
        }
        p.closeSubpath()
        return p
    }
}
