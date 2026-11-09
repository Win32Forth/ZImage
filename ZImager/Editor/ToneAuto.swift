import Foundation

/// Sets the six basic tone sliders from a photograph's luminance.
/// Texture, clarity, dehaze, color, and the other sliders stay as they are.
nonisolated enum ToneAuto {
    struct Levels: Equatable, Sendable {
        var black: Double
        var shadow: Double
        var mid: Double
        var highlight: Double
        var white: Double
    }

    /// Percentiles of perceptual luminance. `rgba` is tightly packed sRGB, 4 bytes a pixel.
    static func levels(rgba: [UInt8]) -> Levels? {
        guard rgba.count >= 8, rgba.count.isMultiple(of: 4) else { return nil }
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        var index = 0
        while index + 3 < rgba.count {
            let alpha = rgba[index + 3]
            if alpha > 0 {
                let luma = (54 * Int(rgba[index]) + 183 * Int(rgba[index + 1]) + 19 * Int(rgba[index + 2])) >> 8
                histogram[min(255, luma)] += 1
                total += 1
            }
            index += 4
        }
        guard total >= 32 else { return nil }
        return Levels(
            black: percentile(0.005, histogram: histogram, total: total),
            shadow: percentile(0.15, histogram: histogram, total: total),
            mid: percentile(0.50, histogram: histogram, total: total),
            highlight: percentile(0.85, histogram: histogram, total: total),
            white: percentile(0.995, histogram: histogram, total: total)
        )
    }

    /// Replaces Exposure, Contrast, Highlights, Shadows, Whites, and Blacks.
    static func applying(_ levels: Levels, to tone: ToneState) -> ToneState {
        var next = tone
        next.exposureEV = clamp(exposure(mid: levels.mid), -1.5, 1.5)
        next.contrast = clamp(contrast(black: levels.black, white: levels.white), -0.45, 0.5)
        next.highlights = clamp(highlights(white: levels.white), -0.8, 0)
        next.shadows = clamp(shadows(black: levels.black, shadow: levels.shadow), 0, 0.55)
        next.whites = clamp(whites(white: levels.white), -0.2, 0.7)
        next.blacks = clamp(blacks(black: levels.black, white: levels.white, shadow: levels.shadow), -0.75, 0.15)
        return next
    }

    private static func percentile(_ p: Double, histogram: [Int], total: Int) -> Double {
        let target = max(1, Int((Double(total) * p).rounded(.up)))
        var seen = 0
        for bin in 0..<256 {
            seen += histogram[bin]
            if seen >= target { return Double(bin) / 255 }
        }
        return 1
    }

    /// Stops toward a mid gray of 0.45. The value is photographic exposure, so it uses linear light.
    private static func exposure(mid: Double) -> Double {
        let target = linear(0.45)
        let current = max(linear(mid), 0.002)
        return log2(target / current)
    }

    private static func contrast(black: Double, white: Double) -> Double {
        let span = white - black
        if span < 0.55 { return min(0.45, (0.75 - span) * 0.8) }
        if span > 0.92 { return max(-0.35, (0.92 - span) * 1.5) }
        return 0
    }

    /// Highlight recovery only. A positive Highlights slider does not change the picture.
    private static func highlights(white: Double) -> Double {
        guard white >= 0.985 else { return 0 }
        return -(white - 0.96) * 10
    }

    private static func shadows(black: Double, shadow: Double) -> Double {
        guard shadow < 0.16, black < 0.04 else { return 0 }
        return (0.18 - shadow) * 2
    }

    private static func whites(white: Double) -> Double {
        if white < 0.90 { return (0.97 - white) * 2 }
        if white >= 0.995 { return -0.15 }
        return 0
    }

    private static func blacks(black: Double, white: Double, shadow: Double) -> Double {
        if black > 0.06, white > black + 0.4 { return -(black - 0.02) * 4 }
        if black < 0.005, shadow < 0.06 { return 0.12 }
        return 0
    }

    private static func linear(_ encoded: Double) -> Double {
        let c = min(1, max(0, encoded))
        if c <= 0.04045 { return c / 12.92 }
        return pow((c + 0.055) / 1.055, 2.4)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }
}
