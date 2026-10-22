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

/// "Archived *Episode*  Undo": the one inverted cloud (cocoa on cream, cream on cocoa), so it stands
/// apart from the mini player it sits above.
struct UndoToastView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let toast = app.undo.toast {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Palette.inverseAccent)
                HStack(spacing: 5) {
                    Text(toast.verb).fontWeight(.heavy).foregroundStyle(Palette.inverseInk).fixedSize()
                    Text(toast.subject).foregroundStyle(Palette.inverseInk.opacity(0.78)).lineLimit(1)
                }
                .font(.text(14.5, .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { app.undo.undo() } label: {
                    Text("Undo").font(.rounded(16, .heavy)).foregroundStyle(Palette.inverseAccent)
                        .padding(.horizontal, 14).frame(height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("undoToast.undo")
            }
            .padding(.leading, 16).padding(.trailing, 6)
            .frame(minHeight: 52)
            .background {
                CloudShape(cornerRadius: 22, scallop: 28, depth: 2)
                    .fill(Palette.inverse)
                    .floatShadow(10, y: 6, opacity: 0.25)
            }
            .id(toast.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(toast.verb) \(toast.subject)")
            .accessibilityAction(named: "Undo") { app.undo.undo() }
            .accessibilityIdentifier("undoToast")
            .onAppear { AccessibilityNotification.Announcement("\(toast.verb) \(toast.subject). Undo available.").post() }
        }
    }
}
