import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Mask source ids stored on `InpaintOp.modelID`.
/// `lama` is the fill model. `colorSelection` means the mask came from the Lab flood fill.
/// The LaMa weights are not in the repo. `advimman/lama` is Apache-2.0. A Core ML
/// conversion named `lama-big-coreml-v1.mlmodelc` can be added to the app bundle later.
/// Until that file is present, a click uses `StubInpainter` and export refuses the document.
nonisolated enum InpaintModel {
    static let lama = "lama-big-coreml-v1"
    static let colorSelection = "color-selection"
    static let dust = "touchup-dust-v1"
    static let scratch = "touchup-scratch-v1"
    static let bundledResource = "lama-big-coreml-v1"

    static func isTouchup(_ modelID: String) -> Bool {
        modelID == dust || modelID == scratch
    }

    /// Object removal still needs the LaMa file. Dust and scratch repair do not.
    static func needsLama(_ modelID: String) -> Bool {
        !isTouchup(modelID)
    }
}

nonisolated enum InpaintExportError: LocalizedError {
    case modelMissing

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "Object removal needs the LaMa model, and that model is not installed. Nothing was written."
        }
    }
}

/// Click selection, mask PNG, and the interactive or export fill.
/// Stage 3 runs after geometry and before tone. Masks are normalized to that image.
nonisolated enum InpaintPipeline {
    static let interactiveLongEdge = 1024
    static let exportLongEdge = 2048
    static let maskLongEdge = 1024
    static let visionLongEdge = 2048
    static let instanceCap = 16
    static let colorDeltaE: Double = 12
    static let colorPixelFraction = 0.25
    static let tileOverlap = 128
    static let minimumPad: CGFloat = 32
    static let padFraction: CGFloat = 0.5

    static func modelURL() -> URL? {
        let bundle = Bundle.main
        if let compiled = bundle.url(forResource: InpaintModel.bundledResource, withExtension: "mlmodelc") {
            return compiled
        }
        return bundle.url(forResource: InpaintModel.bundledResource, withExtension: "mlpackage")
    }

    /// Export refuses object removal when the LaMa file is absent. Dust and scratch repair export without it.
    static func validateForExport(_ state: EditState) throws {
        let needsModel = state.inpaints.contains { InpaintModel.needsLama($0.modelID) }
        if !needsModel { return }
        guard modelURL() != nil else { throw InpaintExportError.modelMissing }
    }

    static func select(image: CIImage, bitmapPoint: CGPoint, context: CIContext) -> InpaintOp {
        if let png = visionMask(image: image, bitmapPoint: bitmapPoint, context: context) {
            return InpaintOp(id: UUID(), maskPNG: png, modelID: InpaintModel.lama, featherPx: 8)
        }
        let png = colorMask(image: image, bitmapPoint: bitmapPoint, context: context)
        return InpaintOp(id: UUID(), maskPNG: png, modelID: InpaintModel.colorSelection, featherPx: 8)
    }

    /// Interactive fill. A missing model uses the stub. The stored command is still the mask, not the pixels.
    /// `imageToken` is the geometry and file under the masks. Tone is applied later and is not part of it.
    static func applyInteractive(base: CIImage, operations: [InpaintOp], imageToken: Int = 0) -> CIImage {
        var image = base
        var chain = imageToken
        for operation in operations where !operation.maskPNG.isEmpty {
            if InpaintModel.isTouchup(operation.modelID) {
                image = Touchup.apply(base: image, operation: operation, chain: chain)
            } else {
                image = StubInpainter.composite(base: image, maskPNG: operation.maskPNG, featherPx: operation.featherPx)
            }
            chain = Touchup.advance(chain, operation)
        }
        return image
    }

    /// Crop padded by the larger of 32 px and half the box, clipped to the image.
    static func paddedCrop(of bbox: CGRect, in extent: CGRect) -> CGRect {
        let padX = max(minimumPad, bbox.width * padFraction)
        let padY = max(minimumPad, bbox.height * padFraction)
        let raw = CGRect(
            x: bbox.minX - padX,
            y: bbox.minY - padY,
            width: bbox.width + padX * 2,
            height: bbox.height + padY * 2
        )
        return raw.intersection(extent)
    }

    /// Long edge of the model input. Never enlarges a crop that is already small enough.
    static func modelInputSize(crop: CGSize, maxEdge: Int) -> CGSize {
        let long = max(crop.width, crop.height)
        guard long > 0 else { return .zero }
        let scale = min(1, CGFloat(maxEdge) / long)
        return CGSize(width: max(1, floor(crop.width * scale)), height: max(1, floor(crop.height * scale)))
    }

    /// Export tiles. Each edge is at most `maxEdge`. Neighbors overlap by `overlap` when the crop is larger.
    static func tiles(covering size: CGSize, maxEdge: Int = exportLongEdge, overlap: Int = tileOverlap) -> [CGRect] {
        let edge = CGFloat(max(1, maxEdge))
        let step = max(1, edge - CGFloat(overlap))
        var rects: [CGRect] = []
        var y: CGFloat = 0
        while y < size.height {
            let height = min(edge, size.height - y)
            var x: CGFloat = 0
            while x < size.width {
                let width = min(edge, size.width - x)
                rects.append(CGRect(x: x, y: y, width: width, height: height))
                if x + width >= size.width { break }
                x += step
            }
            if y + height >= size.height { break }
            y += step
        }
        return rects
    }

    static func colorMask(image: CIImage, bitmapPoint: CGPoint, context: CIContext) -> Data {
        guard let raster = rasterize(image, context: context) else { return Data() }
        let width = raster.width
        let height = raster.height
        let x = min(max(0, Int(bitmapPoint.x)), width - 1)
        let y = min(max(0, Int(bitmapPoint.y)), height - 1)
        let seedRow = height - 1 - y
        let seed = lab(raster.samples, width: width, x: x, row: seedRow)
        var selected = [Bool](repeating: false, count: width * height)
        var queue: [(Int, Int)] = [(x, y)]
        var head = 0
        let cap = max(1, Int(Double(width * height) * colorPixelFraction))
        var count = 0
        while head < queue.count && count < cap {
            let point = queue[head]
            head += 1
            let index = point.1 * width + point.0
            if selected[index] { continue }
            let row = height - 1 - point.1
            let sample = lab(raster.samples, width: width, x: point.0, row: row)
            let delta = hypot(sample.L - seed.L, hypot(sample.a - seed.a, sample.b - seed.b))
            if count > 0 && delta > colorDeltaE { continue }
            selected[index] = true
            count += 1
            for dy in -1...1 {
                for dx in -1...1 {
                    if dx == 0 && dy == 0 { continue }
                    let nx = point.0 + dx
                    let ny = point.1 + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let next = ny * width + nx
                    if selected[next] { continue }
                    queue.append((nx, ny))
                }
            }
        }
        var gray = [UInt8](repeating: 0, count: width * height)
        for index in selected.indices where selected[index] {
            gray[index] = 255
        }
        let fitted = fitMask(gray, width: width, height: height, maxEdge: maskLongEdge)
        return encodeGrayPNG(fitted.pixels, width: fitted.width, height: fitted.height)
    }

    private static func visionMask(image: CIImage, bitmapPoint: CGPoint, context: CIContext) -> Data? {
        let scaled = scaledImage(image, maxLongEdge: CGFloat(visionLongEdge))
        let extent = scaled.extent.integral
        guard extent.width >= 1, extent.height >= 1,
              let cgImage = context.createCGImage(scaled, from: extent) else {
            return nil
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let buffer = observation.instanceMask
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let indexes = Array(observation.allInstances.prefix(instanceCap))
        guard !indexes.isEmpty else { return nil }
        let allowed = Set(indexes)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)

        func label(x: Int, y: Int) -> Int? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let row = base.advanced(by: y * bytesPerRow)
            switch format {
            case kCVPixelFormatType_OneComponent8:
                return Int(row.assumingMemoryBound(to: UInt8.self)[x])
            case kCVPixelFormatType_OneComponent16:
                return Int(row.assumingMemoryBound(to: UInt16.self)[x])
            case kCVPixelFormatType_OneComponent32Float:
                return Int(row.assumingMemoryBound(to: Float.self)[x].rounded())
            default:
                return nil
            }
        }

        let sourceWidth = image.extent.width
        let sourceHeight = image.extent.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let mx = min(width - 1, max(0, Int(bitmapPoint.x / sourceWidth * CGFloat(width))))
        let my = min(height - 1, max(0, Int(bitmapPoint.y / sourceHeight * CGFloat(height))))
        guard let hit = label(x: mx, y: my), allowed.contains(hit) else { return nil }

        var area: [Int: Int] = [:]
        for index in indexes { area[index] = 0 }
        for y in 0..<height {
            for x in 0..<width {
                guard let value = label(x: x, y: y), area[value] != nil else { continue }
                area[value, default: 0] += 1
            }
        }
        let chosen = hit
        var gray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                if label(x: x, y: y) == chosen {
                    gray[y * width + x] = 255
                }
            }
        }
        let fitted = fitMask(gray, width: width, height: height, maxEdge: maskLongEdge)
        let png = encodeGrayPNG(fitted.pixels, width: fitted.width, height: fitted.height)
        return png.isEmpty ? nil : png
    }

    private static func scaledImage(_ image: CIImage, maxLongEdge: CGFloat) -> CIImage {
        let long = max(image.extent.width, image.extent.height)
        guard long > maxLongEdge, long > 0 else { return image }
        let scale = maxLongEdge / long
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private struct Raster {
        var width: Int
        var height: Int
        var samples: [Float]
    }

    private static func rasterize(_ image: CIImage, context: CIContext) -> Raster? {
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        var samples = [Float](repeating: 0, count: width * height * 4)
        samples.withUnsafeMutableBytes { raw in
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
        return Raster(width: width, height: height, samples: samples)
    }

    private static func lab(_ samples: [Float], width: Int, x: Int, row: Int) -> LabColor {
        let offset = (row * width + x) * 4
        guard offset + 2 < samples.count else { return LabColor(L: 0, a: 0, b: 0) }
        return Eyedropper.lab((
            r: Double(samples[offset]),
            g: Double(samples[offset + 1]),
            b: Double(samples[offset + 2])
        ))
    }

    private static func fitMask(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        maxEdge: Int
    ) -> (pixels: [UInt8], width: Int, height: Int) {
        let long = max(width, height)
        guard long > maxEdge, width > 0, height > 0 else {
            return (pixels, width, height)
        }
        let scale = Double(maxEdge) / Double(long)
        let fittedWidth = max(1, Int((Double(width) * scale).rounded(.down)))
        let fittedHeight = max(1, Int((Double(height) * scale).rounded(.down)))
        var fitted = [UInt8](repeating: 0, count: fittedWidth * fittedHeight)
        for y in 0..<fittedHeight {
            for x in 0..<fittedWidth {
                let sourceX = min(width - 1, Int(Double(x) / scale))
                let sourceY = min(height - 1, Int(Double(y) / scale))
                fitted[y * fittedWidth + x] = pixels[sourceY * width + sourceX]
            }
        }
        return (fitted, fittedWidth, fittedHeight)
    }

    static func encodeGrayPNG(_ pixels: [UInt8], width: Int, height: Int) -> Data {
        guard width > 0, height > 0, pixels.count >= width * height else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return Data()
        }
        let space = CGColorSpaceCreateDeviceGray()
        let buffer = Data(pixels.prefix(width * height))
        guard let provider = CGDataProvider(data: buffer as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }
}

/// Blurred surround under the mask. Used when `lama-big-coreml-v1` is not in the bundle.
nonisolated enum StubInpainter {
    static func composite(base: CIImage, maskPNG: Data, featherPx: Int) -> CIImage {
        let extent = base.extent
        guard extent.width >= 1, extent.height >= 1,
              let maskImage = CIImage(data: maskPNG) else {
            return base
        }
        let scaleX = extent.width / max(maskImage.extent.width, 1)
        let scaleY = extent.height / max(maskImage.extent.height, 1)
        var mask = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)).cropped(to: extent)
        if featherPx > 0 {
            mask = mask.clampedToExtent().applyingGaussianBlur(sigma: Double(featherPx)).cropped(to: extent)
        }
        let blurred = base.clampedToExtent().applyingGaussianBlur(sigma: 12).cropped(to: extent)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return base }
        filter.setValue(blurred, forKey: kCIInputImageKey)
        filter.setValue(base, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        return (filter.outputImage ?? base).cropped(to: extent)
    }
}
