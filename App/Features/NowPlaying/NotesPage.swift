import SwiftUI
import PoddleKit

/// Now Playing's left page: chapters (tap to jump) and the show notes, with tappable links and
/// timestamps that seek.
struct NotesPage: View {
    var item: EpisodeItem
    @Environment(PoddleStore.self) private var store
    @Environment(\.player) private var player
    @State private var blocks: [ShowNotes.Block] = []
    @State private var seeked = 0

    private var html: String { store.showNotes[item.id] ?? item.episode.showNotesHTML }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading
                if !player.chapters.isEmpty {
                    sectionTitle("Chapters")
                    VStack(spacing: 0) {
                        ForEach(Array(player.chapters.enumerated()), id: \.element.id) { i, chapter in
                            chapterRow(i, chapter)
                        }
                    }
                    .background(NP.util, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 16)
                }
                sectionTitle("Show notes")
                VStack(alignment: .leading, spacing: 12) {
                    if blocks.isEmpty {
                        Text("No show notes for this one.").font(.text(15)).foregroundStyle(NP.fg2)
                    }
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .tint(Palette.mustard)
                .textSelection(.enabled)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .environment(\.openURL, OpenURLAction { url in
            guard let seconds = ShowNotes.seekSeconds(url) else { return .systemAction }
            player.seek(to: seconds)
            seeked += 1
            return .handled
        })
        .sensoryFeedback(.impact(weight: .light), trigger: seeked)
        .task(id: item.id) { await store.loadShowNotes(item.id) }
        .task(id: html) {
            let html = html
            blocks = await Task.detached(priority: .userInitiated) { ShowNotes.blocks(html: html) }.value
        }
    }

    private var heading: some View {
        HStack(spacing: 12) {
            ArtworkView(podcast: item.podcast, size: 56, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.podcast.title).font(.rounded(11, .bold)).tracking(0.66).textCase(.uppercase)
                    .foregroundStyle(Palette.mustard).lineLimit(1)
                Text(item.episode.title).font(.rounded(18, .bold)).foregroundStyle(NP.fg).lineLimit(2)
                Text("\(Format.relativeDate(item.episode.pubDate)) · \(Format.duration(item.duration))")
                    .font(.text(12.5, .medium)).foregroundStyle(NP.fg2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.rounded(11, .bold)).tracking(1.1).textCase(.uppercase).foregroundStyle(NP.fg2)
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 8)
    }

    private func chapterRow(_ i: Int, _ chapter: Chapter) -> some View {
        let current = player.currentChapterIndex == i
        let played = (player.currentChapterIndex ?? -1) > i
        return Button { player.seek(toChapter: chapter); seeked += 1 } label: {
            HStack(spacing: 12) {
                Text("\(i + 1)").font(.rounded(12, .heavy)).foregroundStyle(current ? Palette.creamWhite : NP.fg2)
                    .frame(width: 24, height: 24)
                    .background(current ? Palette.tomato : NP.util, in: Circle())
                Text(chapter.title).font(.text(15, current ? .semibold : .regular))
                    .foregroundStyle(played ? NP.fg3 : NP.fg)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if current {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .foregroundStyle(Palette.tomato)
                }
                Text(Format.clock(chapter.start)).font(.rounded(12.5, .semibold)).monospacedDigit().foregroundStyle(NP.fg2)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chapter \(i + 1), \(chapter.title), at \(Format.clock(chapter.start))")
    }

    @ViewBuilder private func blockView(_ block: ShowNotes.Block) -> some View {
        switch block {
        case let .paragraph(text):
            Text(text).font(.text(15.5)).foregroundStyle(Palette.body).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Palette.mustard)
                Text(text).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
            }
            .font(.text(15.5))
        case let .heading(text):
            Text(text).font(.rounded(17, .bold)).foregroundStyle(NP.fg).padding(.top, 4)
        }
    }
}
