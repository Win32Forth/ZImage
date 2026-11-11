import CoreGraphics
import CoreImage
import Foundation

/// A compiled lens row. Choosing one copies its coefficients into `LensSetting`.
nonisolated struct LensProfile: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var k1: Double
    var k2: Double
    var cylindricalFOV: Double?

    var setting: LensSetting {
        LensSetting(profileID: id, k1: k1, k2: k2, cylindricalFOV: cylindricalFOV)
    }
}

extension CornerPin {
    /// The source frame. Pins at these positions leave the perspective stage off.
    static let unit = CornerPin(
        topLeft: NormPoint(x: 0, y: 0),
        topRight: NormPoint(x: 1, y: 0),
        bottomRight: NormPoint(x: 1, y: 1),
        bottomLeft: NormPoint(x: 0, y: 1)
    )
}

/// Stage 2 of the fixed render order: lens, perspective, quarter-turns, straighten, then sharpness.
/// Identity geometry returns the base image unchanged.
nonisolated enum GeometryPipeline {
    /// Keystone strength. `1` moves the top-left corner to `(-1/6, -1/6)`.
    static let keystoneGain = 0.5

    static let profiles: [LensProfile] = [
        LensProfile(id: "none", name: "None", k1: 0, k2: 0, cylindricalFOV: nil),
        LensProfile(id: "superwide-mild", name: "Super-wide adapter, mild", k1: -0.15, k2: 0.05, cylindricalFOV: nil),
        LensProfile(id: "superwide-strong", name: "Super-wide adapter, strong", k1: -0.28, k2: 0.12, cylindricalFOV: nil),
        LensProfile(id: "pano-120", name: "Panoramic adapter, 120°", k1: 0, k2: 0, cylindricalFOV: 120),
        LensProfile(id: "pano-180", name: "Panoramic adapter, 180°", k1: 0, k2: 0, cylindricalFOV: 180),
    ]

    static func profile(id: String) -> LensProfile? {
        profiles.first { $0.id == id }
    }

    static func apply(base: CIImage, geometry: GeometryState) -> CIImage {
        guard geometry != .identity else { return base }
        var image = base
        if hasTransform(geometry) {
            image = lens(base, geometry.lens)
            image = perspective(image, geometry)
            image = rotate(image, quarterTurns: geometry.quarterTurns)
            image = straighten(image, degrees: geometry.straightenDegrees)
            image = finite(image)
        }
        let edge = max(image.extent.width, image.extent.height)
        return sharpen(image, amount: geometry.sharpness, longEdge: edge)
    }

    /// Fine unsharp mask. Radius is `1 × longEdge / 2560`. Zero leaves the image.
    static func sharpen(_ image: CIImage, amount: Double, longEdge: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return image }
        return TonePipeline.detail(
            image,
            amount: amount,
            radius: ToneMaps.scaledRadius(longEdge: Double(max(longEdge, 1)), coefficient: 1),
            extent: extent
        )
    }

    private static func hasTransform(_ geometry: GeometryState) -> Bool {
        geometry.quarterTurns != 0
            || abs(geometry.straightenDegrees) > 1e-6
            || geometry.verticalKeystone != 0
            || geometry.horizontalKeystone != 0
            || geometry.corners != nil
            || geometry.lens != .identity
    }

    /// Normalized point, origin top-left, y down. The center stays at `(0.5, 0.5)`.
    /// `X' = X / (1 + kY + hX)` with `k = 0.5 × vertical` and `h = 0.5 × horizontal`.
    static func keystonePoint(_ point: NormPoint, vertical: Double, horizontal: Double) -> NormPoint {
        let x = point.x - 0.5
        let y = point.y - 0.5
        let k = keystoneGain * vertical
        let h = keystoneGain * horizontal
        let weight = 1 + k * y + h * x
        guard abs(weight) > 1e-6 else { return point }
        return NormPoint(x: 0.5 + x / weight, y: 0.5 + y / weight)
    }

    /// Quarter-turn delta (clockwise positive) and straighten delta, in degrees.
    /// A line steeper than 45° takes one quarter-turn toward upright, then the residual.
    /// The clicks are normalized. `pixelWidth` and `pixelHeight` are the picture on
    /// screen, so the run is measured in those pixels. Equal sides leave the angle unchanged.
    static func horizonDelta(
        from start: NormPoint,
        to end: NormPoint,
        pixelWidth: Double = 1,
        pixelHeight: Double = 1
    ) -> (quarterTurns: Int, straightenDegrees: Double) {
        let width = pixelWidth > 0 ? pixelWidth : 1
        let height = pixelHeight > 0 ? pixelHeight : 1
        let dx = (end.x - start.x) * width
        let dy = (end.y - start.y) * height
        guard dx != 0 || dy != 0 else { return (0, 0) }
        var tilt = atan2(dy, dx) * 180 / .pi
        while tilt > 90 { tilt -= 180 }
        while tilt <= -90 { tilt += 180 }
        // The bitmap angle and `CIStraightenFilter` share a sign: writing the
        // measured tilt back cancels it. A tilt past ±45° takes one quarter-turn.
        var needed = tilt
        var turns = 0
        if needed > 45 {
            turns = 1
            needed -= 90
        } else if needed < -45 {
            turns = -1
            needed += 90
        }
        return (turns, min(45, max(-45, needed)))
    }

    static func applyingHorizon(
        from start: NormPoint,
        to end: NormPoint,
        pixelWidth: Double = 1,
        pixelHeight: Double = 1,
        current: GeometryState
    ) -> GeometryState {
        let delta = horizonDelta(from: start, to: end, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        var next = current
        next.quarterTurns = wrap(current.quarterTurns + delta.quarterTurns)
        next.straightenDegrees = min(45, max(-45, current.straightenDegrees + delta.straightenDegrees))
        return next
    }

    static func wrap(_ turns: Int) -> Int {
        let remainder = turns % 4
        return remainder >= 0 ? remainder : remainder + 4
    }

    private static func lens(_ image: CIImage, _ setting: LensSetting) -> CIImage {
        let fov = setting.cylindricalFOV ?? 0
        guard setting.k1 != 0 || setting.k2 != 0 || fov > 0 else { return image }
        let extent = image.extent.integral
        guard extent.width >= 1, extent.height >= 1 else { return image }
        let arguments: [String: Any] = [
            "k1": setting.k1,
            "k2": setting.k2,
            "fov": fov,
            "fullWidth": Double(extent.width),
            "fullHeight": Double(extent.height),
        ]
        guard let output = try? LensKernel.apply(withExtent: extent, inputs: [image], arguments: arguments) else {
            return image
        }
        return output.cropped(to: extent)
    }

    private static func perspective(_ image: CIImage, _ geometry: GeometryState) -> CIImage {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return image }
        let pins = destinationPins(geometry)
        guard let pins, !isUnit(pins) else { return image }
        let width = extent.width
        let height = extent.height
        func vector(_ point: NormPoint) -> CIVector {
            CIVector(
                x: extent.minX + point.x * width,
                y: extent.minY + (1 - point.y) * height
            )
        }
        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(vector(pins.topLeft), forKey: "inputTopLeft")
        filter.setValue(vector(pins.topRight), forKey: "inputTopRight")
        filter.setValue(vector(pins.bottomRight), forKey: "inputBottomRight")
        filter.setValue(vector(pins.bottomLeft), forKey: "inputBottomLeft")
        guard let output = filter.outputImage else { return image }
        return finite(output)
    }

    private static func destinationPins(_ geometry: GeometryState) -> CornerPin? {
        if let corners = geometry.corners {
            return corners
        }
        guard geometry.verticalKeystone != 0 || geometry.horizontalKeystone != 0 else { return nil }
        let vertical = geometry.verticalKeystone
        let horizontal = geometry.horizontalKeystone
        return CornerPin(
            topLeft: keystonePoint(NormPoint(x: 0, y: 0), vertical: vertical, horizontal: horizontal),
            topRight: keystonePoint(NormPoint(x: 1, y: 0), vertical: vertical, horizontal: horizontal),
            bottomRight: keystonePoint(NormPoint(x: 1, y: 1), vertical: vertical, horizontal: horizontal),
            bottomLeft: keystonePoint(NormPoint(x: 0, y: 1), vertical: vertical, horizontal: horizontal)
        )
    }

    private static func isUnit(_ pins: CornerPin) -> Bool {
        func near(_ point: NormPoint, _ x: Double, _ y: Double) -> Bool {
            abs(point.x - x) < 1e-4 && abs(point.y - y) < 1e-4
        }
        return near(pins.topLeft, 0, 0)
            && near(pins.topRight, 1, 0)
            && near(pins.bottomRight, 1, 1)
            && near(pins.bottomLeft, 0, 1)
    }

    private static func rotate(_ image: CIImage, quarterTurns: Int) -> CIImage {
        let turns = wrap(quarterTurns)
        guard turns != 0 else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return image }
        let angle = -CGFloat.pi / 2 * CGFloat(turns)
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: -center.x, y: -center.y)
        return finite(image.transformed(by: transform))
    }

    private static func straighten(_ image: CIImage, degrees: Double) -> CIImage {
        guard abs(degrees) > 1e-6 else { return image }
        let clamped = min(45, max(-45, degrees))
        guard let filter = CIFilter(name: "CIStraightenFilter") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(clamped * .pi / 180, forKey: kCIInputAngleKey)
        guard let output = filter.outputImage else { return image }
        return finite(output)
    }

    private static func finite(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.isInfinite == false, extent.isNull == false, extent.width >= 1, extent.height >= 1 else {
            return image
        }
        let box = extent.integral
        guard box.width >= 1, box.height >= 1 else { return image }
        let shifted = image.transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
        return shifted.cropped(to: CGRect(x: 0, y: 0, width: box.width, height: box.height))
    }
}

/// Brown–Conrady, then a cylindrical x remap. Samples land in the output tile.
final class LensKernel: CIImageProcessorKernel {
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        func number(_ key: String) -> Double? {
            if let value = arguments?[key] as? Double { return value }
            if let value = arguments?[key] as? NSNumber { return value.doubleValue }
            return nil
        }
        guard let width = number("fullWidth"), let height = number("fullHeight") else {
            return outputRect
        }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { true }

    override class func process(
        with inputs: [CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: CIImageProcessorOutput
    ) throws {
        guard let source = inputs?.first,
              source.format == .RGBAh,
              output.format == .RGBAh,
              let arguments else { return }
        func argument(_ key: String, fallback: Double) -> Double {
            if let value = arguments[key] as? Double { return value }
            if let value = arguments[key] as? NSNumber { return value.doubleValue }
            return fallback
        }
        let k1 = argument("k1", fallback: 0)
        let k2 = argument("k2", fallback: 0)
        let fov = argument("fov", fallback: 0)
        let fullWidth = argument("fullWidth", fallback: Double(output.region.width))
        let fullHeight = argument("fullHeight", fallback: Double(output.region.height))
        let outWidth = Int(output.region.width.rounded())
        let outHeight = Int(output.region.height.rounded())
        let sourceWidth = Int(source.region.width.rounded())
        let sourceHeight = Int(source.region.height.rounded())
        guard outWidth > 0, outHeight > 0, fullWidth > 1, fullHeight > 1 else { return }
        let scale = max(fullWidth, fullHeight) / 2
        let halfFOV = min(max(fov, 0) * .pi / 180 / 2, .pi / 2)

        for y in 0..<outHeight {
            let outRow = output.baseAddress.advanced(by: y * output.bytesPerRow)
            let gy = Double(output.region.minY) + Double(y) + 0.5
            for x in 0..<outWidth {
                let destination = outRow.advanced(by: x * 8).assumingMemoryBound(to: Float16.self)
                let gx = Double(output.region.minX) + Double(x) + 0.5
                var nx = (gx - fullWidth / 2) / scale
                let ny = (gy - fullHeight / 2) / scale
                if halfFOV > 0.01 {
                    let xEdge = (gx - fullWidth / 2) / (fullWidth / 2)
                    let theta = min(max(xEdge, -1), 1) * halfFOV
                    // sin(theta)/tan(half) over sin(half)/tan(half) cancels to sin(theta)/sin(half).
                    let srcEdge = sin(theta) / sin(halfFOV)
                    nx = srcEdge * (fullWidth / 2) / scale
                }
                let radius2 = nx * nx + ny * ny
                let factor = 1 + k1 * radius2 + k2 * radius2 * radius2
                let sampleX = fullWidth / 2 + nx * factor * scale
                let sampleY = fullHeight / 2 + ny * factor * scale
                let localX = sampleX - Double(source.region.minX)
                let localY = sampleY - Double(source.region.minY)
                let sample = bilinear(
                    source.baseAddress,
                    bytesPerRow: source.bytesPerRow,
                    x: localX,
                    y: localY,
                    width: sourceWidth,
                    height: sourceHeight
                )
                destination[0] = sample.0
                destination[1] = sample.1
                destination[2] = sample.2
                destination[3] = sample.3
            }
        }
    }

    private static func bilinear(
        _ base: UnsafeRawPointer,
        bytesPerRow: Int,
        x: Double,
        y: Double,
        width: Int,
        height: Int
    ) -> (Float16, Float16, Float16, Float16) {
        guard x >= 0, y >= 0, x < Double(width - 1), y < Double(height - 1) else {
            return (0, 0, 0, 0)
        }
        let x0 = Int(x)
        let y0 = Int(y)
        let tx = Float(x - Double(x0))
        let ty = Float(y - Double(y0))
        let p00 = pixel(base, bytesPerRow: bytesPerRow, x: x0, y: y0)
        let p10 = pixel(base, bytesPerRow: bytesPerRow, x: x0 + 1, y: y0)
        let p01 = pixel(base, bytesPerRow: bytesPerRow, x: x0, y: y0 + 1)
        let p11 = pixel(base, bytesPerRow: bytesPerRow, x: x0 + 1, y: y0 + 1)
        func mix(_ a: Float16, _ b: Float16, _ c: Float16, _ d: Float16) -> Float16 {
            let ab = Float(a) + (Float(b) - Float(a)) * tx
            let cd = Float(c) + (Float(d) - Float(c)) * tx
            return Float16(ab + (cd - ab) * ty)
        }
        return (mix(p00.0, p10.0, p01.0, p11.0), mix(p00.1, p10.1, p01.1, p11.1), mix(p00.2, p10.2, p01.2, p11.2), mix(p00.3, p10.3, p01.3, p11.3))
    }

    private static func pixel(
        _ base: UnsafeRawPointer,
        bytesPerRow: Int,
        x: Int,
        y: Int
    ) -> (Float16, Float16, Float16, Float16) {
        let row = base.advanced(by: y * bytesPerRow)
        let px = row.advanced(by: x * 8).assumingMemoryBound(to: Float16.self)
        return (px[0], px[1], px[2], px[3])
    }
}
