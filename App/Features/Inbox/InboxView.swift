import SwiftUI
import PoddleKit

/// New episodes waiting for a decision. Swipe right to queue (short: last, long: next), swipe
/// left to archive (short) or mark played (long).
struct InboxView: View {
    @Environment(PoddleStore.self) private var store
    @Environment(\.player) private var player
    @Environment(AppModel.self) private var app
    @State private var confirmArchiveAll = false
    @State private var refreshed = 0

    var body: some View {
        let items = store.inbox
        let actions = EpisodeActions(store: store, player: player, app: app)
        List {
            VStack(alignment: .leading, spacing: 0) {
                TopBar {
                    if !items.isEmpty {
                        TextButton(title: "Archive all") { confirmArchiveAll = true }
                    }
                }
                LargeTitle(title: "Inbox", subtitle: subtitle(items)).padding(.top, 6)
                hint.padding(.top, 14).padding(.bottom, 6)
            }
            .plainListRow()

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                EpisodeRow(item: item, style: .inbox, onArtworkTap: { actions.playNow(item.id) })
                    .overlay(alignment: .top) { if index > 0 { RowDivider() } }
                    .swipeRow(
                        leading: SwipeEdge(
                            short: .upNext("Queue last") { store.queueLast(item.id) },
                            long: SwipeAction(title: "Queue next", systemImage: "text.line.first.and.arrowtriangle.forward",
                                              fill: Fills.actionTomato) { store.playNext(item.id) }
                        ),
                        trailing: SwipeEdge(short: .archive { store.archive(item.id) }, long: .played { store.markPlayed(item.id) })
                    )
                    .onTapGesture { app.push(.episode(item.id), on: .inbox) }
                    .contextMenu {
                        actions.menu(for: item, context: .inbox)
                    } preview: {
                        ShowNotesPreview(item: item)
                    }
                    .plainListRow()
            }

            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(Palette.ink3)
                    Text("Inbox zero").font(.rounded(20, .bold)).foregroundStyle(Palette.ink)
                    Text("New episodes from your shows land here. Priority shows skip straight to Up Next.")
                        .font(.text(14)).foregroundStyle(Palette.ink2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
                .plainListRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: items.map(\.id))
        .refreshable {
            await store.refresh()
            refreshed += 1
        }
        .sensoryFeedback(.success, trigger: refreshed)
        .confirmationDialog("Archive everything in the Inbox?", isPresented: $confirmArchiveAll, titleVisibility: .visible) {
            Button("Archive \(items.count) episodes", role: .destructive) {
                withAnimation { for item in items { store.archive(item.id) } }
            }
        }
    }

    private func subtitle(_ items: [EpisodeItem]) -> String {
        guard !items.isEmpty else { return "All caught up" }
        let total = items.reduce(0) { $0 + $1.wallRemaining }
        return "\(items.count) new · \(Format.duration(total)) at your speeds"
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.goldInk)
            Text("Swipe right to queue, left to archive. Hold for more.")
                .font(.text(12.5, .medium)).foregroundStyle(Palette.ink2)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.goldBg.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }
}
