import SwiftUI
import PoddleKit

/// What plays after this one: tap to play, drag to reorder, swipe to remove (with Undo).
/// Chapters live on Now Playing's notes page.
struct QueueSheet: View {
    @Environment(PoddleStore.self) private var store
    @Environment(\.player) private var player
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let upNext = store.upNext(excluding: player.currentEpisodeId)
        let actions = EpisodeActions(store: store, player: player, app: app)
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Up Next").font(.rounded(22, .heavy)).foregroundStyle(Palette.ink)
                    Text(Format.queueSummary(count: upNext.count, wallSeconds: store.wallTime(upNext)))
                        .font(.text(12.5, .medium)).foregroundStyle(Palette.ink2)
                }
                Spacer()
                TextButton(title: "Done", bold: true, pill: true) { dismiss() }
                    .accessibilityIdentifier("queue.done")
            }
            .padding(.leading, 20).padding(.trailing, 8).padding(.top, 18).padding(.bottom, 8)

            List {
                if upNext.isEmpty {
                    BrandPlaceholder(pose: .empty, title: "Nothing after this one", message: "Add episodes from a show's page.", size: 110)
                        .plainListRow()
                }
                ForEach(upNext) { item in
                    HStack(spacing: 12) {
                        ArtworkView(podcast: item.podcast, size: 46, cornerRadius: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.episode.title).font(.text(15.5, .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                            Text(item.timeLabel).font(.text(13, .semibold)).foregroundStyle(Palette.ink2)
                        }
                        Spacer()
                        Image(systemName: "line.3.horizontal").foregroundStyle(Palette.ink3)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .cloudCard()
                    .padding(.vertical, 3)
                    .onTapGesture { player.play(item.id) }
                    .swipeRow(trailing: SwipeEdge(short: .remove { actions.removeFromUpNext(item) }))
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("queue.row.\(item.id)")
                    .plainListRow()
                }
                .onMove { store.moveQueue(ids: upNext.map(\.id), from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .overlay(alignment: .bottom) { UndoToastView().padding(.horizontal, 12).padding(.bottom, 8) }
        .poddleSheet(detents: [.medium, .large])
    }
}
