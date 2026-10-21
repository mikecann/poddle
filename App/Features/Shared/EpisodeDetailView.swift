import SwiftUI
import PoddleKit

/// Episode page: artwork, the actions, and the show notes.
struct EpisodeDetailView: View {
    var episodeId: String
    var inSheet = false
    @Environment(PoddleStore.self) private var store
    @Environment(MockPlayer.self) private var player
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let item = store.item(episodeId) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TopBar {
                        if inSheet { TextButton(title: "Close") { dismiss() } } else { BackButton(title: "Back") }
                    } trailing: {
                        Menu { EpisodeActions(store: store, player: player, app: app).menu(for: item, context: .detail) } label: {
                            Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Palette.tomato).frame(width: 36, height: 36).raised(Circle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).padding(.horizontal, 4)
                    }
                    HStack(alignment: .bottom, spacing: 16) {
                        ArtworkView(podcast: item.podcast, size: 112, cornerRadius: 22, shadow: false)
                            .shadow(color: Palette.shadow.opacity(0.35), radius: 10, y: 10)
                        VStack(alignment: .leading, spacing: 4) {
                            Button { app.goToShow(item.podcast.id) } label: {
                                Text(item.podcast.title).capsLabel(11, color: Palette.tomato)
                            }
                            .buttonStyle(.plain)
                            Text("\(Format.relativeDate(item.episode.pubDate)) · \(Format.duration(item.duration))")
                                .font(.text(13, .medium)).foregroundStyle(Palette.ink2)
                            HStack(spacing: 6) {
                                if item.speed.isOverride { OverridePin(text: Format.speed(item.speed.value)) }
                                DownloadGlyph(item: item)
                                if item.isStarred { Image(systemName: "star.fill").foregroundStyle(Palette.mustard).font(.system(size: 12)) }
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 6)

                    Text(item.episode.title).font(.rounded(26, .heavy)).tracking(-0.4).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 20).padding(.top, 16)

                    if item.isInProgress {
                        HStack(spacing: 8) {
                            ProgressBar(value: item.progress, width: 80)
                            Text(item.timeLabel).font(.text(13, .semibold)).foregroundStyle(Palette.ink)
                        }
                        .padding(.horizontal, 20).padding(.top, 8)
                    }

                    HStack(spacing: 8) {
                        PoddleButton(title: player.currentEpisodeId == item.id && player.isPlaying ? "Playing" : "Play", systemImage: "play.fill", kind: .primary) {
                            player.play(item.id)
                            app.showNowPlaying = true
                        }
                        if item.isQueued {
                            PoddleButton(title: "In Up Next", systemImage: "checkmark") { store.removeFromQueue(item.id) }
                        } else {
                            PoddleButton(title: "Queue", systemImage: "plus") { store.queueLast(item.id) }
                        }
                        PoddleButton(title: "", systemImage: item.isStarred ? "star.fill" : "star") { store.toggleStar(item.id) }
                            .accessibilityLabel(item.isStarred ? "Unstar" : "Star")
                    }
                    .padding(.horizontal, 20).padding(.top, 16)

                    Text("Show notes").font(.rounded(20, .heavy)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 20).padding(.top, 24)
                    Text((store.showNotes[episodeId] ?? item.episode.showNotesHTML).strippingHTML)
                        .font(.text(15)).foregroundStyle(Palette.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 30)
                }
            }
            .task(id: episodeId) { await store.loadShowNotes(episodeId) }
        } else {
            ContentUnavailableView("Episode not found", systemImage: "questionmark.circle")
        }
    }
}
