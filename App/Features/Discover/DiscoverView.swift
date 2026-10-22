import SwiftUI
import PoddleKit

/// Search the Apple Podcasts directory, or add any feed by URL (offered straight from the clipboard).
struct DiscoverView: View {
    @Environment(PoddleStore.self) private var store
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var response: SearchResponse?
    @State private var searching = false
    @State private var searchError: String?
    @State private var clipboard = ClipboardState.none
    @State private var manualURL = ""
    @State private var showManual = false
    @State private var toast: String?
    @State private var followed = 0
    @FocusState private var focused: Bool

    enum ClipboardState: Equatable {
        case none
        /// iOS knows there's a link without reading it (no paste prompt).
        case hasLink
        case link(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TopBar { BrandLockup() } trailing: { EmptyView() }
                    .frame(height: 52)
                LargeTitle(title: "Discover").padding(.top, 2)
                searchBar.padding(.top, 12)
                urlCard.padding(.top, 14)
                results
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .overlay(alignment: .top) { toastView }
        .sensoryFeedback(.success, trigger: followed)
        .task(id: query) { await runSearch() }
        .task { await checkClipboard() }
        .onAppear { if query.isEmpty && !app.discoverQuery.isEmpty { query = app.discoverQuery } }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await checkClipboard() }
        }
        #endif
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.ink2)
                TextField("Shows, people, topics", text: $query)
                    .font(.text(17, .medium))
                    .foregroundStyle(Palette.ink)
                    .tint(Palette.tomato)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("discover.search")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(Palette.ink3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                    .accessibilityIdentifier("discover.clear")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .well(Capsule())
            if focused || !query.isEmpty {
                Button("Cancel") { query = ""; focused = false }
                    .font(.text(17, .bold)).foregroundStyle(Palette.tomato)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .accessibilityIdentifier("discover.cancel")
            }
        }
        .padding(.horizontal, 16)
        .animation(.snappy, value: focused || !query.isEmpty)
    }

    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        searchError = nil
        guard !term.isEmpty else { response = nil; return }
        try? await Task.sleep(for: .milliseconds(400)) // debounce, Apple allows ~20 calls a minute
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let r = try await store.search(term)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { response = r }
        } catch {
            if !Task.isCancelled { searchError = "Please try again, or paste a show's feed URL above." }
        }
    }

    @ViewBuilder private var results: some View {
        if searching {
            BrandPlaceholder(pose: .searching, title: "Searching…", message: "Looking through Apple Podcasts.")
        } else if let searchError {
            BrandPlaceholder(title: "Couldn't search", message: searchError)
            PoddleButton(title: "Try again", kind: .quiet) { Task { await runSearch() } }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("discover.retry")
        } else if let response, !query.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text("Apple Podcasts").font(.rounded(22, .heavy)).foregroundStyle(Palette.ink)
                Spacer()
                Text(searching ? "Searching…" : "\(response.totalCount) results").font(.text(13.5, .semibold)).foregroundStyle(Palette.ink2)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 4)
            if response.results.isEmpty {
                BrandPlaceholder(pose: .searching, title: "No shows found",
                                 message: "Nothing for \"\(query)\". Try a show's name, or paste its feed URL above.")
            }
            LazyVStack(spacing: 8) {
                ForEach(response.results) { r in
                    resultRow(r)
                        .cloudCard()
                        .padding(.horizontal, 12)
                        .accessibilityIdentifier("discover.result.\(r.id)")
                }
            }
            Color.clear.frame(height: 20)
        } else {
            Companion(pose: .searching, motion: .sway, size: 140)
                .frame(height: 140)
                .frame(maxWidth: .infinity).padding(.top, 20)
            VStack(alignment: .leading, spacing: 12) {
                Text("Try").font(.rounded(22, .heavy)).foregroundStyle(Palette.ink)
                FlowChips(items: ["ai", "web dev", "history", "apple", "design", "comedy", "security", "business"]) { query = $0 }
            }
            .padding(.horizontal, 20).padding(.top, 24)
        }
    }

    private func resultRow(_ r: SearchResult) -> some View {
        let following = store.isFollowing(feedURL: r.feedURL)
        return HStack(spacing: 12) {
            ArtworkView(title: r.title, artworkURL: r.artworkURL, size: 56, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.text(16, .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text("\(r.author) \(Text("· \(r.genre)").foregroundStyle(Palette.ink3))")
                    .font(.text(13)).foregroundStyle(Palette.ink2).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                if following {
                    if let id = store.podcastId(feedURL: r.feedURL) { app.push(.podcast(id)) }
                } else {
                    withAnimation(.snappy) { store.subscribe(r) }
                    followed += 1
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: following ? "checkmark" : "plus").font(.system(size: 13, weight: .heavy))
                    Text(following ? "Following" : "Follow")
                }
                .font(.rounded(14, .heavy))
                .foregroundStyle(following ? Palette.fern : Palette.onTomato)
                .padding(.horizontal, 14).frame(height: 36)
                .background { if following { Capsule().fill(Palette.fern.opacity(0.12)) } else { Color.clear.raised(Capsule(), fill: Palette.chipOn) } }
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("discover.follow.\(r.id)")
        }
        .padding(.leading, 12).padding(.trailing, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if let id = store.podcastId(feedURL: r.feedURL) { app.push(.podcast(id)) } }
    }

    // MARK: Add by URL

    private var urlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "link").font(.system(size: 18, weight: .bold)).foregroundStyle(Palette.onTomato)
                    .frame(width: 44, height: 44)
                    .background(Palette.chipOn, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add by URL").font(.text(16, .bold)).foregroundStyle(Palette.ink)
                    switch clipboard {
                    case let .link(url):
                        Text("Found on your clipboard:").font(.text(12.5)).foregroundStyle(Palette.ink2)
                        Text(displayURL(url)).font(.mono(12)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 4))
                    case .hasLink:
                        Text("There's a link on your clipboard").font(.text(12.5)).foregroundStyle(Palette.ink2)
                    case .none:
                        Text("RSS, Apple Podcasts or Overcast links. Private feeds too.").font(.text(12.5)).foregroundStyle(Palette.ink2)
                    }
                }
                Spacer(minLength: 4)
                if clipboard != .none {
                    PoddleButton(title: "Paste", kind: .primary) { Task { await pasteFromClipboard() } }
                        .fixedSize()
                        .accessibilityIdentifier("discover.paste")
                } else {
                    PoddleButton(title: showManual ? "Close" : "Type", kind: .quiet) { withAnimation(.snappy) { showManual.toggle() } }
                        .fixedSize()
                        .accessibilityIdentifier("discover.type")
                }
            }
            if showManual {
                HStack(spacing: 8) {
                    TextField("https://…", text: $manualURL)
                        .font(.mono(13))
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12).frame(height: 40)
                        .well(Capsule())
                        .onSubmit { Task { await add(manualURL) } }
                        .accessibilityIdentifier("discover.urlField")
                    PoddleButton(title: "Add", kind: .primary) { Task { await add(manualURL) } }.fixedSize()
                        .accessibilityIdentifier("discover.add")
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 14)
        .cloudCard()
        .padding(.horizontal, 16)
    }

    private func displayURL(_ s: String) -> String {
        s.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    private func checkClipboard() async {
        if let fake = app.fakeClipboard { clipboard = .link(fake); return }
        #if os(iOS)
        let pb = UIPasteboard.general
        guard pb.hasURLs || pb.hasStrings else { clipboard = .none; return }
        // Detecting a pattern doesn't trigger the paste prompt; reading does, so we wait for a tap.
        let patterns = (try? await pb.detectedPatterns(for: [\.probableWebURL])) ?? []
        clipboard = pb.hasURLs || patterns.contains(\.probableWebURL) ? .hasLink : .none
        #else
        if let s = NSPasteboard.general.string(forType: .string), s.hasPrefix("http") { clipboard = .link(s) } else { clipboard = .none }
        #endif
    }

    private func pasteFromClipboard() async {
        var url: String?
        if case let .link(s) = clipboard { url = s }
        #if os(iOS)
        if url == nil { url = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string }
        #endif
        guard let url else { return }
        await add(url)
    }

    private func add(_ url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Token-in-URL feeds are private: never sent to directory lookups or shown on share cards.
        let isPrivate = trimmed.contains("token=") || trimmed.contains("@") || trimmed.contains("/private")
        if let found = try? await store.resolve(url: trimmed) {
            if store.isFollowing(feedURL: found.feedURL) {
                show("Already following \(found.title)")
            } else {
                store.subscribe(found, isPrivate: isPrivate)
                show("Following \(found.title)")
                followed += 1
            }
            manualURL = ""
            showManual = false
            clipboard = .none
        } else {
            show("Couldn't find a feed at that link")
        }
    }

    private func show(_ message: String) {
        withAnimation(.spring) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast).font(.text(14.5, .bold)).foregroundStyle(Palette.inverseInk)
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(Palette.inverse, in: Capsule())
                .floatShadow(8, y: 4, opacity: 0.25)
                .accessibilityIdentifier("discover.toast")
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Wrapping row of suggestion chips.
private struct FlowChips: View {
    var items: [String]
    var onTap: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Chip(title: item, count: nil, isOn: false) { onTap(item) }
                    .accessibilityIdentifier("discover.suggestion.\(item)")
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 360, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (i, p) in result.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x)
            rowH = max(rowH, size.height)
        }
        return (points, CGSize(width: maxX, height: y + rowH))
    }
}
