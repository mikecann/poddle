import SwiftUI
import PoddleKit

/// Chapters for what's playing (tap to jump) and the queue (drag to reorder).
struct QueueChaptersSheet: View {
    @Environment(PoddleStore.self) private var store
    @Environment(MockPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var pane: Pane = .chapters

    enum Pane: Hashable { case chapters, queue }

    var body: some View {
        let upNext = store.upNext(excluding: player.currentEpisodeId)
        VStack(spacing: 0) {
            HStack {
                Text(pane == .chapters ? "Chapters" : "Up Next").font(.rounded(20, .heavy)).foregroundStyle(Palette.ink)
                Spacer()
                TextButton(title: "Done", bold: true) { dismiss() }
            }
            .padding(.leading, 20).padding(.trailing, 8).padding(.top, 18)

            PoddleSegmented(options: [(Pane.chapters, "Chapters \(player.chapters.count)"), (Pane.queue, "Queue \(upNext.count)")], selection: $pane)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)

            List {
                if pane == .chapters {
                    if player.chapters.isEmpty {
                        Text("This episode doesn't have chapters.")
                            .font(.text(14)).foregroundStyle(Palette.ink2)
                            .frame(maxWidth: .infinity).padding(30).plainListRow()
                    }
                    ForEach(Array(player.chapters.enumerated()), id: \.element.id) { i, chapter in
                        chapterRow(i, chapter).plainListRow()
                    }
                } else {
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
                        .plainListRow()
                    }
                    .onMove { store.moveQueue(ids: upNext.map(\.id), from: $0, to: $1) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .poddleSheet(detents: [.medium, .large])
    }

    private func chapterRow(_ i: Int, _ chapter: Chapter) -> some View {
        let current = player.currentChapterIndex == i
        let played = (player.currentChapterIndex ?? -1) > i
        return Button { player.seek(toChapter: chapter) } label: {
            HStack(spacing: 12) {
                Text("\(i + 1)").font(.rounded(13, .heavy)).foregroundStyle(current ? Palette.creamWhite : Palette.ink3)
                    .frame(width: 26, height: 26)
                    .background(current ? Palette.tomato : Palette.wash, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(chapter.title).font(.text(15.5, current ? .semibold : .regular))
                        .foregroundStyle(played ? Palette.ink3 : Palette.ink)
                    Text(Format.clock(chapter.start)).font(.rounded(12, .semibold)).monospacedDigit().foregroundStyle(Palette.ink2)
                }
                Spacer()
                if let end = chapter.end {
                    Text(Format.duration((end - chapter.start) / player.rate)).font(.text(12.5, .medium)).foregroundStyle(Palette.ink3)
                }
                if current {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .foregroundStyle(Palette.tomato)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
