import CoreGraphics
import CoreImage
import Foundation

/// Slider position to the Core Image input measured on this Mac.
/// Contrast, saturation, and highlight amount are not 0 at identity.
nonisolated enum ToneMaps {
    static func contrastInput(_ slider: Double) -> Double {
        if slider >= 0 {
            return 1 + 3 * slider
        }
        return 1 + 0.75 * slider
    }

    static func highlightAmount(_ slider: Double) -> Double {
        if slider >= 0 {
            return 1
        }
        return 1 + 0.7 * slider
    }

    static func saturationInput(_ slider: Double) -> Double {
        1 + slider
    }

    /// Point 1 of the shared tone curve. Identity is `(0.25, 0.25)`.
    static func blacksY(_ blacks: Double) -> Double {
        min(0.5, max(0, 0.25 + 0.25 * blacks))
    }

    /// Point 3 of the shared tone curve. Identity is `(0.75, 0.75)`.
    static func whitesY(_ whites: Double) -> Double {
        min(1, max(0.5, 0.75 + 0.25 * whites))
    }

    /// `coefficient × longEdge / 2560`. Sharpness uses 1, texture 1.5, clarity 30, dehaze 32.
    static func scaledRadius(longEdge: Double, coefficient: Double) -> Double {
        coefficient * longEdge / 2560
    }
}

/// Linear Display P3 ↔ CIE L\*a\*b\* under the D65 white of that primary matrix.
/// The skin cube is built from these. A nil `skinGrade` never calls them.
nonisolated enum LinearDisplayP3 {
    static func xyz(r: Double, g: Double, b: Double) -> (x: Double, y: Double, z: Double) {
        let x = 0.4865709486482162 * r + 0.26566769316909306 * g + 0.1982172852343625 * b
        let y = 0.2289745640697488 * r + 0.6917385218365064 * g + 0.079286914093745 * b
        let z = 0.04511338185890264 * g + 1.043944368900976 * b
        return (x, y, z)
    }

    /// XYZ of linear (1, 1, 1), so that white round-trips through Lab.
    static let white = xyz(r: 1, g: 1, b: 1)

    static func lab(x: Double, y: Double, z: Double) -> (L: Double, a: Double, b: Double) {
        let fx = pivot(x / white.x)
        let fy = pivot(y / white.y)
        let fz = pivot(z / white.z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func p3(L: Double, a: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let fy = (L + 16) / 116
        let fx = fy + a / 500
        let fz = fy - b / 200
        let x = white.x * inversePivot(fx)
        let y = white.y * inversePivot(fy)
        let z = white.z * inversePivot(fz)
        let r = 2.493496911941425 * x - 0.9313836179191239 * y - 0.40271078445071684 * z
        let g = -0.8294889695615747 * x + 1.7626640603183463 * y + 0.023624685841943577 * z
        let b = 0.03584583024378447 * x - 0.07617238926804182 * y + 0.9568845240076872 * z
        return (r, g, b)
    }

    private static func pivot(_ t: Double) -> Double {
        let epsilon = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        if t > epsilon { return cbrt(t) }
        return (kappa * t + 16) / 116
    }

    private static func inversePivot(_ t: Double) -> Double {
        let delta = 6.0 / 29.0
        if t > delta { return t * t * t }
        return 3 * delta * delta * (t - 4.0 / 29.0)
    }
}

/// Records the input region the dehaze kernel actually receives.
/// The ROI callback returns the output tile, so this stays the tile rather than the whole frame.
enum DehazeTileTrace {
    nonisolated(unsafe) static var inputPixelCounts: [Int] = []

    static func reset() {
        inputPixelCounts = []
    }

    static func record(inputRegion: CGRect) {
        let pixels = Int(inputRegion.width.rounded()) * Int(inputRegion.height.rounded())
        inputPixelCounts.append(pixels)
    }
}

/// Subtracts `dehaze × veil` inside the output tile. The ROI is that tile.
/// Dehaze 0 copies the input. The kernel does not allocate a frame-sized buffer.
final class DehazeKernel: CIImageProcessorKernel {
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        outputRect
    }

    override class var outputFormat: CIFormat { .RGBAh }

    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

    override class var synchronizeInputs: Bool { true }

    override class func process(
        with inputs: [CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: CIImageProcessorOutput
    ) throws {
        guard let inputs, inputs.count >= 2 else { return }
        let color = inputs[0]
        let veil = inputs[1]
        DehazeTileTrace.record(inputRegion: color.region)
        DehazeTileTrace.record(inputRegion: veil.region)
        guard color.format == .RGBAh, veil.format == .RGBAh, output.format == .RGBAh else { return }

        let amount = (arguments?["dehaze"] as? NSNumber)?.floatValue ?? 0
        let outWidth = Int(output.region.width.rounded())
        let outHeight = Int(output.region.height.rounded())
        guard outWidth > 0, outHeight > 0 else { return }

        let colorX = Int((output.region.minX - color.region.minX).rounded())
        let colorY = Int((output.region.minY - color.region.minY).rounded())
        let veilX = Int((output.region.minX - veil.region.minX).rounded())
        let veilY = Int((output.region.minY - veil.region.minY).rounded())
        let colorWidth = Int(color.region.width.rounded())
        let colorHeight = Int(color.region.height.rounded())
        let veilWidth = Int(veil.region.width.rounded())
        let veilHeight = Int(veil.region.height.rounded())

        for y in 0..<outHeight {
            let outRow = output.baseAddress.advanced(by: y * output.bytesPerRow)
            for x in 0..<outWidth {
                let destination = outRow.advanced(by: x * 8).assumingMemoryBound(to: Float16.self)
                let sample = pixel(
                    color.baseAddress,
                    bytesPerRow: color.bytesPerRow,
                    x: colorX + x,
                    y: colorY + y,
                    width: colorWidth,
                    height: colorHeight
                )
                if amount == 0 {
                    destination[0] = sample.r
                    destination[1] = sample.g
                    destination[2] = sample.b
                    destination[3] = sample.a
                    continue
                }
                let haze = pixel(
                    veil.baseAddress,
                    bytesPerRow: veil.bytesPerRow,
                    x: veilX + x,
                    y: veilY + y,
                    width: veilWidth,
                    height: veilHeight
                )
                let veilValue = max(Float(haze.r), max(Float(haze.g), Float(haze.b)))
                destination[0] = Float16(max(0, Float(sample.r) - amount * veilValue))
                destination[1] = Float16(max(0, Float(sample.g) - amount * veilValue))
                destination[2] = Float16(max(0, Float(sample.b) - amount * veilValue))
                destination[3] = sample.a
            }
        }
    }

    private static func pixel(
        _ base: UnsafeRawPointer,
        bytesPerRow: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> (r: Float16, g: Float16, b: Float16, a: Float16) {
        guard x >= 0, y >= 0, x < width, y < height else {
            return (0, 0, 0, 1)
        }
        let row = base.advanced(by: y * bytesPerRow)
        let px = row.advanced(by: x * 8).assumingMemoryBound(to: Float16.self)
        return (px[0], px[1], px[2], px[3])
    }
}

/// Stage 4 of the fixed render order: exposure, highlight/shadow, tone curve,
/// color controls, vibrance, temperature and tint, texture, clarity, dehaze, skin cube.
/// Identity controls are omitted. The context working format is `CIFormat.RGBAh`
/// and the working color space is extended linear Display P3.
nonisolated enum TonePipeline {
    static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    static func makeContext() -> CIContext {
        CIContext(options: [
            .workingColorSpace: workingColorSpace,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
    }

    static func apply(base: CIImage, tone: ToneState, longEdge: CGFloat) -> CIImage {
        let extent = base.extent
        var image = base
        if tone.exposureEV != 0 {
            image = applying("CIExposureAdjust", to: image, extent: extent, parameters: [
                "inputEV": tone.exposureEV,
            ])
        }
        if tone.shadows != 0 || ToneMaps.highlightAmount(tone.highlights) != 1 {
            image = applying("CIHighlightShadowAdjust", to: image, extent: extent, parameters: [
                "inputHighlightAmount": ToneMaps.highlightAmount(tone.highlights),
                "inputShadowAmount": tone.shadows,
                "inputRadius": 0.0,
            ])
        }
        if tone.whites != 0 || tone.blacks != 0 {
            image = applying("CIToneCurve", to: image, extent: extent, parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: ToneMaps.blacksY(tone.blacks)),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: ToneMaps.whitesY(tone.whites)),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
        }
        let contrast = ToneMaps.contrastInput(tone.contrast)
        let saturation = ToneMaps.saturationInput(tone.saturation)
        if tone.brightness != 0 || contrast != 1 || saturation != 1 {
            image = applying("CIColorControls", to: image, extent: extent, parameters: [
                "inputBrightness": tone.brightness,
                "inputContrast": contrast,
                "inputSaturation": saturation,
            ])
        }
        if tone.vibrance != 0 {
            image = applying("CIVibrance", to: image, extent: extent, parameters: [
                "inputAmount": tone.vibrance,
            ])
        }
        if tone.temperature != 6500 || tone.tint != 0 {
            image = applying("CITemperatureAndTint", to: image, extent: extent, parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: tone.temperature, y: tone.tint),
            ])
        }
        let edge = Double(longEdge)
        image = detail(
            image,
            amount: tone.texture,
            radius: ToneMaps.scaledRadius(longEdge: edge, coefficient: 1.5),
            extent: extent
        )
        image = detail(
            image,
            amount: tone.clarity,
            radius: ToneMaps.scaledRadius(longEdge: edge, coefficient: 30),
            extent: extent
        )
        if tone.dehaze > 0 {
            image = dehaze(image, amount: tone.dehaze, longEdge: edge, extent: extent)
        }
        if let grade = tone.skinGrade {
            image = skinCube(image, grade: grade, extent: extent)
        }
        return image.cropped(to: extent)
    }

    static func rgba8(of image: CIImage, context: CIContext) -> [UInt8] {
        let extent = image.extent.integral
        let width = max(1, Int(extent.width))
        let height = max(1, Int(extent.height))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            image,
            toBitmap: &bytes,
            rowBytes: width * 4,
            bounds: extent,
            format: .RGBA8,
            colorSpace: workingColorSpace
        )
        return bytes
    }

    private static func applying(
        _ name: String,
        to image: CIImage,
        extent: CGRect,
        parameters: [String: Any]
    ) -> CIImage {
        guard let filter = CIFilter(name: name) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        for (key, value) in parameters {
            filter.setValue(value, forKey: key)
        }
        guard let output = filter.outputImage else { return image }
        return output.cropped(to: extent)
    }

    /// Positive amount is an unsharp mask. Negative amount mixes in a blur.
    /// Zero omits the filter. `radius` is the coefficient already scaled by long edge.
    /// Geometry sharpness uses this with coefficient 1. Texture uses 1.5 and clarity 30.
    static func detail(_ image: CIImage, amount: Double, radius: Double, extent: CGRect) -> CIImage {
        if amount == 0 || radius <= 0 { return image }
        if amount > 0 {
            return applying("CIUnsharpMask", to: image, extent: extent, parameters: [
                "inputIntensity": amount,
                "inputRadius": radius,
            ])
        }
        let t = abs(amount)
        let blurred = applying("CIGaussianBlur", to: image, extent: extent, parameters: [
            "inputRadius": radius * t,
        ])
        return applying("CIDissolveTransition", to: image, extent: extent, parameters: [
            "inputTargetImage": blurred,
            "inputTime": t,
        ])
    }

    /// Veil is the blurred per-pixel minimum of R, G, and B. Radius is `32 × longEdge / 2560`.
    /// The subtract runs in `DehazeKernel`, whose ROI is the output tile.
    private static func dehaze(_ image: CIImage, amount: Double, longEdge: Double, extent: CGRect) -> CIImage {
        let radius = ToneMaps.scaledRadius(longEdge: longEdge, coefficient: 32)
        let minimum = applying("CIMinimumComponent", to: image, extent: extent, parameters: [:])
        let veil = applying("CIGaussianBlur", to: minimum, extent: extent, parameters: [
            "inputRadius": radius,
        ])
        guard let output = try? DehazeKernel.apply(
            withExtent: extent,
            inputs: [image, veil],
            arguments: ["dehaze": amount]
        ) else {
            return image
        }
        return output.cropped(to: extent)
    }

    /// 32³ cube shifting a\* and b\* by the grade deltas. The cube is not stored.
    private static func skinCube(_ image: CIImage, grade: SkinGrade, extent: CGRect) -> CIImage {
        let dimension = 32
        var samples = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        var index = 0
        let last = Double(dimension - 1)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let linear = LinearDisplayP3.xyz(
                        r: Double(red) / last,
                        g: Double(green) / last,
                        b: Double(blue) / last
                    )
                    let (L, a, b) = LinearDisplayP3.lab(x: linear.x, y: linear.y, z: linear.z)
                    let shifted = LinearDisplayP3.p3(L: L, a: a + grade.deltaA, b: b + grade.deltaB)
                    samples[index] = Float(min(1, max(0, shifted.r)))
                    samples[index + 1] = Float(min(1, max(0, shifted.g)))
                    samples[index + 2] = Float(min(1, max(0, shifted.b)))
                    samples[index + 3] = 1
                    index += 4
                }
            }
        }
        let data = samples.withUnsafeBytes { Data($0) }
        return applying("CIColorCube", to: image, extent: extent, parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data,
        ])
    }
}

nonisolated struct ToneRenderer: EditRendering {
    func render(base: CIImage, state: EditState, purpose: RenderPurpose) throws -> CIImage {
        let longEdge: CGFloat
        switch purpose {
        case .proxy(let edge), .visibleTile(let edge):
            longEdge = CGFloat(edge)
        case .exportTile:
            longEdge = max(base.extent.width, base.extent.height)
        }
        return TonePipeline.apply(base: base, tone: state.tone, longEdge: longEdge)
    }
}
