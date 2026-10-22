import SwiftUI

/// Approved poodle illustrations. Decorative beside text, so VoiceOver reads the message once.
/// For one that moves, use `Companion`.
struct Mascot: View {
    enum Pose: String {
        case listening, sleeping, waving, empty, searching, confused
        /// The companion's own poses (designs/branding/final/src-companion).
        case peek, peekSleepy = "peek-sleepy", celebrate, trot
    }
    var pose: Pose
    var size: CGFloat = 160

    var body: some View {
        Image("Mascot/\(pose.rawValue)")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct PoddleWordmark: View {
    var size: CGFloat = 44

    var body: some View {
        Text("Poddle")
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .tracking(-size * 0.035)
            .foregroundStyle(Palette.ink)
    }
}

/// The mock's header logo: the peeking poodle's head beside the wordmark.
struct BrandLockup: View {
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: 6) {
            Image("Mascot/peek").resizable().scaledToFit()
                .frame(height: size * 1.05)
                .accessibilityHidden(true)
            PoddleWordmark(size: size)
        }
        .padding(.leading, 12)
        .accessibilityElement()
        .accessibilityLabel("Poddle")
        .accessibilityAddTraits(.isHeader)
    }
}

/// An empty, searching or error state: the companion doing the matching thing, then a message.
struct BrandPlaceholder: View {
    var pose: Mascot.Pose = .confused
    var title: String
    var message: String
    var size: CGFloat = 150

    var body: some View {
        VStack(spacing: 10) {
            Companion(pose: pose, motion: CompanionMotion.natural(for: pose), size: size, tappable: true)
                .frame(height: size)
            Text(title).font(.rounded(21, .heavy)).foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text(message).font(.text(15, .medium)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("placeholder-\(pose.rawValue)")
    }
}

struct ListeningBrandFooter: View {
    var body: some View {
        Companion(pose: .listening, motion: .still, size: 112)
            .frame(height: 100)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
    }
}
