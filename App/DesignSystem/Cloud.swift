import SwiftUI
import os

// Cloud Fluff's shapes: gently scalloped "curl-edge" cards and the line of curls that fills in as
// you listen. Everything here is a plain nonisolated `Shape`, so SwiftUI can build and resolve
// it off the main thread, and the scalloped paths are cached by size so a scrolling list doesn't
// rebuild the same outline for every row.

/// A rounded rectangle whose straight edges are a row of shallow curls, like the poodle's coat.
nonisolated struct CloudShape: InsettableShape {
    var cornerRadius: CGFloat = 20
    /// Roughly how wide one curl is along an edge. The count rounds so curls fill each edge evenly.
    var scallop: CGFloat = 30
    /// How far each curl bulges out. Small on purpose: gently scalloped, not cartoonish.
    var depth: CGFloat = 2
    var edges: Edge.Set = .all
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let key = CloudPathCache.Key(width: rect.width, height: rect.height, cornerRadius: cornerRadius, scallop: scallop,
                                     depth: depth, edges: edges.rawValue, inset: insetAmount)
        return CloudPathCache.path(for: key).offsetBy(dx: rect.minX, dy: rect.minY)
    }

    func inset(by amount: CGFloat) -> CloudShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    /// The outline at the origin. Each curl is a quadratic bump whose peak sits `depth` outside
    /// the base rectangle, so the whole shape stays inside the frame it's given.
    fileprivate static func makePath(_ key: CloudPathCache.Key) -> Path {
        let edges = Edge.Set(rawValue: key.edges)
        let d = key.depth
        func pad(_ e: Edge.Set) -> CGFloat { key.inset + (edges.contains(e) ? d : 0) }
        let r = CGRect(x: pad(.leading), y: pad(.top),
                       width: max(0, key.width - pad(.leading) - pad(.trailing)),
                       height: max(0, key.height - pad(.top) - pad(.bottom)))
        let cr = max(0, min(key.cornerRadius - key.inset, r.width / 2, r.height / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX + cr, y: r.minY))
        edge(&p, to: CGPoint(x: r.maxX - cr, y: r.minY), normal: CGVector(dx: 0, dy: -1), on: edges.contains(.top), key)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + cr), radius: cr)
        edge(&p, to: CGPoint(x: r.maxX, y: r.maxY - cr), normal: CGVector(dx: 1, dy: 0), on: edges.contains(.trailing), key)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - cr, y: r.maxY), radius: cr)
        edge(&p, to: CGPoint(x: r.minX + cr, y: r.maxY), normal: CGVector(dx: 0, dy: 1), on: edges.contains(.bottom), key)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - cr), radius: cr)
        edge(&p, to: CGPoint(x: r.minX, y: r.minY + cr), normal: CGVector(dx: -1, dy: 0), on: edges.contains(.leading), key)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + cr, y: r.minY), radius: cr)
        p.closeSubpath()
        return p
    }

    private static func edge(_ p: inout Path, to end: CGPoint, normal n: CGVector, on: Bool, _ key: CloudPathCache.Key) {
        let start = p.currentPoint ?? end
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard on, length > 1 else { p.addLine(to: end); return }
        let count = max(1, Int((length / key.scallop).rounded()))
        // A quadratic's peak is half way to its control point, so push the control out twice as far.
        let bulge = key.depth * 2
        for i in 1...count {
            let t0 = CGFloat(i - 1) / CGFloat(count), t1 = CGFloat(i) / CGFloat(count)
            let mid = CGPoint(x: start.x + dx * (t0 + t1) / 2, y: start.y + dy * (t0 + t1) / 2)
            p.addQuadCurve(to: CGPoint(x: start.x + dx * t1, y: start.y + dy * t1),
                           control: CGPoint(x: mid.x + n.dx * bulge, y: mid.y + n.dy * bulge))
        }
    }
}

/// Built outlines, keyed by size and style. Rows in a list share a handful of sizes, so this stays
/// small; it's emptied if it ever grows past a few hundred (rotation, Dynamic Type changes).
nonisolated enum CloudPathCache {
    struct Key: Hashable, Sendable {
        var width: CGFloat, height: CGFloat, cornerRadius: CGFloat, scallop: CGFloat, depth: CGFloat
        var edges: Int8, inset: CGFloat
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [Key: Path]())

    static func path(for key: Key) -> Path {
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let made = CloudShape.makePath(key)
        cache.withLock { cache in
            if cache.count > 400 { cache.removeAll(keepingCapacity: true) }
            cache[key] = made
        }
        return made
    }
}

/// A line of overlapping curls across the rect, optionally cut off at `fraction` of the width.
/// The cut uses the same curl positions as the full line, so the filled part sits exactly on the
/// track behind it.
nonisolated struct CurlLine: Shape {
    var fraction: CGFloat = 1

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let d = rect.height
        guard d > 0, rect.width > 0 else { return Path() }
        // Neighbouring curls overlap by about a third, so the outline reads as one fluffy rope.
        let count = max(1, Int(((rect.width - d) / (d * 0.68)).rounded()) + 1)
        let pitch = count > 1 ? (rect.width - d) / CGFloat(count - 1) : 0
        var curls = Path()
        for i in 0..<count {
            curls.addEllipse(in: CGRect(x: rect.minX + CGFloat(i) * pitch, y: rect.minY, width: d, height: d))
        }
        let f = min(1, max(0, fraction))
        if f >= 1 { return curls }
        if f <= 0 { return Path() }
        return curls.intersection(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * f, height: d)))
    }
}

/// A ring of overlapping curls: the speed dial's puffy rim.
nonisolated struct PuffRing: Shape {
    var puffs = 18

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        // Each puff's radius, so neighbours overlap and the outer edge just touches the rect.
        let r = outer * sin(.pi / CGFloat(puffs)) * 1.25
        let ring = outer - r
        var p = Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2))
        for i in 0..<puffs {
            let a = CGFloat(i) / CGFloat(puffs) * 2 * .pi
            p.addEllipse(in: CGRect(x: c.x + ring * cos(a) - r, y: c.y + ring * sin(a) - r, width: r * 2, height: r * 2))
        }
        return p
    }
}

/// A read-only curl progress bar: the mini player's, and anywhere progress is shown big enough.
struct CurlProgressBar: View {
    var value: Double
    var height: CGFloat = 8
    var tint: Color = Palette.tomato
    var track: Color = Palette.blushDeep

    var body: some View {
        ZStack {
            CurlLine().fill(track)
            CurlLine(fraction: value).fill(tint)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(1, max(0, value)) * 100).rounded())) percent")
    }
}

// MARK: - Surfaces

extension View {
    /// A cloud card: cream fill with a scalloped edge, sitting on a solid copy of itself a couple
    /// of points lower. That offset copy is the "shadow": no blur and no offscreen pass, so a list
    /// of hundreds of these scrolls like plain rows.
    func cloudCard(fill: Color = Palette.card, cornerRadius: CGFloat = 22, scallop: CGFloat = 30, depth: CGFloat = 2,
                   lift: CGFloat = 2.5, edges: Edge.Set = .all) -> some View {
        background {
            let shape = CloudShape(cornerRadius: cornerRadius, scallop: scallop, depth: depth, edges: edges)
            ZStack {
                shape.fill(Palette.cardEdge).offset(y: lift)
                shape.fill(fill)
                shape.stroke(Palette.line, lineWidth: 0.75)
            }
        }
    }

    /// One soft blur shadow, for the handful of things that float (mini player, big play, primary
    /// buttons). Not for rows.
    func floatShadow(_ radius: CGFloat = 10, y: CGFloat = 6, opacity: Double = 0.18) -> some View {
        shadow(color: Palette.shadow.opacity(opacity), radius: radius, y: y)
    }
}
