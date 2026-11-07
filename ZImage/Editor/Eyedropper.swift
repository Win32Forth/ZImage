import CoreGraphics
import CoreImage
import Foundation

/// White or skin. The click always samples stage 3, after geometry and before tone.
nonisolated enum EyedropperMode: String, Equatable, Sendable {
    case white
    case skin
}

/// Stage-3 readback and the global grade it writes onto `ToneState`.
/// White balance is solved inside the slider parameterization the pipeline already uses:
/// `inputNeutral` stays (6500, 0) and `inputTargetNeutral` is the stored temperature and tint.
nonisolated enum Eyedropper {
    static let whiteSide = 11
    static let skinSide = 21
    /// RMS of a* and b* inside the white window. Above this, the history label says "varied sample".
    static let variedChromaRMS = 3.0
    static let temperatureRange = 2000.0...50000.0
    static let tintRange = -150.0...150.0

    struct GradeResult: Equatable {
        var tone: ToneState
        var label: String
    }

    static func whiteGrade(
        image: CIImage,
        bitmapPoint: CGPoint,
        context: CIContext,
        base: ToneState
    ) -> GradeResult {
        let samples = linearSamples(window(image, bitmapPoint: bitmapPoint, side: whiteSide), context: context)
        let mean = meanRGB(samples)
        let varied = chromaRMS(samples) > variedChromaRMS
        let balance = neutralize(mean, context: context)
        var tone = base
        tone.temperature = balance.temperature
        tone.tint = balance.tint
        let label = varied ? "\(EyedropperCopy.whiteHistory), \(EyedropperCopy.varied)" : EyedropperCopy.whiteHistory
        return GradeResult(tone: tone, label: label)
    }

    static func skinGrade(
        image: CIImage,
        bitmapPoint: CGPoint,
        preset: SkinPreset,
        context: CIContext,
        base: ToneState
    ) -> GradeResult {
        let samples = linearSamples(window(image, bitmapPoint: bitmapPoint, side: skinSide), context: context)
        let median = medianRGB(samples)
        let sample = lab(median)
        var tone = base
        tone.skinGrade = SkinGrade(
            presetID: preset.id,
            sample: sample,
            target: preset.lab,
            deltaA: preset.lab.a - sample.a,
            deltaB: preset.lab.b - sample.b
        )
        return GradeResult(tone: tone, label: preset.label)
    }

    /// Temperature and tint that bring `sample` closest to neutral through `TonePipeline`.
    static func neutralize(
        _ sample: (r: Double, g: Double, b: Double),
        context: CIContext
    ) -> (temperature: Double, tint: Double) {
        let patch = solid(sample.r, sample.g, sample.b, side: 1)
        func score(temperature: Double, tint: Double) -> Double {
            let temperature = min(temperatureRange.upperBound, max(temperatureRange.lowerBound, temperature))
            let tint = min(tintRange.upperBound, max(tintRange.lowerBound, tint))
            var tone = ToneState.identity
            tone.temperature = temperature
            tone.tint = tint
            let graded = TonePipeline.apply(base: patch, tone: tone, longEdge: 1)
            guard let pixel = linearSamples(graded, context: context).first else { return 1e9 }
            guard pixel.r.isFinite, pixel.g.isFinite, pixel.b.isFinite else { return 1e9 }
            guard pixel.r >= 0, pixel.g >= 0, pixel.b >= 0 else { return 1e6 }
            return chroma(pixel)
        }

        let temperatures = (0..<18).map { index -> Double in
            let t = Double(index) / 17
            return exp(log(temperatureRange.lowerBound) + t * (log(temperatureRange.upperBound) - log(temperatureRange.lowerBound)))
        }
        let tints = stride(from: tintRange.lowerBound, through: tintRange.upperBound, by: 25).map { $0 }
        var bestTemperature = 6500.0
        var bestTint = 0.0
        var best = score(temperature: bestTemperature, tint: bestTint)
        for temperature in temperatures {
            for tint in tints {
                let value = score(temperature: temperature, tint: tint)
                if value < best {
                    best = value
                    bestTemperature = temperature
                    bestTint = tint
                }
            }
        }

        var spanTemperature = bestTemperature * 0.18
        var spanTint = 30.0
        for _ in 0..<5 {
            guard best > 0.35 else { break }
            let lowT = max(temperatureRange.lowerBound, bestTemperature - spanTemperature)
            let highT = min(temperatureRange.upperBound, bestTemperature + spanTemperature)
            let lowG = max(tintRange.lowerBound, bestTint - spanTint)
            let highG = min(tintRange.upperBound, bestTint + spanTint)
            for i in 0..<7 {
                for j in 0..<7 {
                    let temperature = lowT + (highT - lowT) * Double(i) / 6
                    let tint = lowG + (highG - lowG) * Double(j) / 6
                    let value = score(temperature: temperature, tint: tint)
                    if value < best {
                        best = value
                        bestTemperature = temperature
                        bestTint = tint
                    }
                }
            }
            spanTemperature *= 0.45
            spanTint *= 0.45
        }
        return (bestTemperature, bestTint)
    }

    static func lab(_ rgb: (r: Double, g: Double, b: Double)) -> LabColor {
        let xyz = LinearDisplayP3.xyz(r: rgb.r, g: rgb.g, b: rgb.b)
        let lab = LinearDisplayP3.lab(x: xyz.x, y: xyz.y, z: xyz.z)
        return LabColor(L: lab.L, a: lab.a, b: lab.b)
    }

    static func chroma(_ rgb: (r: Double, g: Double, b: Double)) -> Double {
        let sample = lab(rgb)
        return hypot(sample.a, sample.b)
    }

    static func solid(_ r: Double, _ g: Double, _ b: Double, side: CGFloat) -> CIImage {
        var components = [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(1)]
        let color = CGColor(colorSpace: TonePipeline.workingColorSpace, components: &components)
            ?? CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
        return CIImage(color: CIColor(cgColor: color)).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// Bitmap point is top-left, y down, matching the canvas click. Core Image is y up.
    static func window(_ image: CIImage, bitmapPoint: CGPoint, side: Int) -> CIImage {
        let extent = image.extent
        let half = CGFloat(side) / 2
        let rect = CGRect(
            x: extent.minX + bitmapPoint.x - half,
            y: extent.maxY - bitmapPoint.y - half,
            width: CGFloat(side),
            height: CGFloat(side)
        )
        let clipped = rect.intersection(extent)
        if clipped.width < 1 || clipped.height < 1 {
            return image.cropped(to: CGRect(x: extent.minX, y: extent.minY, width: 1, height: 1))
        }
        return image.cropped(to: clipped)
    }

    static func linearSamples(_ image: CIImage, context: CIContext) -> [(r: Double, g: Double, b: Double)] {
        let extent = image.extent.integral
        let width = max(1, Int(extent.width))
        let height = max(1, Int(extent.height))
        var floats = [Float](repeating: 0, count: width * height * 4)
        floats.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(
                image,
                toBitmap: base,
                rowBytes: width * MemoryLayout<Float>.stride * 4,
                bounds: extent,
                format: .RGBAf,
                colorSpace: TonePipeline.workingColorSpace
            )
        }
        var pixels: [(r: Double, g: Double, b: Double)] = []
        pixels.reserveCapacity(width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            pixels.append((Double(floats[offset]), Double(floats[offset + 1]), Double(floats[offset + 2])))
        }
        return pixels
    }

    private static func meanRGB(_ samples: [(r: Double, g: Double, b: Double)]) -> (r: Double, g: Double, b: Double) {
        guard !samples.isEmpty else { return (0, 0, 0) }
        let scale = 1 / Double(samples.count)
        var r = 0.0
        var g = 0.0
        var b = 0.0
        for sample in samples {
            r += sample.r
            g += sample.g
            b += sample.b
        }
        return (r * scale, g * scale, b * scale)
    }

    private static func medianRGB(_ samples: [(r: Double, g: Double, b: Double)]) -> (r: Double, g: Double, b: Double) {
        guard !samples.isEmpty else { return (0, 0, 0) }
        func middle(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let mid = sorted.count / 2
            if sorted.count % 2 == 1 { return sorted[mid] }
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return (middle(samples.map(\.r)), middle(samples.map(\.g)), middle(samples.map(\.b)))
    }

    private static func chromaRMS(_ samples: [(r: Double, g: Double, b: Double)]) -> Double {
        guard samples.count > 1 else { return 0 }
        let labs = samples.map { lab($0) }
        let meanA = labs.reduce(0.0) { $0 + $1.a } / Double(labs.count)
        let meanB = labs.reduce(0.0) { $0 + $1.b } / Double(labs.count)
        let sum = labs.reduce(0.0) { partial, sample in
            let da = sample.a - meanA
            let db = sample.b - meanB
            return partial + da * da + db * db
        }
        return (sum / Double(labs.count)).squareRoot()
    }
}
