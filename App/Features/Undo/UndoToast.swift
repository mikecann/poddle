import SwiftUI
import PoddleKit

/// The one app-wide Undo toast (decisions.md). A destructive action shows it for about 5 seconds,
/// then it's final. A new action replaces it, and the one before stays done.
@MainActor
@Observable
final class UndoCenter {
    struct Toast: Identifiable {
        let id = UUID()
        /// "Archived"
        var verb: String
        /// The episode or show it happened to.
        var subject: String
        var undo: () -> Void
        /// Runs when the toast expires or is replaced: the point of no return (e.g. deleting a file).
        var commit: () -> Void
    }

    static let duration: Duration = .seconds(5)

    private(set) var toast: Toast?
    @ObservationIgnored private var timer: Task<Void, Never>?

    func show(_ verb: String, _ subject: String, undo: @escaping () -> Void, commit: @escaping () -> Void = {}) {
        finish()
        let t = Toast(verb: verb, subject: subject, undo: undo, commit: commit)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = t }
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled, let self, self.toast?.id == t.id else { return }
            self.finish()
        }
    }

    func undo() {
        guard let t = toast else { return }
        timer?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            toast = nil
            t.undo()
        }
    }

    /// Makes the current action final now.
    func finish() {
        timer?.cancel()
        guard let t = toast else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = nil }
        t.commit()
    }
}

/// "Archived *Episode*  Undo", in the mini player's walnut, sitting above it.
struct UndoToastView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let toast = app.undo.toast {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.mustard)
                HStack(spacing: 5) {
                    Text(toast.verb).fontWeight(.bold).foregroundStyle(Palette.cream).fixedSize()
                    Text(toast.subject).foregroundStyle(Palette.cream.opacity(0.7)).lineLimit(1)
                }
                .font(.text(14, .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { app.undo.undo() } label: {
                    Text("Undo").font(.rounded(15, .heavy)).foregroundStyle(Palette.mustard)
                        .padding(.horizontal, 12).frame(height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
            .padding(.leading, 14).padding(.trailing, 4)
            .frame(minHeight: 48)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Fills.mini)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).inset(by: 0.5).stroke(.white.opacity(0.08), lineWidth: 1))
                    .shadow(color: Color(hex: 0x321E0F, alpha: 0.3), radius: 10, y: 6)
            }
            .id(toast.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(toast.verb) \(toast.subject)")
            .accessibilityAction(named: "Undo") { app.undo.undo() }
            .onAppear { AccessibilityNotification.Announcement("\(toast.verb) \(toast.subject). Undo available.").post() }
        }
    }
}
