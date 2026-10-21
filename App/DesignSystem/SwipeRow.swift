import SwiftUI

/// One swipe action: a coloured tile revealed under the row.
struct SwipeAction {
    var title: String
    var systemImage: String
    var fill: LinearGradient
    var textColor: Color = Palette.creamWhite
    /// Removing actions slide the row off before firing.
    var removesRow = false
    var action: () -> Void

    static func upNext(_ title: String = "Up Next", action: @escaping () -> Void) -> SwipeAction {
        SwipeAction(title: title, systemImage: "square.stack", fill: Fills.actionGold, textColor: Color(hex: 0x3B2A0B), action: action)
    }
    static func top(action: @escaping () -> Void) -> SwipeAction {
        SwipeAction(title: "Move to top", systemImage: "arrow.up.to.line", fill: Fills.actionGold, textColor: Color(hex: 0x3B2A0B), action: action)
    }
    static func played(action: @escaping () -> Void) -> SwipeAction {
        SwipeAction(title: "Played", systemImage: "checkmark", fill: Fills.actionFern, removesRow: true, action: action)
    }
    static func remove(action: @escaping () -> Void) -> SwipeAction {
        SwipeAction(title: "Remove", systemImage: "trash", fill: Fills.actionTomato, removesRow: true, action: action)
    }
    static func archive(action: @escaping () -> Void) -> SwipeAction {
        SwipeAction(title: "Archive", systemImage: "archivebox", fill: Fills.actionInk, removesRow: true, action: action)
    }
}

/// What a short and a long swipe do on one edge. Leading means left to right.
struct SwipeEdge {
    var short: SwipeAction?
    var long: SwipeAction?
    static let none = SwipeEdge()
    var isEmpty: Bool { short == nil && long == nil }
}

extension View {
    /// Overcast-style swipes: drag past the first threshold and let go for the short action, keep
    /// going past the second for the long one. Both tiles show while you drag, the armed one lit.
    func swipeRow(leading: SwipeEdge = .none, trailing: SwipeEdge = .none) -> some View {
        modifier(SwipeRowModifier(leading: leading, trailing: trailing))
    }
}

private enum Armed: Equatable { case none, short, long }

#if os(iOS)
import UIKit

private struct SwipeRowModifier: ViewModifier {
    var leading: SwipeEdge
    var trailing: SwipeEdge
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 390
    @State private var armed: Armed = .none

    private let shortThreshold: CGFloat = 76
    private var longThreshold: CGFloat { max(200, width * 0.56) }

    func body(content: Content) -> some View {
        content
            .background(offset == 0 ? Color.clear : Palette.paper)
            .offset(x: offset)
            .shadow(color: offset == 0 ? .clear : Palette.shadow.opacity(0.25), radius: 8, x: offset < 0 ? 8 : -8)
            .background(alignment: offset < 0 ? .trailing : .leading) {
                if offset != 0 { tiles }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .gesture(HorizontalPan(onChanged: changed, onEnded: ended))
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, new in new != .none }
    }

    private var edge: SwipeEdge { offset < 0 ? trailing : leading }

    @ViewBuilder private var tiles: some View {
        let revealed = abs(offset)
        let both = edge.short != nil && edge.long != nil
        HStack(spacing: 6) {
            if offset < 0 {
                if let long = edge.long { tile(long, lit: armed == .long || (!both && armed != .none), grow: armed == .long || !both) }
                if let short = edge.short, armed != .long || edge.long == nil { tile(short, lit: armed == .short, grow: !both) }
            } else {
                if let short = edge.short, armed != .long || edge.long == nil { tile(short, lit: armed == .short, grow: !both) }
                if let long = edge.long { tile(long, lit: armed == .long || (!both && armed != .none), grow: armed == .long || !both) }
            }
        }
        .padding(8)
        .frame(width: max(0, revealed), alignment: offset < 0 ? .trailing : .leading)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: armed)
    }

    private func tile(_ a: SwipeAction, lit: Bool, grow: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: a.systemImage).font(.system(size: 20, weight: .semibold))
            Text(a.title).font(.text(12, .semibold)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(a.textColor)
        .frame(minWidth: 72, maxWidth: grow ? .infinity : 72, maxHeight: .infinity)
        .background(a.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(lit ? 1 : 0.55)
        .scaleEffect(lit ? 1 : 0.94)
    }

    private func changed(_ x: CGFloat) {
        // Only move towards an edge that has actions, with a little rubber band past the long mark.
        if (x < 0 && trailing.isEmpty) || (x > 0 && leading.isEmpty) { offset = x * 0.15; return }
        let limit = longThreshold + 60
        let mag = abs(x)
        let damped = mag > limit ? limit + (mag - limit) * 0.3 : mag
        offset = x < 0 ? -damped : damped
        let e = x < 0 ? trailing : leading
        if e.long != nil && mag >= longThreshold { armed = .long }
        else if mag >= shortThreshold { armed = e.short != nil ? .short : (e.long != nil ? .long : .none) }
        else { armed = .none }
    }

    private func ended(_ x: CGFloat, _ velocity: CGFloat) {
        let e = offset < 0 ? trailing : leading
        let action: SwipeAction? = switch armed {
        case .long: e.long ?? e.short
        case .short: e.short ?? e.long
        case .none: nil
        }
        let direction: CGFloat = offset < 0 ? -1 : 1
        armed = .none
        guard let action else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { offset = 0 }
            return
        }
        if action.removesRow {
            withAnimation(.easeIn(duration: 0.18)) { offset = direction * (width + 40) }
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { action.action() }
                offset = 0
            }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { offset = 0 }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { action.action() }
        }
    }
}

/// A pan that only starts when the finger moves mostly sideways, so vertical scrolling and the
/// List's long-press reorder keep working.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let x = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: onChanged(x)
        case .ended: onEnded(x, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed: onEnded(0, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.4
        }
    }
}

#else

/// On the Mac, trackpad swipes use the system's swipe actions. Full swipe fires the long action.
private struct SwipeRowModifier: ViewModifier {
    var leading: SwipeEdge
    var trailing: SwipeEdge

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) { buttons(leading) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { buttons(trailing) }
    }

    @ViewBuilder private func buttons(_ e: SwipeEdge) -> some View {
        if let long = e.long { button(long) }
        if let short = e.short { button(short) }
    }

    private func button(_ a: SwipeAction) -> some View {
        Button { withAnimation { a.action() } } label: { Label(a.title, systemImage: a.systemImage) }
            .tint(a.removesRow ? Palette.tomato : Palette.mustard)
    }
}
#endif
