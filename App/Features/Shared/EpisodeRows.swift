import SwiftUI
import PoddleKit

/// An Up Next row: artwork, show line, title and the time/speed line.
struct EpisodeRow: View {
    @Environment(PoddleStore.self) private var store
    var item: EpisodeItem
    var showGrip = false
    var onArtworkTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(podcast: item.podcast, size: 60, cornerRadius: 12)
                .onTapGesture { onArtworkTap?() }
                .accessibilityAddTraits(onArtworkTap == nil ? [] : .isButton)
                .accessibilityLabel(onArtworkTap == nil ? "\(item.podcast.title) artwork" : "Play \(item.episode.title)")
            VStack(alignment: .leading, spacing: 2) {
                showLine
                Text(item.episode.title)
                    .font(.text(15.5, .semibold)).tracking(-0.155)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                metaLine.padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showGrip {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Palette.ink3)
                    .frame(width: 40, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, showGrip ? 4 : 16)
        .padding(.vertical, 12)
        .frame(minHeight: 88)
        .contentShape(Rectangle())
    }

    private var isFresh: Bool {
        !item.state.played && !item.isInProgress && Date().timeIntervalSince1970 * 1000 - item.episode.pubDate < 86_400_000
    }

    private var showLine: some View {
        HStack(spacing: 6) {
            if isFresh { NewDot() }
            Text(item.podcast.title)
                .font(.rounded(11, .bold)).tracking(0.66).textCase(.uppercase)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
            if item.podcast.isPrivate { PrivateBadge() }
            if item.speed.isOverride { OverridePin(text: Format.speed(item.speed.value)) }
        }
    }

    @ViewBuilder private var metaLine: some View {
        HStack(spacing: 7) {
            if item.isInProgress {
                ProgressBar(value: item.progress)
                Text(Format.duration(item.wallRemaining) + " left").fontWeight(.semibold).foregroundStyle(Palette.ink)
            } else {
                Text(Format.duration(item.wallRemaining)).fontWeight(.semibold).foregroundStyle(Palette.ink)
            }
            Text("at \(Format.speed(item.speed.value))").foregroundStyle(Palette.ink2)
            DownloadGlyph(item: item)
            if item.isWaitingForWifi {
                Text("Waiting for Wi-Fi").foregroundStyle(Palette.ink3)
            } else if item.isDownloading {
                DownloadPercent(progress: store.downloadProgress(item.id), fallback: item.download?.progress ?? 0)
                    .foregroundStyle(Palette.ink3)
            } else if !item.isDownloaded {
                Text("Not downloaded").foregroundStyle(Palette.ink3)
            }
        }
        .font(.text(12.5, .medium))
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// The inset hairline between rows.
struct RowDivider: View {
    var leading: CGFloat = 92
    var body: some View {
        Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, leading)
    }
}

extension View {
    /// List row chrome: no system background, separators or insets.
    func plainListRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// Everything you can do to an episode, used by context menus and swipes. Destructive actions
/// show the Undo toast (decisions.md).
struct EpisodeActions {
    var store: PoddleStore
    var player: any PoddlePlayer
    var app: AppModel

    func playNow(_ id: String) {
        player.play(id)
    }

    /// Over mobile data in Wi-Fi-only mode this asks first (RootView shows the prompt).
    func download(_ id: String) {
        if store.download(id) == .needsMobilePrompt { app.mobilePromptEpisodeId = id }
    }

    /// Top of the visible Up Next list: straight after whatever's playing.
    func moveToTopOfUpNext(_ id: String) {
        if player.currentEpisodeId == nil { store.moveToTop(id) } else { store.playNext(id) }
    }

    // MARK: Destructive, with Undo

    func archive(_ item: EpisodeItem) {
        let point = store.restorePoint([item.id])
        store.archive(item.id)
        app.undo.show("Archived", item.episode.title) { store.restore(point) }
    }

    /// Undo puts it back in the same place in the queue.
    func removeFromUpNext(_ item: EpisodeItem) {
        let point = store.restorePoint([item.id])
        store.removeFromQueue(item.id)
        app.undo.show("Removed", item.episode.title) { store.restore(point) }
    }

    /// Undo restores the played flag, the position and the place in Up Next.
    func markPlayed(_ item: EpisodeItem) {
        let point = store.restorePoint([item.id])
        store.markPlayed(item.id)
        app.undo.show("Played", item.episode.title) { store.restore(point) }
    }

    /// The file is only deleted once the toast has gone, so undo costs nothing.
    func removeDownload(_ item: EpisodeItem) {
        let id = item.id
        let verb = item.isDownloaded ? "Removed download" : "Cancelled download"
        store.removeDownloadLater(id)
        app.undo.show(verb, item.episode.title) {
            store.cancelDownloadRemoval(id)
        } commit: {
            store.commitDownloadRemoval(id)
        }
    }

    func markOlderPlayed(_ item: EpisodeItem) {
        let point = store.restorePoint(podcastId: item.podcast.id)
        store.markOlderPlayed(item.id)
        app.undo.show("Marked older played", item.podcast.title) { store.restore(point) }
    }

    func markAllPlayed(_ podcast: Podcast) {
        let point = store.restorePoint(podcastId: podcast.id)
        store.markAllPlayed(podcast.id)
        app.undo.show("Marked all played", podcast.title) { store.restore(point) }
    }

    func unsubscribe(_ podcast: Podcast) {
        let point = store.restorePoint(podcastId: podcast.id)
        store.unsubscribe(podcast.id)
        app.undo.show("Unsubscribed", podcast.title) {
            store.resubscribe(podcast.id)
            store.restore(point)
        }
    }

    func clearQueue(keeping: String?) {
        let point = store.queueRestorePoint()
        let count = store.queue.count { $0.id != keeping }
        store.clearQueue(keeping: keeping)
        app.undo.show("Cleared", count == 1 ? "1 episode" : "\(count) episodes") { store.restore(point) }
    }

    @ViewBuilder
    func menu(for item: EpisodeItem, context: MenuContext) -> some View {
        let id = item.id
        Button { playNow(id) } label: { Label("Play now", systemImage: "play") }
        switch context {
        case .upNext:
            Button { moveToTopOfUpNext(id) } label: { Label("Move to top", systemImage: "arrow.up.to.line") }
            Button { store.moveToBottom(id) } label: { Label("Move to bottom", systemImage: "arrow.down.to.line") }
            Button { removeFromUpNext(item) } label: { Label("Remove from Up Next", systemImage: "minus.circle") }
        case .podcast, .detail:
            if !item.isQueued {
                Button { store.playNext(id) } label: { Label("Queue next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button { store.queueLast(id) } label: { Label("Queue last", systemImage: "text.line.last.and.arrowtriangle.forward") }
            } else {
                Button { removeFromUpNext(item) } label: { Label("Remove from Up Next", systemImage: "minus.circle") }
            }
        }
        if item.isDownloaded {
            Button { removeDownload(item) } label: { Label("Remove download", systemImage: "xmark.circle") }
        } else if item.isDownloading {
            Button { removeDownload(item) } label: { Label("Cancel download", systemImage: "xmark.circle") }
        } else {
            Button { download(id) } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
        Button { store.toggleStar(id) } label: {
            Label(item.isStarred ? "Unstar" : "Star", systemImage: item.isStarred ? "star.slash" : "star")
        }
        if item.state.played {
            Button { store.markUnplayed(id) } label: { Label("Mark unplayed", systemImage: "circle") }
        } else {
            Button { markPlayed(item) } label: { Label("Mark played", systemImage: "checkmark.circle") }
            if !item.state.archived {
                Button { archive(item) } label: { Label("Archive", systemImage: "archivebox") }
            }
        }
        // The website's page for it; private feeds have none.
        if ShareLinks.canShare(item.podcast) {
            ShareLink(item: ShareLinks.episode(id), subject: Text(item.episode.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        if context != .podcast {
            Button { app.goToShow(item.podcast.id) } label: { Label("Go to show", systemImage: "rectangle.stack") }
        }
        if context == .podcast {
            Divider()
            Button { markOlderPlayed(item) } label: { Label("Mark all older as played", systemImage: "checkmark.circle.badge.questionmark") }
        }
    }

    enum MenuContext { case upNext, podcast, detail }
}

/// Show notes, as the long-press preview and the episode page.
struct ShowNotesPreview: View {
    var item: EpisodeItem
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ArtworkView(podcast: item.podcast, size: 52, cornerRadius: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.podcast.title).capsLabel(11)
                    Text(item.episode.title).font(.rounded(17, .bold)).foregroundStyle(Palette.ink).lineLimit(2)
                }
            }
            Text("\(Format.relativeDate(item.episode.pubDate)) · \(Format.duration(item.duration))")
                .font(.text(12.5, .medium)).foregroundStyle(Palette.ink2)
            Text(item.episode.showNotesHTML.strippingHTML)
                .font(.text(14.5)).foregroundStyle(Palette.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 340, alignment: .leading)
        .background(Palette.paper)
    }
}

extension String {
    /// Crude HTML to text for show notes until we render them properly.
    var strippingHTML: String {
        replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
