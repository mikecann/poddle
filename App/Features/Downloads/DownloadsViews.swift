import SwiftUI
import PoddleKit

/// "Mobile downloads · 52m left · Stop", while a temporary mobile allowance is on.
struct MobileAllowanceChip: View {
    @Environment(PoddleStore.self) private var store

    var body: some View {
        if let downloader = store.downloader, downloader.settings.mobileAllowedUntil != nil {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                if let remaining = downloader.mobileAllowanceRemaining {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 12, weight: .bold))
                        Text("Mobile downloads · \(Self.left(remaining))").font(.text(13, .semibold)).monospacedDigit()
                        Button("Stop") { withAnimation { downloader.stopMobileAllowance() } }
                            .font(.text(13, .bold))
                            .foregroundStyle(Palette.tomato)
                            .accessibilityLabel("Stop mobile downloads")
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .raised(Capsule())
                    .accessibilityIdentifier("mobileAllowanceChip")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    /// "52m left", "2h 10m left", "until midnight".
    static func left(_ seconds: TimeInterval) -> String {
        Format.duration(max(60, seconds)) + " left"
    }
}

/// The prompt for tapping download on one episode over mobile data in Wi-Fi-only mode.
struct MobileDownloadPrompt: ViewModifier {
    @Environment(PoddleStore.self) private var store
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        @Bindable var app = app
        content.confirmationDialog(
            "You're on mobile data",
            isPresented: Binding(get: { app.mobilePromptEpisodeId != nil }, set: { if !$0 { app.mobilePromptEpisodeId = nil } }),
            titleVisibility: .visible,
            presenting: app.mobilePromptEpisodeId
        ) { id in
            ForEach(MobilePromptChoice.allCases, id: \.self) { choice in
                Button(choice.label) { store.resolveMobilePrompt(choice, episodeId: id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { id in
            let size = store.episode(id)?.enclosureLength.map { Format.bytes(Int64($0)) }
            Text("Downloads are set to Wi-Fi only." + (size.map { " This one is \($0)." } ?? ""))
        }
    }
}

extension Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
