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
                    Text("Up Next").font(.rounded(20, .heavy)).foregroundStyle(Palette.ink)
                    Text(Format.queueSummary(count: upNext.count, wallSeconds: store.wallTime(upNext)))
                        .font(.text(12.5, .medium)).foregroundStyle(Palette.ink2)
                }
                Spacer()
                TextButton(title: "Done", bold: true) { dismiss() }
            }
            .padding(.leading, 20).padding(.trailing, 8).padding(.top, 18).padding(.bottom, 8)

            List {
                if upNext.isEmpty {
                    Text("Nothing after this one.")
                        .font(.text(14)).foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity).padding(30).plainListRow()
                }
                ForEach(upNext) { item in
                    HStack(spacing: 12) {
                        ArtworkView(podcast: item.podcast, size: 44, cornerRadius: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.episode.title).font(.text(15, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                            Text(item.timeLabel).font(.text(12.5, .medium)).foregroundStyle(Palette.ink2)
                        }
                        Spacer()
                        Image(systemName: "line.3.horizontal").foregroundStyle(Palette.ink3)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(item.id) }
                    .swipeRow(trailing: SwipeEdge(short: .remove { actions.removeFromUpNext(item) }))
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
