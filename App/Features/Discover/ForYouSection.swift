import SwiftUI
import PoddleKit

/// "For you" at the top of Discover (decisions.md, 3 Nov 2026): episodes from shows you don't follow,
/// each with its date and why it's here. It runs on the person's own Exa key, so without one this is
/// the offer to add it.
struct ForYouSection: View {
    var forYou: ForYou
    /// The row being fetched so its page can open, for its spinner.
    var opening: String?
    var addKey: () -> Void
    var open: (SuggestedEpisode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("For you").font(.rounded(22, .heavy)).foregroundStyle(Palette.ink)
                Spacer()
                if let refreshedAt = forYou.refreshedAt, forYou.hasKey, !forYou.picks.isEmpty {
                    Text("Updated \(Format.relativeDate(refreshedAt))").font(.text(13.5, .semibold)).foregroundStyle(Palette.ink2)
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)

            if !forYou.hasKey {
                offer
            } else {
                if let error = forYou.error { notice(error) }
                if forYou.picks.isEmpty {
                    if forYou.refreshing {
                        HStack(spacing: 10) {
                            ProgressView().tint(Palette.tomato)
                            Text("Finding episodes for you…").font(.text(15, .medium)).foregroundStyle(Palette.ink2)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .accessibilityIdentifier("forYou.loading")
                    } else if forYou.error == nil {
                        notice("Nothing yet. Listen to a few episodes and check back next week.")
                    }
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(forYou.picks) { pick in
                            row(pick)
                                .cloudCard()
                                .padding(.horizontal, 12)
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityIdentifier("forYou.episode.\(pick.id)")
                        }
                    }
                }
            }
        }
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Get episodes picked for you").font(.text(17, .bold)).foregroundStyle(Palette.ink)
            Text("Poddle searches podcast transcripts with Exa, using your own key, so you pay Exa directly: about 50c a month. It sends the titles of episodes you've listened to, never your private shows.")
                .font(.text(14.5)).foregroundStyle(Palette.body)
            PoddleButton(title: "Add your Exa key", kind: .primary, action: addKey)
                .padding(.top, 8)
                .accessibilityIdentifier("forYou.addKey")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cloudCard()
        .padding(.horizontal, 16)
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.text(14.5)).foregroundStyle(Palette.ink2)
            .padding(.horizontal, 20).padding(.bottom, 8)
            .accessibilityIdentifier("forYou.notice")
    }

    private func row(_ pick: SuggestedEpisode) -> some View {
        // The date's here because Mike doesn't want to listen to anything super old, and should be able to tell.
        let details = [pick.showTitle, Format.relativeDate(pick.pubDate), Format.duration(pick.duration)]
        return HStack(spacing: 12) {
            ArtworkView(title: pick.showTitle, artworkURL: pick.artworkURL, size: 56, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(pick.title).font(.text(15.5, .bold)).foregroundStyle(Palette.ink).lineLimit(2)
                Text(details.joined(separator: " · ")).font(.text(13)).foregroundStyle(Palette.ink2).lineLimit(1)
                Text(pick.reason).font(.text(12.5, .semibold)).foregroundStyle(Palette.tomatoText).lineLimit(2).padding(.top, 2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 8) {
                if let position = pick.chartPosition {
                    Text("#\(position) chart").font(.text(11.5, .bold)).foregroundStyle(Palette.goldInk)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Palette.goldBg, in: Capsule())
                        .fixedSize()
                }
                if opening == pick.id {
                    ProgressView().tint(Palette.tomato)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink3)
                }
            }
        }
        .padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { open(pick) }
    }
}

/// Pasting in an Exa key. It goes straight to the server and never comes back to the app.
struct ExaKeySheet: View {
    @Environment(PoddleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var saving = false
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Exa key").font(.rounded(24, .heavy)).foregroundStyle(Palette.ink)
            Text("Sign up at Exa, make an API key and paste it here. Poddle keeps it encrypted and only uses it for your suggestions, about once a week.")
                .font(.text(15)).foregroundStyle(Palette.body)
            Link("Get a key from Exa", destination: URL(string: "https://dashboard.exa.ai/api-keys")!)
                .font(.text(15, .bold)).tint(Palette.tomato)
            SecureField("Paste your key", text: $key)
                .font(.mono(14))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .padding(.horizontal, 14).frame(height: 46)
                .well(Capsule())
                .accessibilityIdentifier("forYou.keyField")
            if let failed {
                Text(failed).font(.text(14)).foregroundStyle(Palette.tomatoText)
            }
            HStack {
                PoddleButton(title: "Cancel", kind: .quiet) { dismiss() }
                PoddleButton(title: saving ? "Saving…" : "Save", kind: .primary) { save() }
                    .disabled(saving || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("forYou.saveKey")
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(20)
        .background(Palette.paper)
        .presentationDetents([.medium])
    }

    private func save() {
        saving = true
        failed = nil
        Task {
            defer { saving = false }
            do {
                try await store.setExaKey(key)
                dismiss()
            } catch {
                failed = "That didn't save. Check the key and try again."
            }
        }
    }
}

/// Profile's row: add, or see which key's in use and remove it.
struct ExaKeyRow: View {
    @Environment(PoddleStore.self) private var store
    @State private var forYou: ForYou?
    @State private var adding = false

    var body: some View {
        Cell(title: "Exa key", subtitle: subtitle, icon: "sparkles", iconTint: Palette.mustard) {
            if forYou?.hasKey == true {
                Button("Remove") {
                    Task {
                        try? await store.removeExaKey()
                        await load()
                    }
                }
                .font(.text(15, .bold)).foregroundStyle(Palette.tomato).buttonStyle(.plain)
                .accessibilityIdentifier("settings.exaKey.remove")
            } else {
                Button("Add") { adding = true }
                    .font(.text(15, .bold)).foregroundStyle(Palette.tomato).buttonStyle(.plain)
                    .accessibilityIdentifier("settings.exaKey.add")
            }
        }
        .sheet(isPresented: $adding) { ExaKeySheet() }
        .task(id: adding) { if !adding { await load() } }
    }

    private var subtitle: String {
        if let ending = forYou?.keyEnding { return "Ending \(ending), used for your suggestions in Discover" }
        return "Your own key pays for suggestions in Discover"
    }

    /// Profile can be set up before sign-in has finished, so a first failure gets a few more tries.
    private func load() async {
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
            guard !Task.isCancelled else { return }
            if let latest = try? await store.forYou() {
                forYou = latest
                return
            }
        }
    }
}
