import SwiftUI
import PoddleKit

/// Row content shared by Up Next and the Inbox: artwork, show line, title and the time/speed line.
struct EpisodeRow: View {
    enum Style { case queue, inbox }
    var item: EpisodeItem
    var style: Style
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
            if style == .inbox {
                Text(Format.relativeDate(item.episode.pubDate)).foregroundStyle(Palette.ink2)
                Text("·").foregroundStyle(Palette.ink3)
            }
            if item.isInProgress {
                ProgressBar(value: item.progress)
                Text(Format.duration(item.wallRemaining) + " left").fontWeight(.semibold).foregroundStyle(Palette.ink)
            } else {
                Text(Format.duration(item.wallRemaining)).fontWeight(.semibold).foregroundStyle(Palette.ink)
            }
            Text("at \(Format.speed(item.speed.value))").foregroundStyle(Palette.ink2)
            DownloadGlyph(item: item)
            if !item.isDownloaded && !item.isDownloading && style == .queue {
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

/// Everything you can do to an episode, used by context menus and swipes.
struct EpisodeActions {
    var store: PoddleStore
    var player: MockPlayer
    var app: AppModel

    func playNow(_ id: String) {
        player.play(id)
    }

    /// Top of the visible Up Next list: straight after whatever's playing.
    func moveToTopOfUpNext(_ id: String) {
        if player.currentEpisodeId == nil { store.moveToTop(id) } else { store.playNext(id) }
    }

    @ViewBuilder
    func menu(for item: EpisodeItem, context: MenuContext) -> some View {
        let id = item.id
        Button { playNow(id) } label: { Label("Play now", systemImage: "play") }
        switch context {
        case .upNext:
            Button { moveToTopOfUpNext(id) } label: { Label("Move to top", systemImage: "arrow.up.to.line") }
            Button { store.moveToBottom(id) } label: { Label("Move to bottom", systemImage: "arrow.down.to.line") }
        case .inbox, .podcast, .detail:
            if !item.isQueued {
                Button { store.playNext(id) } label: { Label("Queue next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button { store.queueLast(id) } label: { Label("Queue last", systemImage: "text.line.last.and.arrowtriangle.forward") }
            } else {
                Button { store.removeFromQueue(id) } label: { Label("Remove from Up Next", systemImage: "minus.circle") }
            }
        }
        if item.isDownloaded {
            Button { store.removeDownload(id) } label: { Label("Remove download", systemImage: "xmark.circle") }
        } else {
            Button { store.download(id) } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
        Button { store.toggleStar(id) } label: {
            Label(item.isStarred ? "Unstar" : "Star", systemImage: item.isStarred ? "star.slash" : "star")
        }
        if item.state.played {
            Button { store.markUnplayed(id) } label: { Label("Mark unplayed", systemImage: "circle") }
        } else {
            Button { store.markPlayed(id) } label: { Label("Mark played", systemImage: "checkmark.circle") }
        }
        if context == .inbox {
            Button { store.archive(id) } label: { Label("Archive", systemImage: "archivebox") }
        }
        ShareLink(item: URL(string: item.episode.enclosureURL) ?? URL(string: "https://poddle.app")!, subject: Text(item.episode.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        if context != .podcast {
            Button { app.goToShow(item.podcast.id) } label: { Label("Go to show", systemImage: "rectangle.stack") }
        }
        if context == .inbox {
            Divider()
            Button { store.archiveOlder(id) } label: { Label("Archive all older from this show", systemImage: "archivebox.circle") }
        }
        if context == .podcast {
            Divider()
            Button { store.markOlderPlayed(id) } label: { Label("Mark all older as played", systemImage: "checkmark.circle.badge.questionmark") }
        }
    }

    enum MenuContext { case upNext, inbox, podcast, detail }
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
