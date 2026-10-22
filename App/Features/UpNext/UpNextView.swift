import SwiftUI
import PoddleKit

struct UpNextView: View {
    @Environment(PoddleStore.self) private var store
    @Environment(\.player) private var player
    @Environment(AppModel.self) private var app
    @State private var filter: Filter = .all
    @State private var confirmClear = false
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    enum Filter: Hashable { case all, downloaded, short }

    private var items: [EpisodeItem] { store.upNext(excluding: player.currentEpisodeId) }

    private func filtered(_ items: [EpisodeItem]) -> [EpisodeItem] {
        switch filter {
        case .all: items
        case .downloaded: items.filter(\.isDownloaded)
        case .short: items.filter { $0.wallRemaining < 20 * 60 }
        }
    }

    var body: some View {
        let items = items
        let shown = filtered(items)
        let actions = EpisodeActions(store: store, player: player, app: app)
        List {
            header(items)
                .plainListRow()
                .moveDisabled(true)

            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                EpisodeRow(item: item, showGrip: true)
                    .overlay(alignment: .top) { if index > 0 { RowDivider() } }
                    .swipeRow(
                        leading: SwipeEdge(short: .top { actions.moveToTopOfUpNext(item.id) }),
                        trailing: SwipeEdge(short: .remove { actions.removeFromUpNext(item) }, long: .played { actions.markPlayed(item) })
                    )
                    .onTapGesture { actions.playNow(item.id) }
                    .contextMenu {
                        actions.menu(for: item, context: .upNext)
                    } preview: {
                        ShowNotesPreview(item: item)
                    }
                    .plainListRow()
            }
            .onMove { from, to in
                store.moveQueue(ids: shown.map(\.id), from: from, to: to)
            }
            .moveDisabled(filter != .all)

            footer(items)
                .plainListRow()
                .moveDisabled(true)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
        .contentMargins(.top, 0, for: .scrollContent)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: shown.map(\.id))
        #if os(iOS)
        .environment(\.editMode, $editMode)
        #endif
        .confirmationDialog("Clear Up Next?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear \(items.count) episodes", role: .destructive) {
                withAnimation { actions.clearQueue(keeping: player.currentEpisodeId) }
            }
        } message: {
            Text("Whatever's playing stays. You can undo this for a few seconds.")
        }
    }

    private func header(_ items: [EpisodeItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TopBar {
                Menu {
                    Section("Sort the queue once") {
                        Button { sort(items, by: { $0.wallRemaining < $1.wallRemaining }) } label: { Label("Shortest first", systemImage: "timer") }
                        Button { sort(items, by: { $0.episode.pubDate > $1.episode.pubDate }) } label: { Label("Newest first", systemImage: "calendar") }
                        Button { sort(items, by: { $0.episode.pubDate < $1.episode.pubDate }) } label: { Label("Oldest first", systemImage: "calendar.badge.clock") }
                    }
                    Button(role: .destructive) { confirmClear = true } label: { Label("Clear queue…", systemImage: "trash") }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.tomato)
                        .frame(width: 36, height: 36)
                        .raised(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .accessibilityLabel("Sort and clear")
                #if os(iOS)
                TextButton(title: editMode.isEditing ? "Done" : "Edit", bold: editMode.isEditing) {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                #endif
            }
            LargeTitle(title: "Up Next", subtitle: Format.queueSummary(count: items.count, wallSeconds: store.wallTime(items)))
                .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(title: "All", count: items.count, isOn: filter == .all) { filter = .all }
                    Chip(title: "Downloaded", count: items.filter(\.isDownloaded).count, isOn: filter == .downloaded) { filter = .downloaded }
                    Chip(title: "Under 20 min", count: items.filter { $0.wallRemaining < 20 * 60 }.count, isOn: filter == .short) { filter = .short }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()
            .padding(.top, 6)
        }
        .animation(.default, value: filter)
    }

    @ViewBuilder private func footer(_ items: [EpisodeItem]) -> some View {
        if items.isEmpty {
            BrandPlaceholder(pose: .empty, title: "Nothing to listen to",
                             message: "New episodes from your shows land here. Swipe right on any episode in a show to add it.")
        } else {
            Text("That's the lot.")
                .font(.text(13, .medium)).foregroundStyle(Palette.ink3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .overlay(alignment: .top) { RowDivider() }
        }
    }

    private func sort(_ items: [EpisodeItem], by order: (EpisodeItem, EpisodeItem) -> Bool) {
        withAnimation {
            for item in items.sorted(by: order) { store.moveToBottom(item.id) }
        }
    }
}

