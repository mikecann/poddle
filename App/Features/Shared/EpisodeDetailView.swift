import SwiftUI
import PoddleKit

/// Episode page: artwork, the actions, and the show notes.
struct EpisodeDetailView: View {
    var episodeId: String
    var inSheet = false
    @Environment(PoddleStore.self) private var store
    @Environment(\.player) private var player
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let item = store.item(episodeId) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TopBar {
                        if inSheet { TextButton(title: "Close", bold: true) { dismiss() }.accessibilityIdentifier("episode.close") } else { BackButton(title: "Back") }
                    } trailing: {
                        Menu { EpisodeActions(store: store, player: player, app: app).menu(for: item, context: .detail) } label: {
                            Image(systemName: "ellipsis").font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(Palette.tomato).frame(width: 40, height: 40).raised(Circle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).padding(.horizontal, 4)
                        .accessibilityLabel("More")
                        .accessibilityIdentifier("episode.more")
                    }
                    HStack(alignment: .bottom, spacing: 16) {
                        ArtworkView(podcast: item.podcast, size: 112, cornerRadius: 0, shadow: false)
                            .clipShape(CloudShape(cornerRadius: 26, scallop: 28, depth: 2.5))
                            .background { CloudShape(cornerRadius: 26, scallop: 28, depth: 2.5).fill(Palette.cardEdge).offset(y: 4) }
                            .floatShadow(10, y: 8, opacity: 0.2)
                        VStack(alignment: .leading, spacing: 4) {
                            Button { app.goToShow(item.podcast.id) } label: {
                                Text(item.podcast.title).capsLabel(12, color: Palette.tomato)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("episode.show")
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

                    Text(item.episode.title).font(.rounded(27, .heavy)).tracking(-0.4).foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 20).padding(.top, 16)

                    if item.isInProgress {
                        HStack(spacing: 8) {
                            ProgressBar(value: item.progress, width: 80)
                            Text(item.timeLabel).font(.text(13, .semibold)).foregroundStyle(Palette.ink)
                        }
                        .padding(.horizontal, 20).padding(.top, 8)
                    }

                    HStack(spacing: 8) {
                        if let start = app.linkStarts[item.id], player.currentEpisodeId != item.id {
                            // Opened from a shared link with ?t=.
                            PoddleButton(title: "Play from \(Format.clock(start))", systemImage: "play.fill", kind: .primary) {
                                store.moveToTop(item.id)
                                player.load(item.id, position: start, smartSaved: 0)
                                player.resume()
                                app.linkStarts[item.id] = nil
                                app.showNowPlaying = true
                            }
                            .accessibilityIdentifier("episode.play")
                        } else {
                            PoddleButton(title: player.currentEpisodeId == item.id && player.isPlaying ? "Playing" : "Play", systemImage: "play.fill", kind: .primary) {
                                player.play(item.id)
                                app.showNowPlaying = true
                            }
                            .accessibilityIdentifier("episode.play")
                        }
                        if item.isQueued {
                            PoddleButton(title: "In Up Next", systemImage: "checkmark") {
                                EpisodeActions(store: store, player: player, app: app).removeFromUpNext(item)
                            }
                            .accessibilityIdentifier("episode.queue")
                        } else {
                            PoddleButton(title: "Queue", systemImage: "plus") { store.queueLast(item.id) }
                                .accessibilityIdentifier("episode.queue")
                        }
                        PoddleButton(title: "", systemImage: item.isStarred ? "star.fill" : "star") { store.toggleStar(item.id) }
                            .accessibilityLabel(item.isStarred ? "Unstar" : "Star")
                            .accessibilityIdentifier("episode.star")
                    }
                    .padding(.horizontal, 20).padding(.top, 16)

                    Text("Show notes").font(.rounded(22, .heavy)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 20).padding(.top, 24)
                    Text((store.showNotes[episodeId] ?? item.episode.showNotesHTML).strippingHTML)
                        .font(.text(15.5)).foregroundStyle(Palette.body).lineSpacing(2)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 30)
                }
            }
            .task(id: episodeId) { await store.loadShowNotes(episodeId) }
        } else {
            BrandPlaceholder(title: "Episode not found", message: "It may no longer be available, or it may be from a private feed.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.paper.ignoresSafeArea())
        }
    }
}
