import CoreGraphics
import Foundation

/// The three Spectrum handles. Low is the shadow point, middle is the midtone, high is the highlight point.
nonisolated enum SpectrumHandle: Equatable, Sendable {
    case low
    case mid
    case high
}

/// Preview-style levels. Handles live in display tone, 0 black through 1 white.
/// The middle handle is the input tone that becomes middle gray.
nonisolated enum SpectrumLevels {
    /// Closest two handles may come. Keeps the gamma finite.
    static let gap = 0.02

    static func label(_ handle: SpectrumHandle) -> String {
        switch handle {
        case .low: return "Shadows"
        case .mid: return "Midtones"
        case .high: return "Highlights"
        }
    }

    static func isIdentity(low: Double, mid: Double, high: Double) -> Bool {
        low <= 0.0005 && high >= 0.9995 && abs(mid - 0.5) <= 0.0005
    }

    /// Moves one handle and leaves the others where they are.
    static func moving(
        _ handle: SpectrumHandle,
        to value: Double,
        low: Double,
        mid: Double,
        high: Double
    ) -> (low: Double, mid: Double, high: Double) {
        switch handle {
        case .low:
            return (min(max(0, value), mid - gap), mid, high)
        case .mid:
            return (low, min(max(low + gap, value), high - gap), high)
        case .high:
            return (low, mid, min(max(mid + gap, value), 1))
        }
    }

    /// Puts one handle back. Low returns to black, high to white, and middle to the center of the other two.
    static func reset(
        _ handle: SpectrumHandle,
        low: Double,
        mid: Double,
        high: Double
    ) -> (low: Double, mid: Double, high: Double) {
        switch handle {
        case .low:
            return moving(.low, to: 0, low: low, mid: mid, high: high)
        case .mid:
            return moving(.mid, to: (low + high) / 2, low: low, mid: mid, high: high)
        case .high:
            return moving(.high, to: 1, low: low, mid: mid, high: high)
        }
    }

    /// Exponent applied after the black and white points. 1 leaves the midtones alone.
    static func gamma(low: Double, mid: Double, high: Double) -> Double {
        let span = high - low
        guard span > 0.0001 else { return 1 }
        let placed = min(0.95, max(0.05, (mid - low) / span))
        if abs(placed - 0.5) <= 0.0005 { return 1 }
        return min(6, max(0.15, log(0.5) / log(placed)))
    }

    /// Five strictly increasing samples of a straight ramp from the shadow point to the highlight point.
    static func stretchPoints(black: Double, white: Double) -> [(x: Double, y: Double)] {
        let black = min(max(black, 0), 1)
        let white = min(max(white, black + gap), 1)
        func y(_ x: Double) -> Double {
            if x <= black { return 0 }
            if x >= white { return 1 }
            return (x - black) / (white - black)
        }
        var xs: [Double] = []
        for value in [0.0, black, (black + white) / 2, white, 1.0] {
            let x = min(1, max(0, value))
            if let last = xs.last, x <= last + 0.004 { continue }
            xs.append(x)
        }
        if xs.first != 0 { xs.insert(0, at: 0) }
        if xs.last != 1 { xs.append(1) }
        while xs.count < 5 {
            var widest = 0
            var span = -1.0
            for index in 0..<(xs.count - 1) {
                let gap = xs[index + 1] - xs[index]
                if gap > span {
                    span = gap
                    widest = index
                }
            }
            xs.insert((xs[widest] + xs[widest + 1]) / 2, at: widest + 1)
        }
        return xs.prefix(5).map { (x: $0, y: y($0)) }
    }

    /// 256 bins of display luminance. `rgba` is packed sRGB.
    static func bins(rgba: [UInt8]) -> [Int] {
        var bins = [Int](repeating: 0, count: 256)
        var index = 0
        while index + 3 < rgba.count {
            if rgba[index + 3] > 0 {
                let luma = (54 * Int(rgba[index]) + 183 * Int(rgba[index + 1]) + 19 * Int(rgba[index + 2])) >> 8
                bins[min(255, luma)] += 1
            }
            index += 4
        }
        return bins
    }

    /// The handle under the pointer, when the pointer is within the drag pad.
    static func nearest(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        axisY: CGFloat,
        low: Double,
        mid: Double,
        high: Double
    ) -> SpectrumHandle? {
        guard width > 1 else { return nil }
        let handles: [(SpectrumHandle, Double)] = [(.low, low), (.mid, mid), (.high, high)]
        var best: SpectrumHandle?
        var bestDistance = CGFloat(20)
        for (handle, position) in handles {
            let distance = hypot(x - CGFloat(position) * width, y - axisY)
            if distance < bestDistance {
                bestDistance = distance
                best = handle
            }
        }
        return best
    }
}
