import Foundation

/// A second-order IIR section (transposed direct form II), RBJ cookbook designs.
struct Biquad: Sendable {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1 = 0.0, z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    private static func normalised(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Biquad {
        Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func highPass(frequency: Double, q: Double = 0.7071, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q), c = cos(w)
        return normalised((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q), c = cos(w)
        return normalised(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
    }

    /// ITU-R BS.1770 K-weighting stage 1 (high shelf), designed for any sample rate.
    static func kWeightingShelf(sampleRate: Double) -> Biquad {
        let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(
            b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }

    /// ITU-R BS.1770 K-weighting stage 2 (RLB high-pass), designed for any sample rate.
    static func kWeightingHighPass(sampleRate: Double) -> Biquad {
        let f0 = 38.13547087602444, q = 0.5003270373238773
        let k = tan(Double.pi * f0 / sampleRate)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }
}

@inline(__always) func dbToGain(_ db: Double) -> Double { pow(10, db / 20) }
@inline(__always) func powerToDB(_ p: Double) -> Double { 10 * log10(max(p, 1e-20)) }
