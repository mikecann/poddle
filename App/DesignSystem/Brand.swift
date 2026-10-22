import SwiftUI

/// Approved poodle illustrations. Decorative beside text, so VoiceOver reads the message once.
struct Mascot: View {
    enum Pose: String { case listening, sleeping, waving, empty, searching, confused }
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

struct BrandPlaceholder: View {
    var pose: Mascot.Pose = .confused
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Mascot(pose: pose)
            Text(title).font(.rounded(20, .bold)).foregroundStyle(Palette.ink)
            Text(message).font(.text(14)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

struct ListeningBrandFooter: View {
    var body: some View {
        Mascot(pose: .listening, size: 112)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
    }
}
