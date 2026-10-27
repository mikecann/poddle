import SwiftUI
import PoddleKit

struct UpNextView: View {
    @Environment(PoddleStore.self) private var store
    @Environment(\.player) private var player
    @Environment(AppModel.self) private var app
    @State private var confirmClear = false
    /// Pull-to-refresh is running: Poddle trots across the top.
    @State private var refreshing = false
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    private var items: [EpisodeItem] { store.upNext(excluding: player.currentEpisodeId) }

    var body: some View {
        let items = items
        let actions = EpisodeActions(store: store, player: player, app: app)
        List {
            header(items)
                .plainListRow()
                .moveDisabled(true)

            ForEach(items) { item in
                EpisodeRow(item: item, showGrip: true)
                    .cloudCard()
                    .padding(.vertical, 4)
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
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("upNext.row.\(item.id)")
                    .plainListRow()
            }
            .onMove { from, to in
                store.moveQueue(ids: items.map(\.id), from: from, to: to)
            }

            footer(items)
                .plainListRow()
                .moveDisabled(true)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            withAnimation { refreshing = true }
            await store.refresh()
            withAnimation { refreshing = false }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .accessibilityIdentifier("upNext.list")
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: items.map(\.id))
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
                BrandLockup()
            } trailing: {
                Menu {
                    Section("Sort the queue once") {
                        Button { sort(items, by: { $0.remaining < $1.remaining }) } label: { Label("Shortest first", systemImage: "timer") }
                        Button { sort(items, by: { $0.episode.pubDate > $1.episode.pubDate }) } label: { Label("Newest first", systemImage: "calendar") }
                        Button { sort(items, by: { $0.episode.pubDate < $1.episode.pubDate }) } label: { Label("Oldest first", systemImage: "calendar.badge.clock") }
                    }
                    Button(role: .destructive) { confirmClear = true } label: { Label("Clear queue…", systemImage: "trash") }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Palette.tomato)
                        .frame(width: 40, height: 40)
                        .raised(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .accessibilityLabel("Sort and clear")
                .accessibilityIdentifier("upNext.sort")
                #if os(iOS)
                TextButton(title: editMode.isEditing ? "Done" : "Edit", bold: editMode.isEditing, pill: true) {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .accessibilityIdentifier("upNext.edit")
                #endif
            }
            .frame(height: 52)
            // No "Up Next" title or filter chips (Mike, 27 Oct 2026): the tab already says where you
            // are, and the queue's total moved to the end of the list.
            if refreshing || isFirstSync(items) {
                TrotStrip(message: refreshing ? "Checking your shows…" : "Fetching your shows…", height: 48)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
    }

    /// Signed in on a fresh install: nothing cached and the first sync hasn't landed yet.
    private func isFirstSync(_ items: [EpisodeItem]) -> Bool {
        guard items.isEmpty, let c = store.connection else { return false }
        return c.lastSyncAt == nil
    }

    @ViewBuilder private func footer(_ items: [EpisodeItem]) -> some View {
        if items.isEmpty, !isFirstSync(items) {
            BrandPlaceholder(pose: .empty, title: "Nothing to listen to",
                             message: "New episodes from your shows land here. Swipe right on any episode in a show to add it.")
        } else if !items.isEmpty {
            VStack(spacing: 3) {
                Text("That's the lot.")
                    .font(.text(13.5, .semibold)).foregroundStyle(Palette.ink3)
                // How long the whole queue takes at each show's speed. The rows show real lengths.
                Text(Format.queueSummary(count: items.count, wallSeconds: store.wallTime(items)))
                    .font(.text(12.5, .semibold)).foregroundStyle(Palette.ink3)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            // One element, so the "sits above the mini player" check covers both lines.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("upNext.end")
        }
    }

    private func sort(_ items: [EpisodeItem], by order: (EpisodeItem, EpisodeItem) -> Bool) {
        withAnimation {
            for item in items.sorted(by: order) { store.moveToBottom(item.id) }
        }
    }
}

