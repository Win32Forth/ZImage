import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Dust and scratch repair. The mask is stored on the history step. The pixels are rebuilt
/// from the surrounding photo, then mixed by `InpaintOp.strength`.
struct TouchupBuilt: Sendable {
    var operation: InpaintOp
    var pixels: [Float]
}

/// One finished repair, including the picture to put on screen. Built off the main thread.
struct TouchupJobResult: Sendable {
    var built: TouchupBuilt?
    var repaired: CIImage?
    var preview: CGImage?
    var spectrum: [Int]
    var folderJPEG: Data?
    var width: Int
    var height: Int
}

/// Work for one Touchup button or stroke. Run it off the main actor.
nonisolated enum TouchupWork: Sendable {
    case dust
    case scratches
    case spot(CGPoint, Int)
    case scratch([CGPoint], Int)

    var isSpot: Bool {
        if case .spot = self { return true }
        return false
    }
}

/// One repair waiting its turn. Spot clicks stack here so the next click does not wait on the current repair.
nonisolated struct QueuedTouchup: Sendable {
    var banner: String
    var empty: String
    var work: TouchupWork
}

/// Outstanding Dust, Scratches, Spot, and Scratch repairs. The running job counts toward `cap`.
nonisolated struct TouchupQueue: Sendable {
    static let cap = 64

    private(set) var waiting: [QueuedTouchup] = []
    private(set) var running: QueuedTouchup?

    var count: Int { waiting.count + (running == nil ? 0 : 1) }

    /// Spot clicks not yet finished, including the one running.
    var spotsRemaining: Int {
        var total = 0
        if let running, running.work.isSpot { total += 1 }
        for job in waiting where job.work.isSpot { total += 1 }
        return total
    }

    /// Starts `job` when the list is idle. Otherwise appends it. False when `cap` is already full.
    mutating func add(_ job: QueuedTouchup) -> Bool {
        guard count < Self.cap else { return false }
        if running == nil {
            running = job
        } else {
            waiting.append(job)
        }
        return true
    }

    /// Drops the running job and promotes the next one. Nil when the list is empty.
    mutating func finishRunning() -> QueuedTouchup? {
        if waiting.isEmpty {
            running = nil
            return nil
        }
        running = waiting.removeFirst()
        return running
    }

    mutating func removeAll() {
        waiting.removeAll()
        running = nil
    }
}

nonisolated enum Touchup {
    private static let context = TonePipeline.makeContext()
    /// Serial so the job context is never used from two threads. Low priority so the pointer stays live.
    private static let jobQueue = DispatchQueue(label: "com.Win32Forth.ZImager.touchup", qos: .userInitiated)
    private static let jobContext: CIContext = {
        CIContext(options: [
            .workingColorSpace: TonePipeline.workingColorSpace,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .priorityRequestLow: true,
        ])
    }()

    static func perform(_ work: TouchupWork, samples: [Float], width: Int, height: Int) -> TouchupBuilt? {
        switch work {
        case .dust:
            return dust(samples: samples, width: width, height: height)
        case .scratches:
            return scratches(samples: samples, width: width, height: height)
        case .spot(let point, let radius):
            return spot(samples: samples, width: width, height: height, bitmapPoint: point, radius: radius)
        case .scratch(let points, let radius):
            return markedScratch(samples: samples, width: width, height: height, points: points, radius: radius)
        }
    }

    /// Renders the working image, repairs it, and builds the on-screen picture away from the main thread.
    /// `priorOperations` are repairs already in the log. They are applied here when the caller does not already have that picture.
    static func finishOffMain(
        image: CIImage,
        work: TouchupWork,
        tone: ToneState,
        displaySpaceName: String,
        priorOperations: [InpaintOp] = [],
        priorToken: Int = 0
    ) async -> TouchupJobResult {
        await withCheckedContinuation { continuation in
            jobQueue.async {
                continuation.resume(returning: finish(
                    image: image,
                    work: work,
                    tone: tone,
                    displaySpaceName: displaySpaceName,
                    priorOperations: priorOperations,
                    priorToken: priorToken
                ))
            }
        }
    }

    private static func finish(
        image: CIImage,
        work: TouchupWork,
        tone: ToneState,
        displaySpaceName: String,
        priorOperations: [InpaintOp],
        priorToken: Int
    ) -> TouchupJobResult {
        let source = priorOperations.isEmpty
            ? image
            : InpaintPipeline.applyInteractive(
                base: image,
                operations: priorOperations,
                imageToken: priorToken,
                context: jobContext
            )
        guard let raster = read(source, context: jobContext) else {
            return TouchupJobResult(
                built: nil, repaired: nil, preview: nil, spectrum: [], folderJPEG: nil, width: 0, height: 0
            )
        }
        guard let built = perform(work, samples: raster.samples, width: raster.width, height: raster.height) else {
            return TouchupJobResult(
                built: nil, repaired: nil, preview: nil, spectrum: [], folderJPEG: nil,
                width: raster.width, height: raster.height
            )
        }
        let repaired = ciImage(built.pixels, width: raster.width, height: raster.height, extent: raster.extent)
        let preview = displayImage(repaired, tone: tone, displaySpaceName: displaySpaceName)
        let spectrum = histogram(shaped: repaired, tone: tone)
        let folderJPEG = preview.flatMap { ZImgRaw.jpegPreview(from: $0, maxLongEdge: FolderPreviewCache.maxLongEdge) }
        return TouchupJobResult(
            built: built,
            repaired: repaired,
            preview: preview,
            spectrum: spectrum,
            folderJPEG: folderJPEG,
            width: raster.width,
            height: raster.height
        )
    }

    private static func displayImage(_ shaped: CIImage, tone: ToneState, displaySpaceName: String) -> CGImage? {
        let longEdge = max(shaped.extent.width, shaped.extent.height)
        let toned = TonePipeline.apply(base: shaped, tone: tone, longEdge: longEdge)
        let extent = toned.extent.integral
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let space = CGColorSpace(name: displaySpaceName as CFString) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return jobContext.createCGImage(toned, from: extent, format: .RGBA8, colorSpace: space)
    }

    /// Same graph the inspector draws: the photograph before the Spectrum handles, scaled to a long edge of 160.
    private static func histogram(shaped: CIImage, tone: ToneState) -> [Int] {
        let extent = shaped.extent
        let longSide = max(extent.width, extent.height)
        guard longSide.isFinite, longSide > 1 else { return [] }
        var plain = tone
        plain.spectrumLow = 0
        plain.spectrumMid = 0.5
        plain.spectrumHigh = 1
        let scale = min(1, 160 / longSide)
        let small = shaped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let toned = TonePipeline.apply(
            base: small,
            tone: plain,
            longEdge: max(small.extent.width, small.extent.height)
        )
        let bounds = toned.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width >= 2, height >= 2 else { return [] }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        jobContext.render(
            toned,
            toBitmap: &bytes,
            rowBytes: width * 4,
            bounds: bounds,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        )
        return SpectrumLevels.bins(rgba: bytes)
    }

    /// Identity of the photo under the repair. Tone is not included. The cache is in memory only.
    static func imageToken(path: String, geometry: GeometryState, crop: NormRect?) -> Int {
        struct Stamp: Encodable {
            var path: String
            var geometry: GeometryState
            var crop: NormRect?
        }
        let data = (try? JSONEncoder().encode(Stamp(path: path, geometry: geometry, crop: crop))) ?? Data()
        return fnv(data)
    }

    /// Cache identity of the image a repair was built from. It includes earlier masks, not this repair's strength.
    static func chain(imageToken: Int, operations: [InpaintOp]) -> Int {
        var chain = imageToken
        for operation in operations where !operation.maskPNG.isEmpty {
            chain = advance(chain, operation)
        }
        return chain
    }

    static func advance(_ chain: Int, _ operation: InpaintOp) -> Int {
        var hash = (chain ^ operation.id.hashValue) &* 1_099_511_628_211
        let strength = Int((min(1, max(0, operation.strength)) * 10_000).rounded())
        hash = (hash ^ strength) &* 1_099_511_628_211
        hash = (hash ^ fnv(operation.maskPNG)) &* 1_099_511_628_211
        return hash
    }

    static func read(_ image: CIImage) -> (samples: [Float], width: Int, height: Int, extent: CGRect)? {
        read(image, context: context)
    }

    static func read(
        _ image: CIImage,
        context: CIContext
    ) -> (samples: [Float], width: Int, height: Int, extent: CGRect)? {
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 1, height > 1 else { return nil }
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
        return (samples, width, height, extent)
    }

    static func ciImage(_ samples: [Float], width: Int, height: Int, extent: CGRect) -> CIImage {
        let data = samples.withUnsafeBytes { Data($0) }
        let image = CIImage(
            bitmapData: data,
            bytesPerRow: width * MemoryLayout<Float>.stride * 4,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: TonePipeline.workingColorSpace
        )
        return image.transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
    }

    static func resetCache() {
        TouchupCache.shared.reset()
    }

    static func store(chain: Int, width: Int, height: Int, maskPNG: Data, modelID: String, image: CIImage) {
        TouchupCache.shared.store(
            TouchupCache.Key(
                chain: chain,
                width: width,
                height: height,
                maskHash: fnv(maskPNG),
                modelID: modelID
            ),
            image
        )
    }

    static func dust(samples: [Float], width: Int, height: Int) -> TouchupBuilt? {
        guard let mask = TouchupEngine.dustMask(samples: samples, width: width, height: height) else { return nil }
        return built(mask: mask, samples: samples, width: width, height: height, modelID: InpaintModel.dust)
    }

    static func scratches(samples: [Float], width: Int, height: Int) -> TouchupBuilt? {
        guard let mask = TouchupEngine.scratchMask(samples: samples, width: width, height: height) else { return nil }
        return built(mask: mask, samples: samples, width: width, height: height, modelID: InpaintModel.scratch)
    }

    /// `bitmapPoint` is top-left, the same space as an object-removal click.
    /// `radius` is the circle, in raster pixels, that limits the search.
    /// The fill runs on a window around that circle. Pixels outside the window stay as they were.
    static func spot(
        samples: [Float],
        width: Int,
        height: Int,
        bitmapPoint: CGPoint,
        radius: Int = 12
    ) -> TouchupBuilt? {
        let window = spotWindow(width: width, height: height, bitmapPoint: bitmapPoint, radius: radius)
        let mask: [UInt8]
        let pixels: [Float]
        if window.width == width && window.height == height {
            guard let found = TouchupEngine.spotMask(
                samples: samples,
                width: width,
                height: height,
                bitmapPoint: bitmapPoint,
                radius: radius
            ) else { return nil }
            mask = found
            pixels = TouchupEngine.repair(
                samples: samples, mask: found, width: width, height: height, scratch: false
            )
        } else {
            let localSamples = cropSamples(samples, width: width, window: window)
            let localPoint = CGPoint(
                x: bitmapPoint.x - CGFloat(window.minX),
                y: bitmapPoint.y - CGFloat(window.minY)
            )
            guard let localMask = TouchupEngine.spotMask(
                samples: localSamples,
                width: window.width,
                height: window.height,
                bitmapPoint: localPoint,
                radius: radius
            ) else { return nil }
            let localPixels = TouchupEngine.repair(
                samples: localSamples,
                mask: localMask,
                width: window.width,
                height: window.height,
                scratch: false
            )
            mask = pasteMask(localMask, width: width, height: height, window: window)
            pixels = pastePixels(localPixels, into: samples, width: width, window: window)
        }
        let png = TouchupEngine.maskPNG(mask, width: width, height: height)
        guard !png.isEmpty else { return nil }
        return TouchupBuilt(
            operation: InpaintOp(id: UUID(), maskPNG: png, modelID: InpaintModel.dust, featherPx: 2),
            pixels: pixels
        )
    }

    /// Donor search reaches 30 px, and the blurs add a few more. The outer ring of the click is included too.
    private struct SpotWindow {
        var minX: Int
        var minY: Int
        var width: Int
        var height: Int
    }

    private static func spotWindow(width: Int, height: Int, bitmapPoint: CGPoint, radius: Int) -> SpotWindow {
        let radius = max(1, radius)
        let margin = 40 + max(6, radius / 5)
        let centerX = Int(bitmapPoint.x.rounded(.down))
        let centerY = Int(bitmapPoint.y.rounded(.down))
        let minX = max(0, centerX - radius - margin)
        let maxX = min(width - 1, centerX + radius + margin)
        let minY = max(0, centerY - radius - margin)
        let maxY = min(height - 1, centerY + radius + margin)
        return SpotWindow(minX: minX, minY: minY, width: max(1, maxX - minX + 1), height: max(1, maxY - minY + 1))
    }

    private static func cropSamples(_ samples: [Float], width: Int, window: SpotWindow) -> [Float] {
        var local = [Float](repeating: 0, count: window.width * window.height * 4)
        samples.withUnsafeBufferPointer { source in
            local.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
                let rowCount = window.width * 4
                for row in 0..<window.height {
                    let src = ((window.minY + row) * width + window.minX) * 4
                    destinationBase.advanced(by: row * rowCount).update(from: sourceBase.advanced(by: src), count: rowCount)
                }
            }
        }
        return local
    }

    private static func pasteMask(_ local: [UInt8], width: Int, height: Int, window: SpotWindow) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: width * height)
        for row in 0..<window.height {
            let src = row * window.width
            let dst = (window.minY + row) * width + window.minX
            mask.replaceSubrange(dst..<(dst + window.width), with: local[src..<(src + window.width)])
        }
        return mask
    }

    private static func pastePixels(_ local: [Float], into samples: [Float], width: Int, window: SpotWindow) -> [Float] {
        var pixels = samples
        let rowCount = window.width * 4
        local.withUnsafeBufferPointer { source in
            pixels.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
                for row in 0..<window.height {
                    let dst = ((window.minY + row) * width + window.minX) * 4
                    destinationBase.advanced(by: dst).update(
                        from: sourceBase.advanced(by: row * rowCount),
                        count: rowCount
                    )
                }
            }
        }
        return pixels
    }

    static func markedScratch(
        samples: [Float],
        width: Int,
        height: Int,
        from: CGPoint,
        to: CGPoint,
        radius: Int = 8
    ) -> TouchupBuilt? {
        markedScratch(samples: samples, width: width, height: height, points: [from, to], radius: radius)
    }

    /// `points` are top-left. `radius` is how far to either side of the stroke the search may look.
    static func markedScratch(
        samples: [Float],
        width: Int,
        height: Int,
        points: [CGPoint],
        radius: Int = 8
    ) -> TouchupBuilt? {
        guard let mask = TouchupEngine.markedScratchMask(
            samples: samples,
            width: width,
            height: height,
            points: points,
            radius: radius
        ) else { return nil }
        return built(mask: mask, samples: samples, width: width, height: height, modelID: InpaintModel.scratch)
    }

    /// Mixes a cached repair back over the photo. Strength 0 returns the photo unchanged.
    /// `chain` identifies the image this mask was built from. It does not include this step's strength.
    static func apply(base: CIImage, operation: InpaintOp, chain: Int, context: CIContext? = nil) -> CIImage {
        let strength = min(1, max(0, operation.strength))
        if strength <= 0.001 { return base }
        let extent = base.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 1, height > 1 else { return base }
        let renderContext = context ?? Touchup.context
        let key = TouchupCache.Key(
            chain: chain,
            width: width,
            height: height,
            maskHash: fnv(operation.maskPNG),
            modelID: operation.modelID
        )
        let repaired: CIImage
        if let cached = TouchupCache.shared.image(for: key) {
            repaired = cached
        } else if let raster = read(base, context: renderContext),
                  let mask = TouchupEngine.bottomMask(operation.maskPNG, width: raster.width, height: raster.height) {
            let pixels = TouchupEngine.repair(
                samples: raster.samples,
                mask: mask,
                width: raster.width,
                height: raster.height,
                scratch: operation.modelID == InpaintModel.scratch
            )
            repaired = ciImage(pixels, width: raster.width, height: raster.height, extent: raster.extent)
            TouchupCache.shared.store(key, repaired)
        } else {
            return base
        }
        guard strength < 0.999 else { return repaired.cropped(to: base.extent) }
        guard let filter = CIFilter(name: "CIDissolveTransition") else { return repaired }
        filter.setValue(base, forKey: kCIInputImageKey)
        filter.setValue(repaired, forKey: kCIInputTargetImageKey)
        filter.setValue(strength, forKey: kCIInputTimeKey)
        return (filter.outputImage ?? repaired).cropped(to: base.extent)
    }

    private static func built(
        mask: [UInt8],
        samples: [Float],
        width: Int,
        height: Int,
        modelID: String
    ) -> TouchupBuilt? {
        let png = TouchupEngine.maskPNG(mask, width: width, height: height)
        guard !png.isEmpty else { return nil }
        let pixels = TouchupEngine.repair(
            samples: samples,
            mask: mask,
            width: width,
            height: height,
            scratch: modelID == InpaintModel.scratch
        )
        return TouchupBuilt(
            operation: InpaintOp(id: UUID(), maskPNG: png, modelID: modelID, featherPx: 2),
            pixels: pixels
        )
    }

    private static func fnv(_ data: Data) -> Int {
        var hash = 1_469_598_103_934_665_603
        for byte in data {
            hash = (hash ^ Int(byte)) &* 1_099_511_628_211
        }
        return hash
    }
}

private nonisolated final class TouchupCache: @unchecked Sendable {
    static let shared = TouchupCache()

    struct Key: Hashable {
        var chain: Int
        var width: Int
        var height: Int
        var maskHash: Int
        var modelID: String
    }

    private let lock = NSLock()
    private var images: [Key: CIImage] = [:]
    private var order: [Key] = []

    func image(for key: Key) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[key]
    }

    func store(_ key: Key, _ image: CIImage) {
        lock.lock()
        defer { lock.unlock() }
        images[key] = image
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 6 {
            images[order.removeFirst()] = nil
        }
    }

    func reset() {
        lock.lock()
        images.removeAll()
        order.removeAll()
        lock.unlock()
    }
}

/// Detection and the structure-plus-texture fill.
/// `CIContext.render` writes this buffer with row 0 at the top of the photo. Clicks use that same top-left space.
private nonisolated enum TouchupEngine {
    static func dustMask(samples: [Float], width: Int, height: Int) -> [UInt8]? {
        let luma = perceptualLuma(samples, width: width, height: height)
        let scale = Float(max(width, height)) / 2560
        let maxArea = max(30, Int(90 * scale * scale))
        let maxSpan = max(10, Int(18 * scale))
        var response = [Float](repeating: 0, count: width * height)
        var guardLuma = luma
        for radius in [2, 4] {
            let opened = opening(luma, width: width, height: height, radius: radius)
            let closed = closing(luma, width: width, height: height, radius: radius)
            if radius == 2 { guardLuma = opened }
            for index in response.indices {
                response[index] = max(response[index], max(luma[index] - opened[index], closed[index] - luma[index]))
            }
        }
        let gradient = gradientMagnitude(guardLuma, width: width, height: height)
        for index in response.indices where gradient[index] > 0.18 {
            response[index] = 0
        }
        let threshold = max(0.055, meanPlusSigma(response, factor: 4.8))
        var candidate = [UInt8](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let value = response[index]
                guard value >= threshold else { continue }
                if value < response[index - 1] || value < response[index + 1] || value < response[index - width] || value < response[index + width] {
                    continue
                }
                candidate[index] = 255
            }
        }
        let blobs = components(candidate, width: width, height: height, response: response)
        var kept = blobs.filter { blob in
            let span = max(blob.maxX - blob.minX, blob.maxY - blob.minY) + 1
            let shortSide = min(blob.maxX - blob.minX, blob.maxY - blob.minY) + 1
            let aspect = Float(span) / Float(max(shortSide, 1))
            if blob.pixels.count > maxArea || span > maxSpan { return false }
            if aspect > 3.5 && blob.pixels.count > 6 { return false }
            if blob.pixels.count == 1 && blob.peak < threshold * 1.25 { return false }
            return true
        }
        if kept.count > 400 {
            kept.sort { $0.peak > $1.peak }
            kept = Array(kept.prefix(400))
        }
        return paint(kept, width: width, height: height, dilate: 1)
    }

    static func scratchMask(samples: [Float], width: Int, height: Int) -> [UInt8]? {
        let luma = perceptualLuma(samples, width: width, height: height)
        let factor = max(width, height) >= 700 ? 2 : 1
        let smallW = max(1, width / factor)
        let smallH = max(1, height / factor)
        let small = downsample(luma, width: width, height: height, factor: factor, smallWidth: smallW, smallHeight: smallH)
        let scores = scratchScores(small, width: smallW, height: smallH)
        let threshold = max(0.06, meanPlusSigma(scores, factor: 5))
        var candidate = [UInt8](repeating: 0, count: smallW * smallH)
        for index in scores.indices where scores[index] >= threshold {
            candidate[index] = 255
        }
        let minCount = factor == 2 ? 8 : 14
        let minLambda = factor == 2 ? Float(20) : Float(36)
        var kept = components(candidate, width: smallW, height: smallH, response: scores).filter { blob in
            let shape = elongation(blob, width: smallW)
            return blob.pixels.count >= minCount && shape.lambdaMajor > minLambda && shape.ratio >= 6 && shape.thickness <= 4
        }
        if kept.count > 60 {
            kept.sort { $0.peak > $1.peak }
            kept = Array(kept.prefix(60))
        }
        var full = [UInt8](repeating: 0, count: width * height)
        for blob in kept {
            for index in blob.pixels {
                let x = index % smallW
                let y = index / smallW
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        let fx = x * factor + dx
                        let fy = y * factor + dy
                        if fx < width, fy < height {
                            full[fy * width + fx] = 255
                        }
                    }
                }
            }
        }
        let dilated = dilate(full, width: width, height: height, radius: 1)
        return dilated.contains(255) ? dilated : nil
    }

    static func spotMask(
        samples: [Float],
        width: Int,
        height: Int,
        bitmapPoint: CGPoint,
        radius: Int
    ) -> [UInt8]? {
        let radius = max(1, radius)
        guard let seed = snappedSpeck(
            samples: samples,
            width: width,
            height: height,
            bitmapPoint: bitmapPoint,
            radius: radius
        ) else {
            return nil
        }
        var mask = [UInt8](repeating: 0, count: width * height)
        var queue = [seed.index]
        var head = 0
        mask[seed.index] = 255
        var count = 1
        let limit = min(250_000, max(160, radius * radius * 3))
        let colorLimit = max(0.16, seed.score * 0.85)
        let medianGate = max(0.045, seed.score * 0.28)
        let reach = Float(radius * radius)
        while head < queue.count && count < limit {
            let current = queue[head]
            head += 1
            let x = current % width
            let y = current / width
            for step in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + step.0
                let ny = y + step.1
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let next = ny * width + nx
                if mask[next] != 0 { continue }
                let dx = Float(nx - seed.clickX)
                let dy = Float(ny - seed.clickY)
                if dx * dx + dy * dy > reach { continue }
                let offset = next * 4
                let distance = hypot(
                    samples[offset] - seed.red,
                    hypot(samples[offset + 1] - seed.green, samples[offset + 2] - seed.blue)
                )
                let fromMedian = hypot(
                    samples[offset] - seed.medianRed,
                    hypot(samples[offset + 1] - seed.medianGreen, samples[offset + 2] - seed.medianBlue)
                )
                guard distance < colorLimit, fromMedian > medianGate else { continue }
                mask[next] = 255
                count += 1
                queue.append(next)
            }
        }
        let grown = dilate(mask, width: width, height: height, radius: 1)
        return grown.contains(255) ? grown : nil
    }

    static func markedScratchMask(
        samples: [Float],
        width: Int,
        height: Int,
        points: [CGPoint],
        radius: Int
    ) -> [UInt8]? {
        let radius = max(1, radius)
        var raster: [(x: Int, y: Int)] = []
        for point in points {
            guard let next = rasterPoint(point, width: width, height: height) else { continue }
            if let last = raster.last, last.x == next.x, last.y == next.y { continue }
            raster.append(next)
        }
        guard raster.count >= 2 else { return nil }
        var mask = [UInt8](repeating: 0, count: width * height)
        var covered: Float = 0
        let spacing = max(1, radius / 4)
        for index in 1..<raster.count {
            let start = raster[index - 1]
            let end = raster[index]
            let dx = Float(end.x - start.x)
            let dy = Float(end.y - start.y)
            let length = hypot(dx, dy)
            guard length >= 0.5 else { continue }
            covered += length
            let steps = max(1, Int((length / Float(spacing)).rounded(.up)))
            for step in 0...steps {
                let t = Float(step) / Float(steps)
                let x = Int((Float(start.x) + dx * t).rounded())
                let y = Int((Float(start.y) + dy * t).rounded())
                stampDisk(mask: &mask, width: width, height: height, x: x, y: y, radius: radius)
            }
        }
        guard covered >= 2, mask.contains(255) else { return nil }
        return mask
    }

    static func repair(samples: [Float], mask: [UInt8], width: Int, height: Int, scratch: Bool) -> [Float] {
        let hole = dilate(mask, width: width, height: height, radius: 1)
        var alpha = blurMask(mask, width: width, height: height, radius: scratch ? 3 : 1)
        if scratch {
            for index in mask.indices where mask[index] != 0 {
                alpha[index] = 1
            }
        }
        var filled = samples
        let low = boxBlurRGB(samples, width: width, height: height, radius: 2)
        var high = samples
        for index in 0..<(width * height) {
            let offset = index * 4
            if hole[index] == 0 {
                high[offset] -= low[offset]
                high[offset + 1] -= low[offset + 1]
                high[offset + 2] -= low[offset + 2]
            } else {
                high[offset] = 0
                high[offset + 1] = 0
                high[offset + 2] = 0
            }
            high[offset + 3] = 1
        }
        let blobs = components(hole, width: width, height: height, response: alpha)
        for blob in blobs where !blob.pixels.isEmpty {
            if scratch {
                fillScratch(
                    filled: &filled,
                    samples: samples,
                    hole: hole,
                    blob: blob,
                    width: width,
                    height: height
                )
            } else {
                fillDust(
                    filled: &filled,
                    samples: samples,
                    high: high,
                    hole: hole,
                    blob: blob,
                    width: width,
                    height: height
                )
            }
        }
        var output = samples
        for index in 0..<(width * height) {
            let amount = alpha[index]
            if amount <= 0 { continue }
            let offset = index * 4
            let keep = 1 - amount
            output[offset] = samples[offset] * keep + filled[offset] * amount
            output[offset + 1] = samples[offset + 1] * keep + filled[offset + 1] * amount
            output[offset + 2] = samples[offset + 2] * keep + filled[offset + 2] * amount
            output[offset + 3] = 1
        }
        return output
    }

    static func maskPNG(_ mask: [UInt8], width: Int, height: Int) -> Data {
        var top = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let source = (height - 1 - row) * width
            let destination = row * width
            for x in 0..<width {
                top[destination + x] = mask[source + x]
            }
        }
        return InpaintPipeline.encodeGrayPNG(top, width: width, height: height)
    }

    static func bottomMask(_ png: Data, width: Int, height: Int) -> [UInt8]? {
        guard let decoded = topDownMask(png), decoded.width > 0, decoded.height > 0 else { return nil }
        var mask = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let topY = min(decoded.height - 1, (height - 1 - row) * decoded.height / height)
            for x in 0..<width {
                let sourceX = min(decoded.width - 1, x * decoded.width / width)
                mask[row * width + x] = decoded.pixels[topY * decoded.width + sourceX] > 16 ? 255 : 0
            }
        }
        return mask
    }

    private static func fillDust(
        filled: inout [Float],
        samples: [Float],
        high: [Float],
        hole: [UInt8],
        blob: Blob,
        width: Int,
        height: Int
    ) {
        let boundary = boundaryPixels(hole, blob: blob, width: width, height: height)
        guard !boundary.isEmpty else { return }
        let range = channelRange(samples, indexes: boundary)
        let donor = donorOffset(hole: hole, blob: blob, samples: samples, boundary: boundary, width: width, height: height)
        for index in blob.pixels {
            let color = inverseDistance(samples, index: index, boundary: boundary, width: width)
            var red = color.0
            var green = color.1
            var blue = color.2
            if let donor {
                let x = index % width + donor.x
                let y = index / width + donor.y
                if x >= 0, y >= 0, x < width, y < height {
                    let source = (y * width + x) * 4
                    red += high[source]
                    green += high[source + 1]
                    blue += high[source + 2]
                }
            }
            let offset = index * 4
            filled[offset] = min(max(red, range.redLo), range.redHi)
            filled[offset + 1] = min(max(green, range.greenLo), range.greenHi)
            filled[offset + 2] = min(max(blue, range.blueLo), range.blueHi)
            filled[offset + 3] = 1
        }
    }

    private static func fillScratch(
        filled: inout [Float],
        samples: [Float],
        hole: [UInt8],
        blob: Blob,
        width: Int,
        height: Int
    ) {
        let boundary = boundaryPixels(hole, blob: blob, width: width, height: height)
        let range = channelRange(samples, indexes: boundary.isEmpty ? blob.pixels : boundary)
        let field = outsideField(hole: hole, blob: blob, width: width, height: height)
        for index in blob.pixels {
            let x = index % width
            let y = index / width
            guard let near = field.seed(x: x, y: y) else { continue }
            let vx = Float(x - near.x)
            let vy = Float(y - near.y)
            let nearDist = hypot(vx, vy)
            guard nearDist >= 0.5 else { continue }
            let ux = vx / nearDist
            let uy = vy / nearDist
            let nearColor = sideColor(
                samples, hole: hole, width: width, height: height,
                pixelX: x, pixelY: y, exitX: near.x, exitY: near.y
            )
            var red = nearColor.0
            var green = nearColor.1
            var blue = nearColor.2
            if let far = oppositeExit(
                hole: hole, width: width, height: height,
                x: x, y: y, ux: ux, uy: uy, nearDist: nearDist
            ) {
                let farColor = sideColor(
                    samples, hole: hole, width: width, height: height,
                    pixelX: x, pixelY: y, exitX: far.x, exitY: far.y
                )
                let t = nearDist / (nearDist + far.distance)
                red = nearColor.0 * (1 - t) + farColor.0 * t
                green = nearColor.1 * (1 - t) + farColor.1 * t
                blue = nearColor.2 * (1 - t) + farColor.2 * t
            }
            let offset = index * 4
            filled[offset] = min(max(red, range.redLo), range.redHi)
            filled[offset + 1] = min(max(green, range.greenLo), range.greenHi)
            filled[offset + 2] = min(max(blue, range.blueLo), range.blueHi)
            filled[offset + 3] = 1
        }
    }

    /// Nearest outside pixel for each pixel of the stroke. The search stays in the stroke's box.
    private struct OutsideField {
        var x0: Int
        var y0: Int
        var width: Int
        var height: Int
        var originX: [Int]
        var originY: [Int]

        func seed(x: Int, y: Int) -> (x: Int, y: Int)? {
            let localX = x - x0
            let localY = y - y0
            guard localX >= 0, localY >= 0, localX < width, localY < height else { return nil }
            let index = localY * width + localX
            let seedX = originX[index]
            guard seedX >= 0 else { return nil }
            return (seedX, originY[index])
        }
    }

    private static func outsideField(hole: [UInt8], blob: Blob, width: Int, height: Int) -> OutsideField {
        let x0 = max(0, blob.minX - 2)
        let y0 = max(0, blob.minY - 2)
        let x1 = min(width - 1, blob.maxX + 2)
        let y1 = min(height - 1, blob.maxY + 2)
        let boxWidth = x1 - x0 + 1
        let boxHeight = y1 - y0 + 1
        var originX = [Int](repeating: -1, count: boxWidth * boxHeight)
        var originY = [Int](repeating: -1, count: boxWidth * boxHeight)
        var queue: [Int] = []
        for y in y0...y1 {
            for x in x0...x1 {
                let global = y * width + x
                guard hole[global] == 0 else { continue }
                let touches = (x > 0 && hole[global - 1] != 0)
                    || (x + 1 < width && hole[global + 1] != 0)
                    || (y > 0 && hole[global - width] != 0)
                    || (y + 1 < height && hole[global + width] != 0)
                guard touches else { continue }
                let local = (y - y0) * boxWidth + (x - x0)
                originX[local] = x
                originY[local] = y
                queue.append(local)
            }
        }
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            let localX = current % boxWidth
            let localY = current / boxWidth
            let seedX = originX[current]
            let seedY = originY[current]
            let x = x0 + localX
            let y = y0 + localY
            let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            for (nx, ny) in neighbors {
                guard nx >= x0, ny >= y0, nx <= x1, ny <= y1 else { continue }
                guard hole[ny * width + nx] != 0 else { continue }
                let local = (ny - y0) * boxWidth + (nx - x0)
                guard originX[local] < 0 else { continue }
                originX[local] = seedX
                originY[local] = seedY
                queue.append(local)
            }
        }
        return OutsideField(x0: x0, y0: y0, width: boxWidth, height: boxHeight, originX: originX, originY: originY)
    }

    /// The other side of the stroke. Nil at a round end, where the far side is a long walk down the stroke.
    private static func oppositeExit(
        hole: [UInt8],
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        ux: Float,
        uy: Float,
        nearDist: Float
    ) -> (x: Int, y: Int, distance: Float)? {
        let limit = min(512, max(24, Int(nearDist * 4) + 8))
        for step in 1...limit {
            let nx = Int((Float(x) + ux * Float(step)).rounded())
            let ny = Int((Float(y) + uy * Float(step)).rounded())
            guard nx >= 0, ny >= 0, nx < width, ny < height else { return nil }
            guard hole[ny * width + nx] == 0 else { continue }
            let distance = hypot(Float(nx - x), Float(ny - y))
            guard distance <= nearDist * 3 + 8 else { return nil }
            return (nx, ny, distance)
        }
        return nil
    }

    /// Color continued from outside the stroke, across from this pixel. A pixel on the lip is not smeared inward.
    private static func sideColor(
        _ samples: [Float],
        hole: [UInt8],
        width: Int,
        height: Int,
        pixelX: Int,
        pixelY: Int,
        exitX: Int,
        exitY: Int
    ) -> (Float, Float, Float) {
        let dx = Float(exitX - pixelX)
        let dy = Float(exitY - pixelY)
        let len = max(0.5, hypot(dx, dy))
        let tx = -dy / len
        let ty = dx / len
        let ux = dx / len
        let uy = dy / len
        for extra in 0...2 {
            let mx = Int((Float(exitX) + ux * (len + Float(extra))).rounded())
            let my = Int((Float(exitY) + uy * (len + Float(extra))).rounded())
            if let color = outsideAverage(
                samples, hole: hole, width: width, height: height,
                x: mx, y: my, tx: tx, ty: ty
            ) {
                return color
            }
        }
        let offset = (exitY * width + exitX) * 4
        return (samples[offset], samples[offset + 1], samples[offset + 2])
    }

    private static func outsideAverage(
        _ samples: [Float],
        hole: [UInt8],
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        tx: Float,
        ty: Float
    ) -> (Float, Float, Float)? {
        guard x >= 0, y >= 0, x < width, y < height, hole[y * width + x] == 0 else { return nil }
        var red: Float = 0
        var green: Float = 0
        var blue: Float = 0
        var count: Float = 0
        for step in -1...1 {
            let sx = Int((Float(x) + tx * Float(step)).rounded())
            let sy = Int((Float(y) + ty * Float(step)).rounded())
            guard sx >= 0, sy >= 0, sx < width, sy < height else { continue }
            let index = sy * width + sx
            guard hole[index] == 0 else { continue }
            let offset = index * 4
            red += samples[offset]
            green += samples[offset + 1]
            blue += samples[offset + 2]
            count += 1
        }
        guard count > 0 else { return nil }
        return (red / count, green / count, blue / count)
    }

    private static func snappedSpeck(
        samples: [Float],
        width: Int,
        height: Int,
        bitmapPoint: CGPoint,
        radius: Int
    ) -> (index: Int, x: Int, y: Int, clickX: Int, clickY: Int, red: Float, green: Float, blue: Float, medianRed: Float, medianGreen: Float, medianBlue: Float, score: Float)? {
        guard let point = rasterPoint(bitmapPoint, width: width, height: height) else { return nil }
        let radius = max(1, radius)
        let outer = radius + max(6, radius / 5)
        let step = radius > 48 ? 3 : (radius > 16 ? 2 : 1)
        var reds: [Float] = []
        var greens: [Float] = []
        var blues: [Float] = []
        func collect(_ x: Int, _ y: Int) {
            let offset = (y * width + x) * 4
            reds.append(samples[offset])
            greens.append(samples[offset + 1])
            blues.append(samples[offset + 2])
        }
        for y in stride(from: max(0, point.y - outer), through: min(height - 1, point.y + outer), by: step) {
            for x in stride(from: max(0, point.x - outer), through: min(width - 1, point.x + outer), by: step) {
                let dx = x - point.x
                let dy = y - point.y
                let distance = dx * dx + dy * dy
                guard distance > radius * radius, distance <= outer * outer else { continue }
                collect(x, y)
            }
        }
        if reds.count < 12 {
            reds.removeAll()
            greens.removeAll()
            blues.removeAll()
            let corner = min(8, min(width, height) / 2)
            guard corner > 0 else { return nil }
            for y in 0..<corner {
                for x in 0..<corner {
                    collect(x, y)
                    collect(width - 1 - x, y)
                    collect(x, height - 1 - y)
                    collect(width - 1 - x, height - 1 - y)
                }
            }
        }
        guard !reds.isEmpty else { return nil }
        reds.sort()
        greens.sort()
        blues.sort()
        let medianRed = reds[reds.count / 2]
        let medianGreen = greens[greens.count / 2]
        let medianBlue = blues[blues.count / 2]
        var bestIndex = point.y * width + point.x
        var bestScore: Float = -1
        let reach = radius * radius
        for y in max(0, point.y - radius)...min(height - 1, point.y + radius) {
            for x in max(0, point.x - radius)...min(width - 1, point.x + radius) {
                let dx = x - point.x
                let dy = y - point.y
                if dx * dx + dy * dy > reach { continue }
                let offset = (y * width + x) * 4
                let score = hypot(
                    samples[offset] - medianRed,
                    hypot(samples[offset + 1] - medianGreen, samples[offset + 2] - medianBlue)
                )
                if score > bestScore {
                    bestScore = score
                    bestIndex = y * width + x
                }
            }
        }
        guard bestScore > 0.05 else { return nil }
        let offset = bestIndex * 4
        return (
            bestIndex,
            bestIndex % width,
            bestIndex / width,
            point.x,
            point.y,
            samples[offset],
            samples[offset + 1],
            samples[offset + 2],
            medianRed,
            medianGreen,
            medianBlue,
            bestScore
        )
    }

    /// `point` is top-left, y down, in the same orientation as the rendered buffer.
    private static func rasterPoint(_ point: CGPoint, width: Int, height: Int) -> (x: Int, y: Int)? {
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return (x, y)
    }

    private static func perceptualLuma(_ samples: [Float], width: Int, height: Int) -> [Float] {
        var luma = [Float](repeating: 0, count: width * height)
        for index in luma.indices {
            let offset = index * 4
            let linear = 0.2126 * max(samples[offset], 0) + 0.7152 * max(samples[offset + 1], 0) + 0.0722 * max(samples[offset + 2], 0)
            luma[index] = pow(linear, 0.45)
        }
        return luma
    }

    private static func opening(_ source: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        dilateFilter(erode(source, width: width, height: height, radius: radius), width: width, height: height, radius: radius)
    }

    private static func closing(_ source: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        erode(dilateFilter(source, width: width, height: height, radius: radius), width: width, height: height, radius: radius)
    }

    private static func erode(_ source: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        rank(source, width: width, height: height, radius: radius, minimum: true)
    }

    private static func dilateFilter(_ source: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        rank(source, width: width, height: height, radius: radius, minimum: false)
    }

    private static func rank(_ source: [Float], width: Int, height: Int, radius: Int, minimum: Bool) -> [Float] {
        var horizontal = [Float](repeating: 0, count: width * height)
        var output = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var value = source[row + x]
                let start = max(0, x - radius)
                let end = min(width - 1, x + radius)
                for sample in start...end {
                    let next = source[row + sample]
                    value = minimum ? min(value, next) : max(value, next)
                }
                horizontal[row + x] = value
            }
        }
        for x in 0..<width {
            for y in 0..<height {
                var value = horizontal[y * width + x]
                let start = max(0, y - radius)
                let end = min(height - 1, y + radius)
                for sample in start...end {
                    let next = horizontal[sample * width + x]
                    value = minimum ? min(value, next) : max(value, next)
                }
                output[y * width + x] = value
            }
        }
        return output
    }

    private static func gradientMagnitude(_ source: [Float], width: Int, height: Int) -> [Float] {
        var output = [Float](repeating: 0, count: width * height)
        guard width > 2, height > 2 else { return output }
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                output[index] = abs(source[index + 1] - source[index - 1]) + abs(source[index + width] - source[index - width])
            }
        }
        return output
    }

    private static func meanPlusSigma(_ values: [Float], factor: Float) -> Float {
        var count = 0
        var mean: Float = 0
        var moment: Float = 0
        for index in stride(from: 0, to: values.count, by: 3) {
            let value = values[index]
            count += 1
            let delta = value - mean
            mean += delta / Float(count)
            moment += delta * (value - mean)
        }
        guard count > 1 else { return 0.055 }
        let deviation = sqrt(moment / Float(count - 1))
        return mean + factor * deviation
    }

    private static func downsample(
        _ source: [Float],
        width: Int,
        height: Int,
        factor: Int,
        smallWidth: Int,
        smallHeight: Int
    ) -> [Float] {
        if factor == 1 { return source }
        var output = [Float](repeating: 0, count: smallWidth * smallHeight)
        for y in 0..<smallHeight {
            for x in 0..<smallWidth {
                var sum: Float = 0
                var count: Float = 0
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        let sx = min(width - 1, x * factor + dx)
                        let sy = min(height - 1, y * factor + dy)
                        sum += source[sy * width + sx]
                        count += 1
                    }
                }
                output[y * smallWidth + x] = sum / max(count, 1)
            }
        }
        return output
    }

    private static func scratchScores(_ luma: [Float], width: Int, height: Int) -> [Float] {
        var scores = [Float](repeating: 0, count: width * height)
        let blur = boxBlur(luma, width: width, height: height, radius: 2)
        let directions: [(Float, Float)] = [
            (1, 0), (0.8660254, 0.5), (0.5, 0.8660254), (0, 1), (-0.5, 0.8660254), (-0.8660254, 0.5),
        ]
        let margin = 16
        guard width > margin * 2, height > margin * 2 else { return scores }
        for y in margin..<(height - margin) {
            for x in margin..<(width - margin) {
                let index = y * width + x
                if abs(luma[index] - blur[index]) < 0.035 { continue }
                let center = luma[index]
                var best: Float = -1
                var second: Float = -1
                for direction in directions {
                    let along = median3(
                        sampleOne(luma, width: width, height: height, x: x, y: y, dx: direction.0, dy: direction.1, distance: 3),
                        sampleOne(luma, width: width, height: height, x: x, y: y, dx: direction.0, dy: direction.1, distance: 7),
                        sampleOne(luma, width: width, height: height, x: x, y: y, dx: -direction.0, dy: -direction.1, distance: 7)
                    )
                    let positive = median3(
                        sampleOne(luma, width: width, height: height, x: x, y: y, dx: -direction.1, dy: direction.0, distance: 5),
                        sampleOne(luma, width: width, height: height, x: x, y: y, dx: -direction.1, dy: direction.0, distance: 9),
                        sampleOne(luma, width: width, height: height, x: x, y: y, dx: -direction.1, dy: direction.0, distance: 14)
                    )
                    let negative = median3(
                        sampleOne(luma, width: width, height: height, x: x, y: y, dx: direction.1, dy: -direction.0, distance: 5),
                        sampleOne(luma, width: width, height: height, x: x, y: y, dx: direction.1, dy: -direction.0, distance: 9),
                        sampleOne(luma, width: width, height: height, x: x, y: y, dx: direction.1, dy: -direction.0, distance: 14)
                    )
                    guard abs(positive - negative) < 0.12 else { continue }
                    let score = abs(center - (positive + negative) * 0.5) - abs(center - along)
                    if score > best {
                        second = best
                        best = score
                    } else if score > second {
                        second = score
                    }
                }
                if best > 0.05 && best > second + 0.015 {
                    scores[index] = best
                }
            }
        }
        return scores
    }

    private static func sampleOne(_ luma: [Float], width: Int, height: Int, x: Int, y: Int, dx: Float, dy: Float, distance: Int) -> Float {
        let sx = min(max(0, Int((Float(x) + dx * Float(distance)).rounded())), width - 1)
        let sy = min(max(0, Int((Float(y) + dy * Float(distance)).rounded())), height - 1)
        return luma[sy * width + sx]
    }

    private static func median3(_ a: Float, _ b: Float, _ c: Float) -> Float {
        if a > b {
            if b > c { return b }
            return a > c ? c : a
        }
        if a > c { return a }
        return b > c ? c : b
    }

    private struct Blob {
        var pixels: [Int] = []
        var peak: Float = 0
        var minX = Int.max
        var maxX = 0
        var minY = Int.max
        var maxY = 0
        var sumX: Float = 0
        var sumY: Float = 0
        var sumXX: Float = 0
        var sumYY: Float = 0
        var sumXY: Float = 0
    }

    private static func components(_ mask: [UInt8], width: Int, height: Int, response: [Float]) -> [Blob] {
        var seen = [UInt8](repeating: 0, count: width * height)
        var blobs: [Blob] = []
        for start in mask.indices where mask[start] != 0 && seen[start] == 0 {
            var blob = Blob()
            var queue = [start]
            var head = 0
            seen[start] = 1
            while head < queue.count {
                let index = queue[head]
                head += 1
                let x = index % width
                let y = index / width
                blob.pixels.append(index)
                blob.peak = max(blob.peak, index < response.count ? response[index] : 0)
                blob.minX = min(blob.minX, x)
                blob.maxX = max(blob.maxX, x)
                blob.minY = min(blob.minY, y)
                blob.maxY = max(blob.maxY, y)
                let fx = Float(x)
                let fy = Float(y)
                blob.sumX += fx
                blob.sumY += fy
                blob.sumXX += fx * fx
                blob.sumYY += fy * fy
                blob.sumXY += fx * fy
                let neighbors = [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1, y > 0 ? index - width : -1, y + 1 < height ? index + width : -1]
                for next in neighbors where next >= 0 && mask[next] != 0 && seen[next] == 0 {
                    seen[next] = 1
                    queue.append(next)
                }
            }
            blobs.append(blob)
        }
        return blobs
    }

    private static func elongation(_ blob: Blob, width: Int) -> (ratio: Float, lambdaMajor: Float, thickness: Float, theta: Float) {
        let count = Float(max(blob.pixels.count, 1))
        let meanX = blob.sumX / count
        let meanY = blob.sumY / count
        let cxx = max(0, blob.sumXX / count - meanX * meanX)
        let cyy = max(0, blob.sumYY / count - meanY * meanY)
        let cxy = blob.sumXY / count - meanX * meanY
        let half = (cxx + cyy) * 0.5
        let root = sqrt(max(0, half * half - (cxx * cyy - cxy * cxy)))
        let major = half + root
        let minor = max(0, half - root)
        _ = width
        return (major / max(minor, 0.25), major, minor, 0.5 * atan2(2 * cxy, cxx - cyy))
    }

    private static func paint(_ blobs: [Blob], width: Int, height: Int, dilate radius: Int) -> [UInt8]? {
        var mask = [UInt8](repeating: 0, count: width * height)
        for blob in blobs {
            for index in blob.pixels {
                mask[index] = 255
            }
        }
        let grown = dilate(mask, width: width, height: height, radius: radius)
        return grown.contains(255) ? grown : nil
    }

    private static func dilate(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard radius > 0 else { return mask }
        var output = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var on = false
                let y0 = max(0, y - radius)
                let y1 = min(height - 1, y + radius)
                let x0 = max(0, x - radius)
                let x1 = min(width - 1, x + radius)
                for yy in y0...y1 where !on {
                    for xx in x0...x1 where mask[yy * width + xx] != 0 {
                        on = true
                        break
                    }
                }
                if on { output[y * width + x] = 255 }
            }
        }
        return output
    }

    private static func blurMask(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [Float] {
        var source = [Float](repeating: 0, count: width * height)
        for index in mask.indices where mask[index] != 0 {
            source[index] = 1
        }
        return boxBlur(source, width: width, height: height, radius: radius)
    }

    private static func boxBlur(_ source: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var horizontal = [Float](repeating: 0, count: width * height)
        var output = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                var count: Float = 0
                for sample in max(0, x - radius)...min(width - 1, x + radius) {
                    sum += source[y * width + sample]
                    count += 1
                }
                horizontal[y * width + x] = sum / max(count, 1)
            }
        }
        for x in 0..<width {
            for y in 0..<height {
                var sum: Float = 0
                var count: Float = 0
                for sample in max(0, y - radius)...min(height - 1, y + radius) {
                    sum += horizontal[sample * width + x]
                    count += 1
                }
                output[y * width + x] = sum / max(count, 1)
            }
        }
        return output
    }

    private static func boxBlurRGB(_ samples: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var planes = [Float](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            planes[index] = samples[index * 4]
            planes[width * height + index] = samples[index * 4 + 1]
            planes[width * height * 2 + index] = samples[index * 4 + 2]
        }
        var output = [Float](repeating: 0, count: width * height * 4)
        for channel in 0..<3 {
            let start = channel * width * height
            let blurred = boxBlur(Array(planes[start..<(start + width * height)]), width: width, height: height, radius: radius)
            for index in 0..<(width * height) {
                output[index * 4 + channel] = blurred[index]
            }
        }
        return output
    }

    private static func boundaryPixels(_ hole: [UInt8], blob: Blob, width: Int, height: Int) -> [Int] {
        var found: [Int] = []
        let y0 = max(0, blob.minY - 3)
        let y1 = min(height - 1, blob.maxY + 3)
        let x0 = max(0, blob.minX - 3)
        let x1 = min(width - 1, blob.maxX + 3)
        for y in y0...y1 {
            for x in x0...x1 {
                let index = y * width + x
                guard hole[index] == 0 else { continue }
                var near = false
                for yy in max(0, y - 2)...min(height - 1, y + 2) where !near {
                    for xx in max(0, x - 2)...min(width - 1, x + 2) where hole[yy * width + xx] != 0 {
                        near = true
                        break
                    }
                }
                if near { found.append(index) }
                if found.count == 240 { return found }
            }
        }
        return found
    }

    private static func inverseDistance(_ samples: [Float], index: Int, boundary: [Int], width: Int) -> (Float, Float, Float) {
        let x = index % width
        let y = index / width
        var red: Float = 0
        var green: Float = 0
        var blue: Float = 0
        var weight: Float = 0
        for boundaryIndex in boundary {
            let dx = Float(boundaryIndex % width - x)
            let dy = Float(boundaryIndex / width - y)
            let value = 1 / (dx * dx + dy * dy + 0.35)
            let offset = boundaryIndex * 4
            red += samples[offset] * value
            green += samples[offset + 1] * value
            blue += samples[offset + 2] * value
            weight += value
        }
        guard weight > 0 else {
            let offset = index * 4
            return (samples[offset], samples[offset + 1], samples[offset + 2])
        }
        return (red / weight, green / weight, blue / weight)
    }

    private static func donorOffset(
        hole: [UInt8],
        blob: Blob,
        samples: [Float],
        boundary: [Int],
        width: Int,
        height: Int
    ) -> (x: Int, y: Int)? {
        var bestScore = Float.greatestFiniteMagnitude
        var best: (Int, Int)?
        let probes = Array(blob.pixels.prefix(100))
        let ring = Array(boundary.prefix(40))
        guard !probes.isEmpty, !ring.isEmpty else { return nil }
        for oy in stride(from: -30, through: 30, by: 3) {
            for ox in stride(from: -30, through: 30, by: 3) {
                if ox == 0 && oy == 0 { continue }
                var valid = true
                for index in probes {
                    let nx = index % width + ox
                    let ny = index / width + oy
                    if nx < 0 || ny < 0 || nx >= width || ny >= height || hole[ny * width + nx] != 0 {
                        valid = false
                        break
                    }
                }
                guard valid else { continue }
                var score: Float = 0
                var count: Float = 0
                for index in ring {
                    let nx = index % width + ox
                    let ny = index / width + oy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let left = index * 4
                    let right = (ny * width + nx) * 4
                    score += abs(samples[left] - samples[right])
                    score += abs(samples[left + 1] - samples[right + 1])
                    score += abs(samples[left + 2] - samples[right + 2])
                    count += 1
                }
                guard count > 0 else { continue }
                score = score / count + 0.002 * Float(abs(ox) + abs(oy))
                if score < bestScore {
                    bestScore = score
                    best = (ox, oy)
                }
            }
        }
        return best
    }

    private struct ChannelRange {
        var redLo: Float
        var redHi: Float
        var greenLo: Float
        var greenHi: Float
        var blueLo: Float
        var blueHi: Float
    }

    private static func channelRange(_ samples: [Float], indexes: [Int]) -> ChannelRange {
        var range = ChannelRange(redLo: 1, redHi: 0, greenLo: 1, greenHi: 0, blueLo: 1, blueHi: 0)
        for index in indexes {
            let offset = index * 4
            range.redLo = min(range.redLo, samples[offset])
            range.redHi = max(range.redHi, samples[offset])
            range.greenLo = min(range.greenLo, samples[offset + 1])
            range.greenHi = max(range.greenHi, samples[offset + 1])
            range.blueLo = min(range.blueLo, samples[offset + 2])
            range.blueHi = max(range.blueHi, samples[offset + 2])
        }
        range.redLo -= 0.06
        range.redHi += 0.06
        range.greenLo -= 0.06
        range.greenHi += 0.06
        range.blueLo -= 0.06
        range.blueHi += 0.06
        return range
    }

    private static func stampDisk(mask: inout [UInt8], width: Int, height: Int, x: Int, y: Int, radius: Int) {
        for yy in max(0, y - radius)...min(height - 1, y + radius) {
            for xx in max(0, x - radius)...min(width - 1, x + radius) {
                let dx = xx - x
                let dy = yy - y
                if dx * dx + dy * dy <= radius * radius + radius {
                    mask[yy * width + xx] = 255
                }
            }
        }
    }

    private static func topDownMask(_ png: Data) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let provider = image.dataProvider,
              let raw = provider.data,
              let pointer = CFDataGetBytePtr(raw) else {
            return nil
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let source = y * image.bytesPerRow + x * bytesPerPixel
                if source < CFDataGetLength(raw) {
                    pixels[y * width + x] = pointer[source]
                }
            }
        }
        return (pixels, width, height)
    }
}
