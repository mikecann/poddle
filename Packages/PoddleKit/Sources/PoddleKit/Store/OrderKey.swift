import Foundation

/// Fractional order keys for the queue (spec §2.10): a reorder on one device and an add on another
/// both survive because each item only ever gets a key between its neighbours.
/// Keys are base-62 strings that sort with plain `<`, never empty and never ending in "0".
public enum OrderKey {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// A key strictly between `a` and `b`. Pass nil for an open end.
    public static func between(_ a: String?, _ b: String?) -> String {
        precondition(a == nil || b == nil || a! < b!, "OrderKey.between needs a < b")
        return midpoint(Array(a ?? ""), b.map(Array.init))
    }

    /// `count` evenly spread keys, handy for seeding a queue.
    public static func sequence(_ count: Int) -> [String] {
        var keys: [String] = []
        var last: String?
        for _ in 0..<count {
            let next = between(last, nil)
            keys.append(next)
            last = next
        }
        return keys
    }

    private static func index(_ c: Character) -> Int { digits.firstIndex(of: c)! }

    private static func midpoint(_ a: [Character], _ b: [Character]?) -> String {
        if let b {
            var n = 0
            while n < b.count, (n < a.count ? a[n] : "0") == b[n] { n += 1 }
            if n > 0 {
                return String(b[0..<n]) + midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n)))
            }
        }
        let digitA = a.first.map(index) ?? 0
        let digitB = b?.first.map(index) ?? digits.count
        if digitB - digitA > 1 {
            return String(digits[(digitA + digitB + 1) / 2])
        }
        if let b, b.count > 1 { return String(b[0]) }
        return String(digits[digitA]) + midpoint(Array(a.dropFirst()), nil)
    }
}
