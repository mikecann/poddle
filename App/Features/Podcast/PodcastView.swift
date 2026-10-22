import SwiftUI
import PoddleKit

struct PodcastView: View {
    var podcastId: String
    @Environment(PoddleStore.self) private var store
    @Environment(\.player) private var player
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = false
    @State private var confirmUnsubscribe = false
    @State private var copied = 0

    var body: some View {
        if let podcast = store.podcast(podcastId) {
            content(podcast)
        } else {
            BrandPlaceholder(title: "Show not found", message: "It may no longer be available, or it may be from a private feed.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.paper.ignoresSafeArea())
        }
    }

    private func content(_ podcast: Podcast) -> some View {
        let order = store.resolved(podcastId).episodeOrder
        let episodes = store.episodes(of: podcastId)
        let actions = EpisodeActions(store: store, player: player, app: app)
        return List {
            VStack(alignment: .leading, spacing: 0) {
                TopBar {
                    BackButton(title: "Library")
                } trailing: {
                    // The website's page for the show; private feeds have none.
                    if ShareLinks.canShare(podcast) {
                        ShareLink(item: ShareLinks.show(podcast.id), subject: Text(podcast.title)) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Palette.tomato).frame(width: 40, height: 40).raised(Circle())
                        }
                        .buttonStyle(.pressable)
                        .padding(.horizontal, 4)
                        .accessibilityLabel("Share")
                        .accessibilityIdentifier("podcast.share")
                    }
                    Menu { headerMenu(podcast) } label: {
                        Image(systemName: "ellipsis").font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(Palette.tomato).frame(width: 40, height: 40).raised(Circle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).padding(.horizontal, 4)
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("podcast.more")
                }
                header(podcast)
                    .contextMenu { headerMenu(podcast) }
                Text(podcast.description)
                    .font(.text(15)).foregroundStyle(Palette.body)
                    .lineLimit(expanded ? nil : 3)
                    .overlay(alignment: .bottomTrailing) {
                        if !expanded {
                            Button("More") { withAnimation { expanded = true } }
                                .font(.text(15, .bold)).foregroundStyle(Palette.tomato)
                                .accessibilityIdentifier("podcast.descriptionMore")
                                .padding(.leading, 44)
                                .background(LinearGradient(colors: [Palette.paper.opacity(0), Palette.paper, Palette.paper], startPoint: .leading, endPoint: .trailing))
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 14)
                buttons(podcast).padding(.top, 14)
                HStack {
                    Text("Episodes").font(.rounded(22, .heavy)).foregroundStyle(Palette.ink)
                    Spacer()
                    Menu {
                        Picker("Order", selection: Binding(get: { order.value }, set: { v in store.updateSettings(podcastId) { $0.episodeOrder = v } })) {
                            ForEach(EpisodeOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(order.value.label)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .bold))
                        }
                        .font(.text(14, .bold)).foregroundStyle(Palette.tomato)
                        .padding(.horizontal, 12).frame(height: 34)
                        .raised(Capsule())
                    }
                    .menuStyle(.button).buttonStyle(.plain)
                    .accessibilityIdentifier("podcast.order")
                }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 4)
            }
            .plainListRow()

            ForEach(episodes) { item in
                PodcastEpisodeRow(item: item) {
                    if item.isQueued { actions.removeFromUpNext(item) } else { store.queueLast(item.id) }
                }
                .cloudCard()
                .padding(.vertical, 4)
                .swipeRow(
                    leading: SwipeEdge(
                        short: .upNext("Add to Up Next") { store.queueLast(item.id) },
                        long: SwipeAction(title: "Play next", systemImage: "text.line.first.and.arrowtriangle.forward", fill: Fills.actionTomato) { store.playNext(item.id) }
                    ),
                    trailing: item.state.played
                        ? SwipeEdge(short: SwipeAction(title: "Unplayed", systemImage: "circle", fill: Fills.actionInk) { store.markUnplayed(item.id) })
                        : SwipeEdge(short: .played { actions.markPlayed(item) }.keepingRow)
                )
                .onTapGesture { app.push(.episode(item.id)) }
                .contextMenu {
                    actions.menu(for: item, context: .podcast)
                } preview: {
                    ShowNotesPreview(item: item)
                }
                .padding(.horizontal, 12)
                .accessibilityIdentifier("podcast.episode.\(item.id)")
                .plainListRow()
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("podcast.list")
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh(podcastId: podcastId) }
        .task(id: podcastId) { await store.observePodcast(podcastId) }
        .sensoryFeedback(.success, trigger: copied)
        .confirmationDialog("Unsubscribe from \(podcast.title)?", isPresented: $confirmUnsubscribe, titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) { actions.unsubscribe(podcast) }
        } message: {
            Text("Your history stays, under Past shows in the Library.")
        }
    }

    private func header(_ podcast: Podcast) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            ArtworkView(podcast: podcast, size: 128, cornerRadius: 0, shadow: false)
                .clipShape(CloudShape(cornerRadius: 28, scallop: 30, depth: 2.5))
                .background { CloudShape(cornerRadius: 28, scallop: 30, depth: 2.5).fill(Palette.cardEdge).offset(y: 4) }
                .floatShadow(10, y: 8, opacity: 0.2)
            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title).font(.rounded(30, .heavy)).tracking(-0.5).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(podcast.author).font(.text(14, .medium)).foregroundStyle(Palette.ink2).lineLimit(2)
                HStack(spacing: 6) {
                    if podcast.isPrivate { PrivateBadge() }
                    if let c = podcast.category { Tag(text: c) }
                    if let cadence = store.cadence(podcastId) { Tag(text: cadence) }
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    private func buttons(_ podcast: Podcast) -> some View {
        HStack(spacing: 8) {
            Button {
                if podcast.subscribed { confirmUnsubscribe = true } else { store.subscribe(feedURL: podcast.feedURL) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: podcast.subscribed ? "checkmark" : "plus").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(podcast.subscribed ? Palette.fern : Palette.tomato)
                    Text(podcast.subscribed ? "Following" : "Follow")
                }
                .font(.text(15, .bold)).foregroundStyle(Palette.ink)
                .padding(.horizontal, 16).frame(height: 40)
                .raised(Capsule())
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("podcast.follow")

            Button { app.sheet = .showSettings(podcastId: podcastId) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 0) {
                        Text("Settings").font(.text(15, .semibold)).foregroundStyle(Palette.ink)
                        Text(" · \(settingsSummary)").font(.text(13, .medium)).foregroundStyle(store.settings(for: podcastId).hasOverrides ? Palette.goldInk : Palette.ink2)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink3)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 14).frame(height: 40)
                .raised(Capsule())
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("podcast.settings")
        }
        .padding(.horizontal, 20)
    }

    private var settingsSummary: String {
        let s = store.settings(for: podcastId)
        var parts: [String] = []
        if let speed = s.speed { parts.append(Format.speed(speed)) }
        if let add = s.autoAdd { parts.append(add.choiceLabel) }
        let rest = [s.smartSpeed != nil, s.voiceBoost != nil, s.skipIntro != nil, s.skipOutro != nil, s.keepLatest != nil,
                    s.notifications != nil, s.autoDownload != nil, s.episodeOrder != nil, s.autoArchive != nil].filter { $0 }.count
        if parts.isEmpty && rest == 0 { return "Using defaults" }
        if rest > 0 { parts.append("\(rest) more") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func headerMenu(_ podcast: Podcast) -> some View {
        let actions = EpisodeActions(store: store, player: player, app: app)
        Button { app.sheet = .showSettings(podcastId: podcastId) } label: { Label("Settings", systemImage: "slider.horizontal.3") }
        if !podcast.isPrivate {
            ShareLink(item: URL(string: podcast.feedURL)!) { Label("Share feed", systemImage: "square.and.arrow.up") }
        }
        Button { Clipboard.copy(podcast.feedURL); copied += 1 } label: { Label("Copy feed URL", systemImage: "doc.on.doc") }
        Button { actions.markAllPlayed(podcast) } label: { Label("Mark all played", systemImage: "checkmark.circle") }
        if podcast.subscribed {
            Button(role: .destructive) { confirmUnsubscribe = true } label: { Label("Unsubscribe", systemImage: "minus.circle") }
        }
    }
}

private struct PodcastEpisodeRow: View {
    var item: EpisodeItem
    var onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if item.isNew { Text("NEW").font(.rounded(10.5, .heavy)).tracking(0.84).foregroundStyle(Palette.tomato) }
                    if item.isStarred { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Palette.mustard) }
                    Text("\(Format.relativeDate(item.episode.pubDate)) · \(Format.duration(item.duration))")
                }
                .font(.text(12, .semibold)).foregroundStyle(Palette.ink2)
                Text(item.episode.title).font(.text(16, .bold)).tracking(-0.1).foregroundStyle(Palette.ink).lineLimit(2)
                HStack(spacing: 7) {
                    if item.isInProgress {
                        ProgressBar(value: item.progress)
                        Text("\(Format.duration(item.wallRemaining)) left").fontWeight(.semibold).foregroundStyle(Palette.ink)
                    } else if !item.state.played {
                        Text("\(Format.duration(item.wallRemaining)) at \(Format.speed(item.speed.value)) ·")
                    } else {
                        Text("Played")
                    }
                    if item.isQueued {
                        Text("· In Up Next")
                    } else if !item.state.played {
                        DownloadGlyph(item: item)
                    }
                }
                .font(.text(12.5, .medium)).foregroundStyle(Palette.ink2).monospacedDigit()
            }
            .opacity(item.state.played ? 0.45 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onAdd) {
                Image(systemName: item.isQueued ? "checkmark" : "plus")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(item.isQueued ? Palette.fern : Palette.tomato)
                    .frame(width: 40, height: 40)
                    .background {
                        if item.isQueued { Circle().fill(Palette.fern.opacity(0.12)) } else { Color.clear.raised(Circle()) }
                    }
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .opacity(item.state.played ? 0.6 : 1)
            .accessibilityLabel(item.isQueued ? "Remove from Up Next" : "Add to Up Next")
            .accessibilityIdentifier("podcast.episode.add.\(item.id)")
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
        .frame(minHeight: 80)
        .contentShape(Rectangle())
    }
}

extension SwipeAction {
    /// Same action, but the row stays (it's still listed on the podcast page).
    var keepingRow: SwipeAction {
        var copy = self
        copy.removesRow = false
        return copy
    }
}

/// Copying to the system clipboard on both platforms.
enum Clipboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
