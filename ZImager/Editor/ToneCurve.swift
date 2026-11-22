import CoreGraphics
import CoreImage
import Foundation

/// One handle on a tone curve. x is the incoming display tone. y is the outgoing tone.
nonisolated struct CurvePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

/// Which curve the graph is editing. RGB runs first. Red, green, and blue run after it.
nonisolated enum CurveChannel: String, CaseIterable, Identifiable, Sendable {
    case rgb
    case red
    case green
    case blue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rgb: return "RGB"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }

    var historyLabel: String {
        switch self {
        case .rgb: return "Curve"
        case .red: return "Red curve"
        case .green: return "Green curve"
        case .blue: return "Blue curve"
        }
    }

    func curve(in curves: ToneCurves) -> ToneCurve {
        switch self {
        case .rgb: return curves.master
        case .red: return curves.red
        case .green: return curves.green
        case .blue: return curves.blue
        }
    }

    func write(_ curve: ToneCurve, into curves: inout ToneCurves) {
        switch self {
        case .rgb: curves.master = curve
        case .red: curves.red = curve
        case .green: curves.green = curve
        case .blue: curves.blue = curve
        }
    }
}

/// A smooth curve through a handful of handles. The ends stay at black and white.
/// Interior handles stay between their neighbors. Eight handles is the limit.
nonisolated struct ToneCurve: Codable, Equatable, Sendable {
    static let maxPoints = 8
    static let gap = 0.02

    var points: [CurvePoint]

    static let linear = ToneCurve(points: [
        CurvePoint(x: 0, y: 0),
        CurvePoint(x: 1, y: 1),
    ])

    init(points: [CurvePoint]) {
        self.points = Self.sanitized(points)
    }

    var isLinear: Bool {
        points.allSatisfy { abs($0.y - $0.x) <= 0.0001 }
    }

    /// Display tone out for a display tone in. Values outside 0...1 follow the end slope.
    func evaluate(_ x: Double) -> Double {
        guard points.count >= 2, let first = points.first, let last = points.last else { return x }
        let slopes = Self.tangents(points)
        if x <= first.x {
            return first.y + slopes[0] * (x - first.x)
        }
        if x >= last.x {
            return last.y + slopes[slopes.count - 1] * (x - last.x)
        }
        var segment = 0
        for index in 0..<(points.count - 1) where x >= points[index].x && x <= points[index + 1].x {
            segment = index
            break
        }
        let left = points[segment]
        let right = points[segment + 1]
        let span = right.x - left.x
        guard span > 1e-8 else { return left.y }
        let t = (x - left.x) / span
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * left.y + h10 * span * slopes[segment] + h01 * right.y + h11 * span * slopes[segment + 1]
    }

    /// Moves one handle. The ends keep x at 0 and 1. An interior handle cannot pass its neighbors.
    func moving(index: Int, x: Double, y: Double) -> ToneCurve {
        guard points.indices.contains(index) else { return self }
        var next = points
        let y = min(1, max(0, y))
        if index == 0 {
            next[0] = CurvePoint(x: 0, y: y)
        } else if index == points.count - 1 {
            next[index] = CurvePoint(x: 1, y: y)
        } else {
            let left = points[index - 1].x + Self.gap
            let right = points[index + 1].x - Self.gap
            next[index] = CurvePoint(x: min(max(left, x), right), y: y)
        }
        return ToneCurve(points: next)
    }

    /// Puts an end handle back on the diagonal. A middle handle is left where it is.
    func resettingEndpoint(_ index: Int) -> ToneCurve {
        guard index == 0 || index == points.count - 1 else { return self }
        return moving(index: index, x: index == 0 ? 0 : 1, y: index == 0 ? 0 : 1)
    }

    /// Adds a handle on the curve. Nil when the curve is full or the spot is already a handle.
    func inserting(x: Double) -> (curve: ToneCurve, index: Int)? {
        guard points.count < Self.maxPoints else { return nil }
        let x = min(1 - Self.gap, max(Self.gap, x))
        if points.contains(where: { abs($0.x - x) < Self.gap }) { return nil }
        let y = min(1, max(0, evaluate(x)))
        var next = points
        next.append(CurvePoint(x: x, y: y))
        let curve = ToneCurve(points: next)
        guard let index = curve.points.firstIndex(where: { abs($0.x - x) < 0.0001 }) else { return nil }
        return (curve, index)
    }

    /// Drops a middle handle. The ends stay.
    func removing(index: Int) -> ToneCurve {
        guard index > 0, index < points.count - 1 else { return self }
        var next = points
        next.remove(at: index)
        return ToneCurve(points: next)
    }

    private enum CodingKeys: String, CodingKey {
        case points
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([CurvePoint].self, forKey: .points) ?? []
        points = Self.sanitized(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }

    /// Sorts, pins the ends, and keeps at most `maxPoints` handles.
    static func sanitized(_ raw: [CurvePoint]) -> [CurvePoint] {
        var kept: [CurvePoint] = []
        for point in raw.sorted(by: { $0.x < $1.x }) {
            let clamped = CurvePoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
            if let last = kept.last, clamped.x - last.x < gap * 0.5 { continue }
            kept.append(clamped)
        }
        if kept.first?.x != 0 {
            kept.insert(CurvePoint(x: 0, y: kept.first?.y ?? 0), at: 0)
        } else if !kept.isEmpty {
            kept[0].x = 0
        }
        if kept.last?.x != 1 {
            kept.append(CurvePoint(x: 1, y: kept.last?.y ?? 1))
        } else if !kept.isEmpty {
            kept[kept.count - 1].x = 1
        }
        while kept.count > maxPoints {
            var drop = 1
            var closest = Double.greatestFiniteMagnitude
            for index in 1..<(kept.count - 1) {
                let spacing = kept[index].x - kept[index - 1].x
                if spacing < closest {
                    closest = spacing
                    drop = index
                }
            }
            kept.remove(at: drop)
        }
        if kept.count < 2 {
            return [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        }
        return kept
    }

    /// Fritsch–Carlson tangents. A monotone run of handles stays monotone.
    static func tangents(_ points: [CurvePoint]) -> [Double] {
        let count = points.count
        guard count >= 2 else { return [] }
        var delta = [Double](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let span = points[index + 1].x - points[index].x
            delta[index] = span > 1e-8 ? (points[index + 1].y - points[index].y) / span : 0
        }
        var slope = [Double](repeating: 0, count: count)
        slope[0] = delta[0]
        slope[count - 1] = delta[count - 2]
        if count > 2 {
            for index in 1..<(count - 1) {
                if delta[index - 1] * delta[index] <= 0 {
                    slope[index] = 0
                } else {
                    slope[index] = (delta[index - 1] + delta[index]) / 2
                }
            }
        }
        for index in 0..<(count - 1) {
            if abs(delta[index]) <= 1e-8 {
                slope[index] = 0
                slope[index + 1] = 0
                continue
            }
            let a = slope[index] / delta[index]
            let b = slope[index + 1] / delta[index]
            let magnitude = a * a + b * b
            if magnitude > 9 {
                let scale = 3 / magnitude.squareRoot()
                slope[index] = scale * a * delta[index]
                slope[index + 1] = scale * b * delta[index]
            }
        }
        return slope
    }
}

/// The four curves stored on a tone record. Missing data decodes as the diagonal.
nonisolated struct ToneCurves: Codable, Equatable, Sendable {
    var master: ToneCurve = .linear
    var red: ToneCurve = .linear
    var green: ToneCurve = .linear
    var blue: ToneCurve = .linear

    static let identity = ToneCurves()

    var isIdentity: Bool {
        master.isLinear && red.isLinear && green.isLinear && blue.isLinear
    }
}

/// Looks for the RGB curve. Choosing one clears the red, green, and blue curves.
nonisolated enum CurvePreset: String, CaseIterable, Identifiable, Sendable {
    case linear
    case matte
    case filmMoody
    case punch
    case loFi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: return "Linear"
        case .matte: return "Matte"
        case .filmMoody: return "Film Moody"
        case .punch: return "Punch"
        case .loFi: return "Lo-fi"
        }
    }

    var help: String {
        switch self {
        case .linear:
            return "Clears the curve."
        case .matte:
            return "Lifts the shadows and softens the highlights."
        case .filmMoody:
            return "A soft S-curve with the ends brought in a little."
        case .punch:
            return "A stronger S-curve. Black and white stay put."
        case .loFi:
            return "Lifts the black and lowers the white."
        }
    }

    var curve: ToneCurve {
        switch self {
        case .linear:
            return .linear
        case .matte:
            return ToneCurve(points: [
                CurvePoint(x: 0, y: 0.09),
                CurvePoint(x: 0.22, y: 0.26),
                CurvePoint(x: 0.50, y: 0.50),
                CurvePoint(x: 0.78, y: 0.72),
                CurvePoint(x: 1, y: 0.88),
            ])
        case .filmMoody:
            return ToneCurve(points: [
                CurvePoint(x: 0, y: 0.04),
                CurvePoint(x: 0.20, y: 0.14),
                CurvePoint(x: 0.48, y: 0.46),
                CurvePoint(x: 0.76, y: 0.80),
                CurvePoint(x: 1, y: 0.93),
            ])
        case .punch:
            return ToneCurve(points: [
                CurvePoint(x: 0, y: 0),
                CurvePoint(x: 0.22, y: 0.12),
                CurvePoint(x: 0.50, y: 0.50),
                CurvePoint(x: 0.78, y: 0.88),
                CurvePoint(x: 1, y: 1),
            ])
        case .loFi:
            return ToneCurve(points: [
                CurvePoint(x: 0, y: 0.14),
                CurvePoint(x: 0.28, y: 0.32),
                CurvePoint(x: 0.55, y: 0.55),
                CurvePoint(x: 0.80, y: 0.74),
                CurvePoint(x: 1, y: 0.84),
            ])
        }
    }

    func matches(_ curves: ToneCurves) -> Bool {
        curves.master == curve && curves.red == .linear && curves.green == .linear && curves.blue == .linear
    }
}

/// 256 bins of display tone for the curve graph.
nonisolated struct CurveHistogram: Equatable, Sendable {
    var luma: [Int]
    var red: [Int]
    var green: [Int]
    var blue: [Int]

    static let empty = CurveHistogram(luma: [], red: [], green: [], blue: [])

    func bins(for channel: CurveChannel) -> [Int] {
        switch channel {
        case .rgb: return luma
        case .red: return red
        case .green: return green
        case .blue: return blue
        }
    }

    /// Packed sRGB. Clear pixels are skipped. Luma uses the same weights as Spectrum.
    static func make(rgba: [UInt8]) -> CurveHistogram {
        var luma = [Int](repeating: 0, count: 256)
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        var index = 0
        while index + 3 < rgba.count {
            if rgba[index + 3] > 0 {
                let r = Int(rgba[index])
                let g = Int(rgba[index + 1])
                let b = Int(rgba[index + 2])
                red[r] += 1
                green[g] += 1
                blue[b] += 1
                luma[min(255, (54 * r + 183 * g + 19 * b) >> 8)] += 1
            }
            index += 4
        }
        return CurveHistogram(luma: luma, red: red, green: green, blue: blue)
    }
}

/// 256 samples of RGB after the master curve, plus the slope past each end.
nonisolated struct CurveLookup: Sendable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var lowR: Float
    var lowG: Float
    var lowB: Float
    var highR: Float
    var highG: Float
    var highB: Float

    init(_ curves: ToneCurves) {
        red = Self.table(master: curves.master, channel: curves.red)
        green = Self.table(master: curves.master, channel: curves.green)
        blue = Self.table(master: curves.master, channel: curves.blue)
        lowR = Self.slope(master: curves.master, channel: curves.red, at: 0, delta: 1 / 255)
        lowG = Self.slope(master: curves.master, channel: curves.green, at: 0, delta: 1 / 255)
        lowB = Self.slope(master: curves.master, channel: curves.blue, at: 0, delta: 1 / 255)
        highR = Self.slope(master: curves.master, channel: curves.red, at: 1, delta: -1 / 255)
        highG = Self.slope(master: curves.master, channel: curves.green, at: 1, delta: -1 / 255)
        highB = Self.slope(master: curves.master, channel: curves.blue, at: 1, delta: -1 / 255)
    }

    var arguments: [String: Any] {
        [
            "lowR": Double(lowR),
            "lowG": Double(lowG),
            "lowB": Double(lowB),
            "highR": Double(highR),
            "highG": Double(highG),
            "highB": Double(highB),
        ]
    }

    /// One row. Red, green, and blue of each pixel are the three lookups.
    func image() -> CIImage {
        var pixels = [Float16](repeating: 0, count: 256 * 4)
        for index in 0..<256 {
            pixels[index * 4] = Float16(red[index])
            pixels[index * 4 + 1] = Float16(green[index])
            pixels[index * 4 + 2] = Float16(blue[index])
            pixels[index * 4 + 3] = 1
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(
            bitmapData: data,
            bytesPerRow: 256 * MemoryLayout<Float16>.stride * 4,
            size: CGSize(width: 256, height: 1),
            format: .RGBAh,
            colorSpace: TonePipeline.workingColorSpace
        )
    }

    private static func table(master: ToneCurve, channel: ToneCurve) -> [Float] {
        (0..<256).map { index in
            let x = Double(index) / 255
            return Float(channel.evaluate(master.evaluate(x)))
        }
    }

    private static func slope(master: ToneCurve, channel: ToneCurve, at x: Double, delta: Double) -> Float {
        let y0 = channel.evaluate(master.evaluate(x))
        let y1 = channel.evaluate(master.evaluate(x + delta))
        guard abs(delta) > 1e-8 else { return 1 }
        return Float((y1 - y0) / delta)
    }
}
