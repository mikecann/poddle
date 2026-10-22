import SwiftUI
import PoddleKit

struct LibraryView: View {
    @Environment(PoddleStore.self) private var store
    @Environment(\.player) private var player
    @Environment(AppModel.self) private var app
    @AppStorage("libraryLayout") private var layout = "grid"
    @AppStorage("librarySort") private var sort = Sort.updated
    @State private var showPast = false
    @State private var unsubscribing: Podcast?

    enum Sort: String, CaseIterable { case updated, title, listened, added
        var label: String {
            switch self {
            case .updated: "Recently updated"
            case .title: "Title"
            case .listened: "Most listened"
            case .added: "Date added"
            }
        }
    }

    private var actions: EpisodeActions { EpisodeActions(store: store, player: player, app: app) }

    private var shows: [Podcast] {
        let base = showPast ? store.pastShows : store.library
        switch sort {
        case .updated: return base
        case .title: return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .added: return base.sorted { ($0.subscribedAt ?? 0) > ($1.subscribedAt ?? 0) }
        case .listened:
            let top = store.stats?.topShows ?? []
            let rank = Dictionary(top.enumerated().map { ($1.podcastId, $0) }, uniquingKeysWith: { a, _ in a })
            return base.sorted { (rank[$0.id] ?? 99) < (rank[$1.id] ?? 99) }
        }
    }

    var body: some View {
        Group {
            if layout == "grid" {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 14, alignment: .top)], spacing: 18) {
                            ForEach(shows) { p in
                                Button { app.push(.podcast(p.id)) } label: { gridCell(p) }
                                    .buttonStyle(.pressable)
                                    .contextMenu { menu(p) }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        empty
                    }
                }
            } else {
                List {
                    header.plainListRow()
                    ForEach(Array(shows.enumerated()), id: \.element.id) { i, p in
                        listRow(p)
                            .overlay(alignment: .top) { if i > 0 { RowDivider(leading: 88) } }
                            .swipeRow(trailing: SwipeEdge(short: SwipeAction(title: "Unsubscribe", systemImage: "minus.circle", fill: Fills.actionTomato) { unsubscribing = p }))
                            .onTapGesture { app.push(.podcast(p.id)) }
                            .contextMenu { menu(p) }
                            .plainListRow()
                    }
                    empty.plainListRow()
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .animation(.snappy, value: layout)
        .confirmationDialog("Unsubscribe from \(unsubscribing?.title ?? "")?", isPresented: Binding(get: { unsubscribing != nil }, set: { if !$0 { unsubscribing = nil } }), titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) { if let p = unsubscribing { withAnimation { actions.unsubscribe(p) } } }
        } message: {
            Text("Your history stays, under Past shows.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            TopBar {
                EmptyView()
            } trailing: {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.tomato).frame(width: 36, height: 36).raised(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).padding(.horizontal, 4)
                .accessibilityLabel("Sort")
                PoddleSegmented(options: [("grid", "Grid"), ("list", "List")], selection: $layout, height: 34, fontSize: 13)
                    .frame(width: 120)
                    .padding(.horizontal, 4)
            }
            LargeTitle(title: "Library", subtitle: showPast ? "\(shows.count) past shows" : "\(shows.count) shows · \(totalUnplayed) unplayed")
                .padding(.top, 6)
            HStack(spacing: 8) {
                Chip(title: "Following", count: store.library.count, isOn: !showPast) { showPast = false }
                Chip(title: "Past shows", count: store.pastShows.count, isOn: showPast) { showPast = true }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }

    private var totalUnplayed: Int { store.library.reduce(0) { $0 + store.unplayedCount($1.id) } }

    private func gridCell(_ p: Podcast) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ArtworkView(podcast: p, size: geo.size.width, cornerRadius: geo.size.width * 0.2, shadow: false)
                    .shadow(color: Color(hex: 0x3C2314, alpha: 0.22), radius: 4, y: 3)
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                let n = store.unplayedCount(p.id)
                if n > 0 {
                    Text("\(n)").font(.rounded(12, .heavy)).foregroundStyle(Palette.creamWhite)
                        .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
                        .background(Palette.tomato, in: Capsule())
                        .overlay(Capsule().stroke(Palette.paper, lineWidth: 2))
                        .offset(x: 6, y: -6)
                }
            }
            HStack(spacing: 4) {
                Text(p.title).font(.text(13, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                if store.settings(for: p.id).hasOverrides { PinGlyph().frame(width: 10, height: 10).foregroundStyle(Palette.goldInk) }
            }
            Text(store.latestPubDate(p.id).map { "Updated \(Format.relativeDate($0).lowercasedIfRelative)" } ?? p.author)
                .font(.text(11.5, .medium)).foregroundStyle(Palette.ink2).lineLimit(1)
        }
    }

    private func listRow(_ p: Podcast) -> some View {
        HStack(spacing: 12) {
            ArtworkView(podcast: p, size: 56, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.title).font(.text(15.5, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    if p.isPrivate { PrivateBadge() }
                    if let speed = store.settings(for: p.id).speed { OverridePin(text: Format.speed(speed)) }
                }
                Text(p.author).font(.text(13)).foregroundStyle(Palette.ink2).lineLimit(1)
                let n = store.unplayedCount(p.id)
                Text(n == 0 ? "All played" : "\(n) unplayed").font(.text(12, .semibold))
                    .foregroundStyle(n == 0 ? Palette.ink3 : Palette.tomato)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink3)
        }
        .padding(.leading, 20).padding(.trailing, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var empty: some View {
        if shows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "square.grid.2x2").font(.system(size: 34)).foregroundStyle(Palette.ink3)
                Text(showPast ? "No past shows" : "No shows yet").font(.rounded(20, .bold)).foregroundStyle(Palette.ink)
                Text(showPast ? "Shows you unsubscribe from keep their history here." : "Find some in Discover, or bring everything over from Overcast.")
                    .font(.text(14)).foregroundStyle(Palette.ink2).multilineTextAlignment(.center)
                if !showPast {
                    PoddleButton(title: "Import from Overcast", systemImage: "square.and.arrow.down", kind: .primary) {
                        app.push(.importOvercast, on: .library)
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(40)
        } else {
            Color.clear.frame(height: 20)
        }
    }

    @ViewBuilder private func menu(_ p: Podcast) -> some View {
        Button { app.sheet = .showSettings(podcastId: p.id) } label: { Label("Settings", systemImage: "slider.horizontal.3") }
        if let latest = store.latestEpisode(of: p.id) {
            Button { player.play(latest.id) } label: { Label("Play latest", systemImage: "play") }
            Button { store.queueLast(latest.id) } label: { Label("Queue latest", systemImage: "text.line.last.and.arrowtriangle.forward") }
        }
        Button { actions.markAllPlayed(p) } label: { Label("Mark all played", systemImage: "checkmark.circle") }
        if p.subscribed {
            Button(role: .destructive) { unsubscribing = p } label: { Label("Unsubscribe", systemImage: "minus.circle") }
        } else {
            Button { store.subscribe(feedURL: p.feedURL) } label: { Label("Follow again", systemImage: "plus.circle") }
        }
    }
}

private extension String {
    /// "Updated today" rather than "Updated Today".
    var lowercasedIfRelative: String { self == "Today" || self == "Yesterday" ? lowercased() : self }
}
