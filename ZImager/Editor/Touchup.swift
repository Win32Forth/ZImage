import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

/// Several spot clicks repaired from one read. `operations` are the clicks that found a speck, in click order.
struct TouchupSpotBatch: Sendable {
    var operations: [InpaintOp]
    var repaired: CIImage?
    var preview: CGImage?
    var spectrum: [Int]
    var folderJPEG: Data?
    var width: Int
    var height: Int
}

/// One picture that was on screen for a particular repair list.
/// `image` is absent when the screen picture was saved before a raster existed.
nonisolated struct TouchupShown: Sendable {
    var token: Int
    var operations: [InpaintOp]
    var image: CIImage?
    var tone: ToneState
    var preview: CGImage
    var spectrum: [Int]
}

/// The last few repaired pictures. Undo of a recent spot puts one back without rebuilding every earlier repair.
nonisolated struct TouchupPictures: Sendable {
    private var frames: [TouchupShown] = []
    var cap: Int

    init(cap: Int = 6) {
        self.cap = max(1, cap)
    }

    var count: Int { frames.count }

    mutating func removeAll() {
        frames.removeAll()
    }

    /// Keeps a raster already stored when the new frame only has the on-screen picture.
    mutating func remember(_ frame: TouchupShown) {
        if let index = frames.lastIndex(where: { $0.token == frame.token && $0.operations == frame.operations }) {
            var kept = frames.remove(at: index)
            if frame.image == nil {
                kept.preview = frame.preview
                kept.tone = frame.tone
                kept.spectrum = frame.spectrum
                frames.append(kept)
            } else {
                frames.append(frame)
            }
        } else {
            frames.append(frame)
        }
        if frames.count > cap {
            frames.removeFirst(frames.count - cap)
        }
    }

    func frame(token: Int, operations: [InpaintOp]) -> TouchupShown? {
        frames.last { $0.token == token && $0.operations == operations }
    }
}

/// The bar on the photograph while saved repairs are rebuilt. `fraction` stays nil until the first repair finishes.
nonisolated struct TouchupMeter: Equatable {
    var title: String
    var done: Int
    var total: Int
    var fraction: Double?

    var caption: String {
        guard total > 0 else { return title }
        return "\(title) \(done) of \(total)"
    }
}

/// Turns finished repair patches into a position on the whole list.
/// `jobTotal` is 0 while the photograph is still being read.
nonisolated enum TouchupReplayScale {
    static func measure(
        doneBefore: Int,
        runCount: Int,
        jobDone: Int,
        jobTotal: Int,
        total: Int
    ) -> (fraction: Double, done: Int) {
        guard total > 0 else { return (0, 0) }
        let span = max(0, runCount)
        let before = max(0, doneBefore)
        let portion: Double
        let advanced: Int
        if jobTotal <= 0 {
            portion = 0
            advanced = 0
        } else if jobDone >= jobTotal {
            portion = 1
            advanced = span
        } else {
            portion = Double(max(0, jobDone)) / Double(jobTotal)
            advanced = span * max(0, jobDone) / jobTotal
        }
        let fraction = min(1, max(0, (Double(before) + portion * Double(span)) / Double(total)))
        let done = min(total, before + advanced)
        return (fraction, done)
    }
}

/// Posts the newest repair count on the main queue. A patch that finishes out of order cannot move the bar backward.
/// The post is asynchronous, so a repair thread does not wait on the main thread.
nonisolated final class TouchupMeterSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var fraction = 0.0
    private var done = 0
    private var total = 0
    private let deliver: @Sendable (Double, Int, Int) -> Void

    init(deliver: @escaping @Sendable (Double, Int, Int) -> Void) {
        self.deliver = deliver
    }

    func report(fraction: Double, done: Int, total: Int) {
        lock.lock()
        let newer = fraction > self.fraction + 0.000_000_1 || done > self.done
        if newer {
            if fraction > self.fraction { self.fraction = fraction }
            if done > self.done { self.done = done }
            if total > self.total { self.total = total }
        }
        let start = newer && !pending
        if start { pending = true }
        lock.unlock()
        guard start else { return }
        DispatchQueue.main.async { [self] in
            self.lock.lock()
            let fraction = self.fraction
            let done = self.done
            let total = self.total
            self.pending = false
            self.lock.unlock()
            self.deliver(fraction, done, total)
        }
    }
}

/// Work for one Touchup button or stroke. Run it off the main actor.
nonisolated enum TouchupWork: Sendable {
    case dust
    case scratches
    case spot(CGPoint, Int)
    case scratch([CGPoint], Int)
    case redEye(CGPoint)

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

/// Outstanding Dust, Scratches, Red Eye, Spot, and Scratch repairs. The running job counts toward `cap`.
nonisolated struct TouchupQueue: Sendable {
    static let cap = 64

    private(set) var waiting: [QueuedTouchup] = []
    private(set) var running: QueuedTouchup?
    /// Spot clicks traveling with `running` in the current batch, not including `running` itself.
    private var heldSpots = 0

    var count: Int { waiting.count + (running == nil ? 0 : 1) + heldSpots }

    /// Spot clicks not yet finished, including the ones in the running batch.
    var spotsRemaining: Int {
        var total = heldSpots
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

    /// The running spot, then every waiting spot up to the next other repair.
    /// `running` stays set so a click during the batch keeps waiting. An empty array means the running job is not a spot.
    mutating func takeLeadingSpots() -> [QueuedTouchup] {
        guard let current = running, current.work.isSpot else { return [] }
        var batch = [current]
        while let next = waiting.first, next.work.isSpot {
            batch.append(waiting.removeFirst())
        }
        heldSpots = batch.count - 1
        return batch
    }

    /// Drops the running job and promotes the next one. Nil when the list is empty.
    mutating func finishRunning() -> QueuedTouchup? {
        heldSpots = 0
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
        heldSpots = 0
    }
}

nonisolated enum Touchup {
    /// Fraction finished, repairs finished, and the repair count. Called off the main thread.
    typealias ProgressHandler = @Sendable (Double, Int, Int) -> Void

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
    /// Undo's rebuild uses this queue, so it does not wait behind a spot click that was already cancelled.
    private static let replayQueue = DispatchQueue(label: "com.Win32Forth.ZImager.touchup.replay", qos: .userInitiated)
    private static let replayContext: CIContext = {
        CIContext(options: [
            .workingColorSpace: TonePipeline.workingColorSpace,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .priorityRequestLow: true,
        ])
    }()
    /// Bumped when a click is cancelled. A repair still waiting on `jobQueue` returns without reading the photo.
    private static let workLock = NSLock()
    private static var workGeneration = 0
    /// Pixels of the last repaired picture. The next spot on that same picture skips another full-frame read.
    private static var rasterCache: RasterBuffer?

    private struct RasterBuffer {
        var key: Int
        var samples: [Float]
        var width: Int
        var height: Int
        var extent: CGRect
    }

    /// Drops repairs that have not started. The one already reading still finishes, then its result is ignored.
    static func abandonQueuedWork() {
        workLock.lock()
        workGeneration += 1
        workLock.unlock()
    }

    static func resetRasterCache() {
        workLock.lock()
        rasterCache = nil
        workLock.unlock()
    }

    private static func workTicket() -> Int {
        workLock.lock()
        defer { workLock.unlock() }
        return workGeneration
    }

    private static func workTicketIsCurrent(_ ticket: Int) -> Bool {
        workLock.lock()
        defer { workLock.unlock() }
        return workGeneration == ticket
    }

    private static func cachedRaster(key: Int) -> RasterBuffer? {
        workLock.lock()
        defer { workLock.unlock() }
        guard let rasterCache, rasterCache.key == key else { return nil }
        return rasterCache
    }

    private static func storeRaster(_ buffer: RasterBuffer, ticket: Int) {
        workLock.lock()
        defer { workLock.unlock() }
        guard workGeneration == ticket else { return }
        rasterCache = buffer
    }

    /// One Core Image context per core. A context is not shared across threads.
    private final class RenderSlot: @unchecked Sendable {
        let context: CIContext
        let lock = NSLock()
        init() {
            context = CIContext(options: [
                .workingColorSpace: TonePipeline.workingColorSpace,
                .workingFormat: CIFormat.RGBAh,
                .cacheIntermediates: false,
                .priorityRequestLow: true,
            ])
        }
    }

    private static let renderSlots: [RenderSlot] = {
        let count = max(2, ProcessInfo.processInfo.activeProcessorCount)
        return (0..<count).map { _ in RenderSlot() }
    }()

    static func perform(_ work: TouchupWork, samples: [Float], width: Int, height: Int) -> TouchupBuilt? {
        let built: TouchupBuilt?
        switch work {
        case .dust:
            built = dust(samples: samples, width: width, height: height)
        case .scratches:
            built = scratches(samples: samples, width: width, height: height)
        case .spot(let point, let radius):
            built = spot(samples: samples, width: width, height: height, bitmapPoint: point, radius: radius)
        case .scratch(let points, let radius):
            built = markedScratch(samples: samples, width: width, height: height, points: points, radius: radius)
        case .redEye(let point):
            built = redEye(samples: samples, width: width, height: height, bitmapPoint: point)
        }
        guard var built else { return nil }
        built.operation.patch = makePatch(
            before: samples,
            after: built.pixels,
            width: width,
            height: height,
            rasterWidth: width,
            rasterHeight: height,
            strength: built.operation.strength
        )
        return built
    }

    /// Rebuilds saved spot and scratch repairs away from the main thread. A row of full-strength dust
    /// spots shares one read and fills on the cores together. The main thread stays free to draw.
    /// This does not use the spot queue, so Undo is not stuck behind a click that was cancelled.
    /// `progress` runs as each repair finishes. It must return without waiting on the main thread.
    static func replay(
        base: CIImage,
        operations: [InpaintOp],
        token: Int,
        displayTurns: Int? = nil,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        progress: ProgressHandler? = nil
    ) async -> CIImage? {
        let ticket = workTicket()
        return await withCheckedContinuation { continuation in
            replayQueue.async {
                guard Self.workTicketIsCurrent(ticket) else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = InpaintPipeline.applyInteractive(
                    base: base,
                    operations: operations,
                    imageToken: token,
                    displayTurns: displayTurns,
                    flipHorizontal: flipHorizontal,
                    flipVertical: flipVertical,
                    context: replayContext,
                    isCancelled: { !Self.workTicketIsCurrent(ticket) },
                    progress: progress
                )
                guard Self.workTicketIsCurrent(ticket) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    /// Renders the working image, repairs it, and builds the on-screen picture away from the main thread.
    /// `priorOperations` are repairs already in the log. They are applied here when the caller does not already have that picture.
    /// `baseChain` identifies the pixels being repaired. A later spot with the same chain reuses them.
    static func finishOffMain(
        image: CIImage,
        work: TouchupWork,
        tone: ToneState,
        displaySpaceName: String,
        priorOperations: [InpaintOp] = [],
        priorToken: Int = 0,
        baseChain: Int = 0,
        frameToken: Int = 0,
        displayTurns: Int? = nil,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false
    ) async -> TouchupJobResult {
        let ticket = workTicket()
        return await withCheckedContinuation { continuation in
            jobQueue.async {
                guard workTicketIsCurrent(ticket) else {
                    continuation.resume(returning: TouchupJobResult(
                        built: nil, repaired: nil, preview: nil, spectrum: [], folderJPEG: nil, width: 0, height: 0
                    ))
                    return
                }
                continuation.resume(returning: finish(
                    image: image,
                    work: work,
                    tone: tone,
                    displaySpaceName: displaySpaceName,
                    priorOperations: priorOperations,
                    priorToken: priorToken,
                    baseChain: baseChain,
                    frameToken: frameToken,
                    displayTurns: displayTurns,
                    flipHorizontal: flipHorizontal,
                    flipVertical: flipVertical,
                    ticket: ticket
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
        priorToken: Int,
        baseChain: Int,
        frameToken: Int,
        displayTurns: Int?,
        flipHorizontal: Bool,
        flipVertical: Bool,
        ticket: Int
    ) -> TouchupJobResult {
        guard let raster = raster(
            image: image,
            priorOperations: priorOperations,
            priorToken: priorToken,
            baseChain: baseChain,
            displayTurns: displayTurns,
            flipHorizontal: flipHorizontal,
            flipVertical: flipVertical,
            ticket: ticket
        ) else {
            return TouchupJobResult(
                built: nil, repaired: nil, preview: nil, spectrum: [], folderJPEG: nil, width: 0, height: 0
            )
        }
        guard var built = perform(work, samples: raster.samples, width: raster.width, height: raster.height) else {
            return TouchupJobResult(
                built: nil, repaired: nil, preview: nil, spectrum: [], folderJPEG: nil,
                width: raster.width, height: raster.height
            )
        }
        guard workTicketIsCurrent(ticket) else {
            return TouchupJobResult(
                built: nil, repaired: nil, preview: nil, spectrum: [], folderJPEG: nil,
                width: raster.width, height: raster.height
            )
        }
        built.operation = tag(built.operation, frameToken: frameToken)
        storeRaster(
            RasterBuffer(
                key: advance(baseChain, built.operation),
                samples: built.pixels,
                width: raster.width,
                height: raster.height,
                extent: raster.extent
            ),
            ticket: ticket
        )
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

    /// One read of the photograph, then every spot window fills at the same time. The picture is the composite.
    static func finishSpotsOffMain(
        image: CIImage,
        spots: [(CGPoint, Int)],
        tone: ToneState,
        displaySpaceName: String,
        priorOperations: [InpaintOp] = [],
        priorToken: Int = 0,
        baseChain: Int = 0,
        frameToken: Int = 0,
        displayTurns: Int? = nil,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false
    ) async -> TouchupSpotBatch {
        let ticket = workTicket()
        return await withCheckedContinuation { continuation in
            jobQueue.async {
                guard workTicketIsCurrent(ticket) else {
                    continuation.resume(returning: TouchupSpotBatch(
                        operations: [], repaired: nil, preview: nil, spectrum: [], folderJPEG: nil, width: 0, height: 0
                    ))
                    return
                }
                continuation.resume(returning: finishSpots(
                    image: image,
                    spots: spots,
                    tone: tone,
                    displaySpaceName: displaySpaceName,
                    priorOperations: priorOperations,
                    priorToken: priorToken,
                    baseChain: baseChain,
                    frameToken: frameToken,
                    displayTurns: displayTurns,
                    flipHorizontal: flipHorizontal,
                    flipVertical: flipVertical,
                    ticket: ticket
                ))
            }
        }
    }

    private static func finishSpots(
        image: CIImage,
        spots: [(CGPoint, Int)],
        tone: ToneState,
        displaySpaceName: String,
        priorOperations: [InpaintOp],
        priorToken: Int,
        baseChain: Int,
        frameToken: Int,
        displayTurns: Int?,
        flipHorizontal: Bool,
        flipVertical: Bool,
        ticket: Int
    ) -> TouchupSpotBatch {
        guard let raster = raster(
            image: image,
            priorOperations: priorOperations,
            priorToken: priorToken,
            baseChain: baseChain,
            displayTurns: displayTurns,
            flipHorizontal: flipHorizontal,
            flipVertical: flipVertical,
            ticket: ticket
        ) else {
            return TouchupSpotBatch(
                operations: [], repaired: nil, preview: nil, spectrum: [], folderJPEG: nil, width: 0, height: 0
            )
        }
        var batch = TouchupEngine.repairClicks(
            samples: raster.samples,
            width: raster.width,
            height: raster.height,
            spots: spots
        )
        batch.operations = batch.operations.map { tag($0, frameToken: frameToken) }
        guard !batch.operations.isEmpty else {
            return TouchupSpotBatch(
                operations: [], repaired: nil, preview: nil, spectrum: [], folderJPEG: nil,
                width: raster.width, height: raster.height
            )
        }
        guard workTicketIsCurrent(ticket) else {
            return TouchupSpotBatch(
                operations: [], repaired: nil, preview: nil, spectrum: [], folderJPEG: nil,
                width: raster.width, height: raster.height
            )
        }
        var key = baseChain
        for operation in batch.operations {
            key = advance(key, operation)
        }
        storeRaster(
            RasterBuffer(
                key: key,
                samples: batch.pixels,
                width: raster.width,
                height: raster.height,
                extent: raster.extent
            ),
            ticket: ticket
        )
        let repaired = ciImage(batch.pixels, width: raster.width, height: raster.height, extent: raster.extent)
        let preview = displayImage(repaired, tone: tone, displaySpaceName: displaySpaceName)
        let spectrum = histogram(shaped: repaired, tone: tone)
        let folderJPEG = preview.flatMap { ZImgRaw.jpegPreview(from: $0, maxLongEdge: FolderPreviewCache.maxLongEdge) }
        return TouchupSpotBatch(
            operations: batch.operations,
            repaired: repaired,
            preview: preview,
            spectrum: spectrum,
            folderJPEG: folderJPEG,
            width: raster.width,
            height: raster.height
        )
    }

    /// Pixels for `baseChain`. A spot that follows another spot on the same picture does not read the frame again.
    private static func raster(
        image: CIImage,
        priorOperations: [InpaintOp],
        priorToken: Int,
        baseChain: Int,
        displayTurns: Int?,
        flipHorizontal: Bool,
        flipVertical: Bool,
        ticket: Int
    ) -> (samples: [Float], width: Int, height: Int, extent: CGRect)? {
        if let cached = cachedRaster(key: baseChain) {
            return (cached.samples, cached.width, cached.height, cached.extent)
        }
        let source = priorOperations.isEmpty
            ? image
            : InpaintPipeline.applyInteractive(
                base: image,
                operations: priorOperations,
                imageToken: priorToken,
                displayTurns: displayTurns,
                flipHorizontal: flipHorizontal,
                flipVertical: flipVertical,
                context: jobContext
            )
        guard let read = read(source, context: jobContext) else { return nil }
        storeRaster(
            RasterBuffer(
                key: baseChain,
                samples: read.samples,
                width: read.width,
                height: read.height,
                extent: read.extent
            ),
            ticket: ticket
        )
        return (read.samples, read.width, read.height, read.extent)
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
    /// Field bits are mixed directly. A JSON encoding of the same frame was not a stable identity:
    /// a finished replay then looked like a new photograph and started over.
    static func imageToken(path: String, geometry: GeometryState, crop: NormRect?) -> Int {
        var hash = 1_469_598_103_934_665_603
        func mix(_ byte: UInt8) {
            hash = (hash ^ Int(byte)) &* 1_099_511_628_211
        }
        func mixBytes(_ bytes: [UInt8]) {
            for byte in bytes { mix(byte) }
            mix(0)
        }
        func mixInt(_ value: Int) {
            var bits = UInt64(bitPattern: Int64(value))
            for _ in 0..<8 {
                mix(UInt8(truncatingIfNeeded: bits))
                bits >>= 8
            }
        }
        func mixDouble(_ value: Double) {
            var bits = value.bitPattern
            for _ in 0..<8 {
                mix(UInt8(truncatingIfNeeded: bits))
                bits >>= 8
            }
        }
        func mixPoint(_ point: NormPoint) {
            mixDouble(point.x)
            mixDouble(point.y)
        }
        mixBytes(Array(path.utf8))
        mixInt(geometry.quarterTurns)
        mix(geometry.flipHorizontal ? 1 : 0)
        mix(geometry.flipVertical ? 1 : 0)
        mixDouble(geometry.straightenDegrees)
        mixDouble(geometry.verticalKeystone)
        mixDouble(geometry.horizontalKeystone)
        mixDouble(geometry.offsetX)
        mixDouble(geometry.offsetY)
        mixDouble(geometry.sharpness)
        mixBytes(Array(geometry.lens.profileID.utf8))
        mixDouble(geometry.lens.k1)
        mixDouble(geometry.lens.k2)
        if let fov = geometry.lens.cylindricalFOV {
            mix(1)
            mixDouble(fov)
        } else {
            mix(0)
        }
        if let corners = geometry.corners {
            mix(1)
            mixPoint(corners.topLeft)
            mixPoint(corners.topRight)
            mixPoint(corners.bottomRight)
            mixPoint(corners.bottomLeft)
        } else {
            mix(0)
        }
        if let crop {
            mix(1)
            mixDouble(crop.x)
            mixDouble(crop.y)
            mixDouble(crop.width)
            mixDouble(crop.height)
        } else {
            mix(0)
        }
        return hash
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

    /// Writes the frame identity onto a patch captured while the repair was running.
    static func tag(_ operation: InpaintOp, frameToken: Int) -> InpaintOp {
        var operation = operation
        guard var patch = operation.patch else { return operation }
        patch.frameToken = frameToken
        operation.patch = patch
        return operation
    }

    /// Small before and after PNGs for the pixels that differ. A speck stays one tile. A long scratch is cut into 160 px cells.
    static func makePatch(
        before: [Float],
        after: [Float],
        width: Int,
        height: Int,
        originX: Int = 0,
        originY: Int = 0,
        rasterWidth: Int,
        rasterHeight: Int,
        strength: Double = 1
    ) -> RepairPatch? {
        guard width > 0, height > 0,
              before.count >= width * height * 4,
              after.count >= width * height * 4 else { return nil }
        let cell = 160
        let columns = max(1, (rasterWidth + cell - 1) / cell)
        struct Box {
            var minX: Int
            var minY: Int
            var maxX: Int
            var maxY: Int
        }
        var boxes: [Int: Box] = [:]
        before.withUnsafeBufferPointer { beforeBuffer in
            after.withUnsafeBufferPointer { afterBuffer in
                guard let beforeBase = beforeBuffer.baseAddress, let afterBase = afterBuffer.baseAddress else { return }
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = (y * width + x) * 4
                        if beforeBase[offset] == afterBase[offset],
                           beforeBase[offset + 1] == afterBase[offset + 1],
                           beforeBase[offset + 2] == afterBase[offset + 2],
                           beforeBase[offset + 3] == afterBase[offset + 3] {
                            continue
                        }
                        let key = ((originY + y) / cell) * columns + (originX + x) / cell
                        if var box = boxes[key] {
                            box.minX = min(box.minX, x)
                            box.minY = min(box.minY, y)
                            box.maxX = max(box.maxX, x)
                            box.maxY = max(box.maxY, y)
                            boxes[key] = box
                        } else {
                            boxes[key] = Box(minX: x, minY: y, maxX: x, maxY: y)
                        }
                    }
                }
            }
        }
        guard !boxes.isEmpty else { return nil }
        let ordered = boxes.values.sorted { lhs, rhs in
            if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
            return lhs.minX < rhs.minX
        }
        var tiles: [RepairTile] = []
        tiles.reserveCapacity(ordered.count)
        for box in ordered {
            let tileWidth = box.maxX - box.minX + 1
            let tileHeight = box.maxY - box.minY + 1
            let beforeTile = cropSamples(before, width: width, minX: box.minX, minY: box.minY, tileWidth: tileWidth, tileHeight: tileHeight)
            let afterTile = cropSamples(after, width: width, minX: box.minX, minY: box.minY, tileWidth: tileWidth, tileHeight: tileHeight)
            guard let beforePNG = encodePatchPNG(beforeTile, width: tileWidth, height: tileHeight),
                  let afterPNG = encodePatchPNG(afterTile, width: tileWidth, height: tileHeight) else { return nil }
            tiles.append(RepairTile(
                beforePNG: beforePNG,
                afterPNG: afterPNG,
                minX: originX + box.minX,
                minY: originY + box.minY,
                width: tileWidth,
                height: tileHeight
            ))
        }
        guard !tiles.isEmpty else { return nil }
        return RepairPatch(
            tiles: tiles,
            rasterWidth: rasterWidth,
            rasterHeight: rasterHeight,
            frameToken: 0,
            strength: min(1, max(0, strength))
        )
    }

    /// Pastes each repair's after picture. Nil when any repair has no picture for this frame, so the fill still runs.
    static func stampAfter(_ operations: [InpaintOp], onto base: CIImage, frameToken: Int) -> CIImage? {
        guard let repairs = stampable(operations, onto: base, frameToken: frameToken, matchStrength: true) else {
            return nil
        }
        return paste(repairs, onto: base, before: false)
    }

    /// Pastes each repair's before picture, last repair first.
    static func stampBefore(_ operations: [InpaintOp], onto base: CIImage, frameToken: Int) -> CIImage? {
        guard let repairs = stampable(operations, onto: base, frameToken: frameToken, matchStrength: false) else {
            return nil
        }
        return paste(Array(repairs.reversed()), onto: base, before: true)
    }

    private static let patchLock = NSLock()
    private static let patchContext = CIContext(options: [
        .workingColorSpace: TonePipeline.workingColorSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

    private static func stampable(
        _ operations: [InpaintOp],
        onto base: CIImage,
        frameToken: Int,
        matchStrength: Bool
    ) -> [InpaintOp]? {
        let extent = base.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        let repairs = operations.filter { !$0.maskPNG.isEmpty }
        guard !repairs.isEmpty, width > 1, height > 1 else { return nil }
        for operation in repairs {
            guard InpaintModel.isTouchup(operation.modelID),
                  let patch = operation.patch,
                  !patch.tiles.isEmpty,
                  patch.frameToken == frameToken,
                  patch.rasterWidth == width,
                  patch.rasterHeight == height else { return nil }
            if matchStrength, abs(patch.strength - operation.strength) > 0.001 { return nil }
        }
        return repairs
    }

    private static func paste(_ operations: [InpaintOp], onto base: CIImage, before: Bool) -> CIImage? {
        patchLock.lock()
        defer { patchLock.unlock() }
        guard let raster = read(base, context: patchContext) else { return nil }
        var samples = raster.samples
        for operation in operations {
            guard let patch = operation.patch else { return nil }
            for tile in patch.tiles {
                let png = before ? tile.beforePNG : tile.afterPNG
                guard let floats = decodePatchPNG(png, width: tile.width, height: tile.height),
                      tile.minX >= 0, tile.minY >= 0,
                      tile.minX + tile.width <= raster.width,
                      tile.minY + tile.height <= raster.height else { return nil }
                pasteSamples(
                    floats,
                    tileWidth: tile.width,
                    tileHeight: tile.height,
                    into: &samples,
                    imageWidth: raster.width,
                    minX: tile.minX,
                    minY: tile.minY
                )
            }
        }
        return ciImage(samples, width: raster.width, height: raster.height, extent: raster.extent)
    }

    private static func cropSamples(
        _ samples: [Float],
        width: Int,
        minX: Int,
        minY: Int,
        tileWidth: Int,
        tileHeight: Int
    ) -> [Float] {
        var tile = [Float](repeating: 0, count: tileWidth * tileHeight * 4)
        let rowCount = tileWidth * 4
        samples.withUnsafeBufferPointer { source in
            tile.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
                for row in 0..<tileHeight {
                    let src = ((minY + row) * width + minX) * 4
                    destinationBase.advanced(by: row * rowCount).update(from: sourceBase.advanced(by: src), count: rowCount)
                }
            }
        }
        return tile
    }

    private static func pasteSamples(
        _ tile: [Float],
        tileWidth: Int,
        tileHeight: Int,
        into samples: inout [Float],
        imageWidth: Int,
        minX: Int,
        minY: Int
    ) {
        let rowCount = tileWidth * 4
        tile.withUnsafeBufferPointer { source in
            samples.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
                for row in 0..<tileHeight {
                    let dst = ((minY + row) * imageWidth + minX) * 4
                    destinationBase.advanced(by: dst).update(from: sourceBase.advanced(by: row * rowCount), count: rowCount)
                }
            }
        }
    }

    /// 16-bit device RGB. The numbers are the working-space samples, so a later read does not convert them.
    private static func encodePatchPNG(_ samples: [Float], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, samples.count >= width * height * 4 else { return nil }
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height * 4) {
            let clamped = min(1, max(0, samples[index]))
            pixels[index] = UInt16((Double(clamped) * 65535).rounded())
        }
        let info = CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: width * 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info
        ), let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func decodePatchPNG(_ data: Data, width: Int, height: Int) -> [Float]? {
        guard width > 0, height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        let info = CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: width * 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.map { Float($0) / 65535 }
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
        guard let repaired = TouchupEngine.repairClick(
            samples: samples,
            width: width,
            height: height,
            bitmapPoint: bitmapPoint,
            radius: radius
        ) else { return nil }
        let pixels = TouchupEngine.install(repaired, into: samples, width: width)
        return TouchupBuilt(
            operation: InpaintOp(id: UUID(), maskPNG: repaired.maskPNG, modelID: InpaintModel.dust, featherPx: 2),
            pixels: pixels
        )
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

    /// `bitmapPoint` is top-left. The click has to land on the red of the pupil, or within a few pixels of it.
    static func redEye(
        samples: [Float],
        width: Int,
        height: Int,
        bitmapPoint: CGPoint
    ) -> TouchupBuilt? {
        guard let mask = TouchupEngine.redEyeMask(
            samples: samples,
            width: width,
            height: height,
            bitmapPoint: bitmapPoint
        ) else { return nil }
        let png = TouchupEngine.maskPNG(mask, width: width, height: height)
        guard !png.isEmpty else { return nil }
        let pixels = TouchupEngine.correctRedEye(samples: samples, mask: mask, width: width, height: height)
        return TouchupBuilt(
            operation: InpaintOp(id: UUID(), maskPNG: png, modelID: InpaintModel.redEye, featherPx: 1),
            pixels: pixels
        )
    }

    /// Turns or mirrors a repair mask so it covers the same pixels after a later rotation or flip.
    /// A mask with no recorded orientation is already on the picture it was drawn on.
    static func oriented(_ operation: InpaintOp, displayTurns: Int) -> InpaintOp {
        oriented(operation, display: GeometryState(quarterTurns: displayTurns))
    }

    static func oriented(_ operation: InpaintOp, display: GeometryState) -> InpaintOp {
        guard let captured = operation.maskQuarterTurns else { return operation }
        let fromTurns = GeometryPipeline.wrap(captured)
        let toTurns = GeometryPipeline.wrap(display.quarterTurns)
        let fromHorizontal = operation.maskFlipHorizontal ?? false
        let fromVertical = operation.maskFlipVertical ?? false
        guard fromTurns != toTurns
            || fromHorizontal != display.flipHorizontal
            || fromVertical != display.flipVertical else { return operation }
        guard !operation.maskPNG.isEmpty else { return operation }
        var png = operation.maskPNG
        if fromVertical {
            guard let flipped = TouchupEngine.flippedMaskPNG(png, horizontal: false) else { return operation }
            png = flipped
        }
        if fromHorizontal {
            guard let flipped = TouchupEngine.flippedMaskPNG(png, horizontal: true) else { return operation }
            png = flipped
        }
        let undoTurns = GeometryPipeline.wrap(-fromTurns)
        if undoTurns != 0 {
            guard let turned = TouchupEngine.rotatedMaskPNG(png, quarterTurns: undoTurns) else { return operation }
            png = turned
        }
        if toTurns != 0 {
            guard let turned = TouchupEngine.rotatedMaskPNG(png, quarterTurns: toTurns) else { return operation }
            png = turned
        }
        if display.flipHorizontal {
            guard let flipped = TouchupEngine.flippedMaskPNG(png, horizontal: true) else { return operation }
            png = flipped
        }
        if display.flipVertical {
            guard let flipped = TouchupEngine.flippedMaskPNG(png, horizontal: false) else { return operation }
            png = flipped
        }
        var oriented = operation
        oriented.maskPNG = png
        oriented.patch = nil
        oriented.maskQuarterTurns = toTurns
        oriented.maskFlipHorizontal = display.flipHorizontal
        oriented.maskFlipVertical = display.flipVertical
        return oriented
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
        } else if operation.modelID == InpaintModel.redEye {
            guard let mask = TouchupEngine.bottomMask(operation.maskPNG, width: width, height: height),
                  let painted = paintRedEye(base: base, mask: mask, context: renderContext) else {
                return base
            }
            repaired = painted
            TouchupCache.shared.store(key, repaired)
        } else if let mask = TouchupEngine.bottomMask(operation.maskPNG, width: width, height: height) {
            let scratch = operation.modelID == InpaintModel.scratch
            let patches = TouchupEngine.localPatches(mask: mask, width: width, height: height, scratch: scratch)
            if patches.isEmpty {
                return base
            } else if patches.count == 1, let patch = patches.first,
                      patch.width < width || patch.height < height {
                guard let tile = repairCrop(
                    base: base,
                    mask: mask,
                    patch: patch,
                    scratch: scratch,
                    context: renderContext
                ) else { return base }
                repaired = tile.composited(over: base).cropped(to: extent)
            } else if patches.count == 1, let raster = read(base, context: renderContext) {
                let pixels = TouchupEngine.repair(
                    samples: raster.samples,
                    mask: mask,
                    width: raster.width,
                    height: raster.height,
                    scratch: scratch
                )
                repaired = ciImage(pixels, width: raster.width, height: raster.height, extent: raster.extent)
            } else {
                let tiles = patches.map { _ in TileBox() }
                TouchupEngine.performJobs(patches.count) { index in
                    let slot = renderSlots[index % renderSlots.count]
                    slot.lock.lock()
                    let crop = readPatch(
                        base: base,
                        mask: mask,
                        patch: patches[index],
                        scratch: scratch,
                        context: slot.context
                    )
                    slot.lock.unlock()
                    guard let crop else { return }
                    tiles[index].image = paintPatch(crop)
                }
                var composed = base
                for tile in tiles {
                    guard let image = tile.image else { continue }
                    composed = image.composited(over: composed).cropped(to: extent)
                }
                repaired = composed
            }
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

    /// Several full-strength dust repairs from one read. Each speck fills on its own core. The composite is not cached as one step.
    /// `progress` receives finished patches and the patch count. Both are 0 while the photograph is still being read.
    /// Nil when `isCancelled` becomes true. The caller must not keep repairing on that result.
    static func applyDustRun(
        base: CIImage,
        operations: [InpaintOp],
        context: CIContext?,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> CIImage? {
        if isCancelled() { return nil }
        progress?(0, 0)
        let renderContext = context ?? Touchup.context
        guard let raster = read(base, context: renderContext) else {
            progress?(1, 1)
            return base
        }
        if isCancelled() { return nil }
        var masks: [[UInt8]] = []
        masks.reserveCapacity(operations.count)
        for operation in operations {
            if isCancelled() { return nil }
            if let mask = TouchupEngine.bottomMask(operation.maskPNG, width: raster.width, height: raster.height) {
                masks.append(mask)
            } else {
                masks.append([])
            }
        }
        if isCancelled() { return nil }
        guard let pixels = TouchupEngine.repairMasks(
            samples: raster.samples,
            masks: masks,
            width: raster.width,
            height: raster.height,
            scratch: false,
            isCancelled: isCancelled,
            progress: progress
        ) else {
            if isCancelled() { return nil }
            progress?(1, 1)
            return base
        }
        if isCancelled() { return nil }
        return ciImage(pixels, width: raster.width, height: raster.height, extent: raster.extent)
            .cropped(to: base.extent)
    }

    /// One repaired patch, in the base image's coordinates.
    private final class TileBox: @unchecked Sendable {
        var image: CIImage?
    }

    /// Pixels of one patch, read under that slot's context lock. The fill runs after the lock is released.
    private struct PatchRead {
        var samples: [Float]
        var width: Int
        var height: Int
        var extent: CGRect
        var mask: [UInt8]
        var scratch: Bool
    }

    /// Pulls the red out of the masked pupil. The rest of the photograph is not read.
    private static func paintRedEye(base: CIImage, mask: [UInt8], context: CIContext) -> CIImage? {
        let extent = base.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 1, height > 1,
              let patch = TouchupEngine.workPatch(mask: mask, width: width, height: height, scratch: true) else {
            return nil
        }
        let crop = CGRect(
            x: extent.minX + CGFloat(patch.minX),
            y: extent.maxY - CGFloat(patch.minY + patch.height),
            width: CGFloat(patch.width),
            height: CGFloat(patch.height)
        )
        guard let raster = read(base.cropped(to: crop), context: context),
              raster.width == patch.width, raster.height == patch.height else {
            return nil
        }
        let localMask = TouchupEngine.cropMask(mask, width: width, patch: patch)
        let pixels = TouchupEngine.correctRedEye(
            samples: raster.samples,
            mask: localMask,
            width: raster.width,
            height: raster.height
        )
        let tile = ciImage(pixels, width: raster.width, height: raster.height, extent: raster.extent)
        return tile.composited(over: base).cropped(to: extent)
    }

    private static func repairCrop(
        base: CIImage,
        mask: [UInt8],
        patch: TouchupEngine.WorkPatch,
        scratch: Bool,
        context: CIContext
    ) -> CIImage? {
        guard let crop = readPatch(base: base, mask: mask, patch: patch, scratch: scratch, context: context) else {
            return nil
        }
        return paintPatch(crop)
    }

    private static func readPatch(
        base: CIImage,
        mask: [UInt8],
        patch: TouchupEngine.WorkPatch,
        scratch: Bool,
        context: CIContext
    ) -> PatchRead? {
        let extent = base.extent.integral
        let crop = CGRect(
            x: extent.minX + CGFloat(patch.minX),
            y: extent.maxY - CGFloat(patch.minY + patch.height),
            width: CGFloat(patch.width),
            height: CGFloat(patch.height)
        )
        guard let raster = read(base.cropped(to: crop), context: context) else { return nil }
        let localMask = TouchupEngine.cropMask(mask, width: Int(extent.width), patch: patch)
        return PatchRead(
            samples: raster.samples,
            width: raster.width,
            height: raster.height,
            extent: raster.extent,
            mask: localMask,
            scratch: scratch
        )
    }

    private static func paintPatch(_ crop: PatchRead) -> CIImage? {
        let pixels = TouchupEngine.repair(
            samples: crop.samples,
            mask: crop.mask,
            width: crop.width,
            height: crop.height,
            scratch: crop.scratch
        )
        return ciImage(pixels, width: crop.width, height: crop.height, extent: crop.extent)
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
    /// Stops a patch repair from starting another `concurrentPerform` while one is already running.
    private static let depthLock = NSLock()
    private static var parallelDepth = 0

    /// Runs independent jobs on the cores. A job that is already inside one of these stays on its thread.
    static func performJobs(_ count: Int, _ body: @escaping (Int) -> Void) {
        runAcross(count: count, allowParallel: true, body: body)
    }

    /// Row passes of a large frame. A patch that is already small stays on one thread.
    private static func parallelRows(width: Int, height: Int, _ body: @escaping (Int) -> Void) {
        let large = width * height >= 256 * 256 || (height >= 64 && width >= 256)
        runAcross(count: height, allowParallel: large, body: body)
    }

    private final class ParallelJob: @unchecked Sendable {
        let body: (Int) -> Void
        init(_ body: @escaping (Int) -> Void) { self.body = body }
    }

    private static func runAcross(count: Int, allowParallel: Bool, body: @escaping (Int) -> Void) {
        guard count > 0 else { return }
        depthLock.lock()
        let nested = parallelDepth > 0
        let parallel = !nested && allowParallel && count >= 2
        if parallel { parallelDepth += 1 }
        depthLock.unlock()
        defer {
            if parallel {
                depthLock.lock()
                parallelDepth -= 1
                depthLock.unlock()
            }
        }
        if parallel {
            let job = ParallelJob(body)
            DispatchQueue.concurrentPerform(iterations: count) { index in
                job.body(index)
            }
        } else {
            for index in 0..<count {
                body(index)
            }
        }
    }

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
            response.withUnsafeMutableBufferPointer { responseBuffer in
                luma.withUnsafeBufferPointer { lumaBuffer in
                    opened.withUnsafeBufferPointer { openedBuffer in
                        closed.withUnsafeBufferPointer { closedBuffer in
                            guard let responseBase = responseBuffer.baseAddress,
                                  let lumaBase = lumaBuffer.baseAddress,
                                  let openedBase = openedBuffer.baseAddress,
                                  let closedBase = closedBuffer.baseAddress else { return }
                            let responseRaw = UInt(bitPattern: responseBase)
                            let lumaRaw = UInt(bitPattern: lumaBase)
                            let openedRaw = UInt(bitPattern: openedBase)
                            let closedRaw = UInt(bitPattern: closedBase)
                            parallelRows(width: width, height: height) { y in
                                let responsePointer = UnsafeMutablePointer<Float>(bitPattern: responseRaw)!
                                let lumaPointer = UnsafePointer<Float>(bitPattern: lumaRaw)!
                                let openedPointer = UnsafePointer<Float>(bitPattern: openedRaw)!
                                let closedPointer = UnsafePointer<Float>(bitPattern: closedRaw)!
                                let row = y * width
                                for x in 0..<width {
                                    let index = row + x
                                    let value = max(
                                        lumaPointer[index] - openedPointer[index],
                                        closedPointer[index] - lumaPointer[index]
                                    )
                                    responsePointer[index] = max(responsePointer[index], value)
                                }
                            }
                        }
                    }
                }
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
        var any = false
        for blob in kept {
            for index in blob.pixels {
                let x = index % smallW
                let y = index / smallW
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        let fx = x * factor + dx
                        let fy = y * factor + dy
                        if fx < width, fy < height {
                            stampSquare(mask: &full, width: width, height: height, x: fx, y: fy, radius: 1)
                            any = true
                        }
                    }
                }
            }
        }
        return any ? full : nil
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

    /// Flash red-eye is red with both other channels low. Skin and lips are red too, but their
    /// green and blue stay much higher, so a click on a cheek does not qualify.
    private enum RedEyeGate {
        static let minRed: Float = 0.20
        static let maxOther: Float = 0.36
        static let minRatio: Float = 1.7
        static let minGap: Float = 0.12
        static let fringeRatio: Float = 1.5
        static let fringeGap: Float = 0.08
        static let fringeOther: Float = 0.32
        /// Linear growth of the black center past the red the click found, so the fill covers the red ring.
        static let pupilScale: Float = 1.2
    }

    static func redEyeMask(
        samples: [Float],
        width: Int,
        height: Int,
        bitmapPoint: CGPoint
    ) -> [UInt8]? {
        guard width > 1, height > 1, samples.count >= width * height * 4,
              let point = rasterPoint(bitmapPoint, width: width, height: height) else {
            return nil
        }
        let grow = max(28, min(120, min(width, height) / 18))
        let snap = 18
        guard let seed = reddestPupil(
            samples: samples,
            width: width,
            height: height,
            x: point.x,
            y: point.y,
            radius: snap
        ) else { return nil }

        var mask = [UInt8](repeating: 0, count: width * height)
        var queue = [seed]
        var head = 0
        mask[seed] = 255
        var count = 1
        let seedX = seed % width
        let seedY = seed / width
        let reach = grow * grow
        let limit = min(80_000, max(400, grow * grow))
        var minX = seedX
        var maxX = seedX
        var minY = seedY
        var maxY = seedY
        while head < queue.count && count < limit {
            let current = queue[head]
            head += 1
            let x = current % width
            let y = current / width
            for step in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + step.0
                let ny = y + step.1
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let dx = nx - seedX
                let dy = ny - seedY
                if dx * dx + dy * dy > reach { continue }
                let next = ny * width + nx
                if mask[next] != 0 { continue }
                let offset = next * 4
                guard isPupilRed(samples[offset], samples[offset + 1], samples[offset + 2]) else { continue }
                mask[next] = 255
                count += 1
                queue.append(next)
                if nx < minX { minX = nx }
                if nx > maxX { maxX = nx }
                if ny < minY { minY = ny }
                if ny > maxY { maxY = ny }
            }
        }
        let boxWidth = maxX - minX + 1
        let boxHeight = maxY - minY + 1
        guard count >= 8, max(boxWidth, boxHeight) <= min(boxWidth, boxHeight) * 3 else { return nil }

        var rim = mask
        let x0 = max(0, minX - 1)
        let y0 = max(0, minY - 1)
        let x1 = min(width - 1, maxX + 1)
        let y1 = min(height - 1, maxY + 1)
        for y in y0...y1 {
            for x in x0...x1 {
                let index = y * width + x
                if mask[index] != 0 { continue }
                let dx = x - seedX
                let dy = y - seedY
                if dx * dx + dy * dy > reach { continue }
                let touches = neighborIsSet(mask, width: width, height: height, x: x, y: y)
                guard touches else { continue }
                let offset = index * 4
                guard isPupilFringe(samples[offset], samples[offset + 1], samples[offset + 2]) else { continue }
                rim[index] = 255
            }
        }
        return enlargePupil(rim, width: width, height: height)
    }

    /// Grows the black center about 20% from its centroid. Each new pixel is kept only when the
    /// mask pixel closer to the center is already set, so the shape scales and a catchlight hole stays open.
    private static func enlargePupil(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var sumX = 0
        var sumY = 0
        var count = 0
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where mask[row + x] != 0 {
                sumX += x
                sumY += y
                count += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard count > 0 else { return mask }
        let scale = RedEyeGate.pupilScale
        let centerX = Float(sumX) / Float(count)
        let centerY = Float(sumY) / Float(count)
        let span = max(maxX - minX, maxY - minY) + 1
        let pad = Int((Float(span) * (scale - 1)).rounded(.up)) + 2
        let x0 = max(0, minX - pad)
        let y0 = max(0, minY - pad)
        let x1 = min(width - 1, maxX + pad)
        let y1 = min(height - 1, maxY + pad)
        let holes = pupilHoles(mask, width: width, minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        var grown = mask
        for y in y0...y1 {
            for x in x0...x1 {
                let index = y * width + x
                if grown[index] != 0 || holes.contains(index) { continue }
                let sx = centerX + (Float(x) - centerX) / scale
                let sy = centerY + (Float(y) - centerY) / scale
                let ix = Int(sx.rounded())
                let iy = Int(sy.rounded())
                guard ix >= 0, iy >= 0, ix < width, iy < height else { continue }
                if mask[iy * width + ix] != 0 {
                    grown[index] = 255
                }
            }
        }
        return grown
    }

    /// Unset pixels inside the pupil that cannot reach the box edge. A catchlight is one of these.
    private static func pupilHoles(
        _ mask: [UInt8],
        width: Int,
        minX: Int,
        minY: Int,
        maxX: Int,
        maxY: Int
    ) -> Set<Int> {
        var seen = Set<Int>()
        var queue: [Int] = []
        func consider(_ x: Int, _ y: Int) {
            let index = y * width + x
            if mask[index] != 0 || seen.contains(index) { return }
            seen.insert(index)
            queue.append(index)
        }
        for x in minX...maxX {
            consider(x, minY)
            consider(x, maxY)
        }
        for y in minY...maxY {
            consider(minX, y)
            consider(maxX, y)
        }
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            let x = current % width
            let y = current / width
            for step in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + step.0
                let ny = y + step.1
                guard nx >= minX, ny >= minY, nx <= maxX, ny <= maxY else { continue }
                let next = ny * width + nx
                if mask[next] != 0 || seen.contains(next) { continue }
                seen.insert(next)
                queue.append(next)
            }
        }
        var holes = Set<Int>()
        for y in minY...maxY {
            let row = y * width
            for x in minX...maxX {
                let index = row + x
                if mask[index] == 0, !seen.contains(index) {
                    holes.insert(index)
                }
            }
        }
        return holes
    }

    /// The red core loses only its extra red. The ring around that core is painted with the core's
    /// dark color on every channel, so it becomes part of the black center. A catchlight is not in the mask.
    static func correctRedEye(samples: [Float], mask: [UInt8], width: Int, height: Int) -> [Float] {
        var output = samples
        let count = width * height
        guard width > 1, height > 1, mask.count >= count, samples.count >= count * 4 else { return output }
        let fill = pupilFill(samples: samples, mask: mask, width: width, height: height)
        let alpha = blurMask(mask, width: width, height: height, radius: 1)
        for index in 0..<count {
            var amount = alpha[index]
            if amount <= 0.001 { continue }
            let offset = index * 4
            let red = samples[offset]
            let green = samples[offset + 1]
            let blue = samples[offset + 2]
            let inMask = mask[index] != 0
            if inMask {
                amount = 1
            } else {
                guard isPupilFringe(red, green, blue) else { continue }
                amount = min(amount, 0.65)
            }
            if inMask, let fill, !isPupilRed(red, green, blue) {
                output[offset] = red + (fill.red - red) * amount
                output[offset + 1] = green + (fill.green - green) * amount
                output[offset + 2] = blue + (fill.blue - blue) * amount
            } else {
                let limit = min(green, blue)
                let corrected = min(red, limit)
                output[offset] = red + (corrected - red) * amount
            }
            output[offset + 3] = samples[offset + 3] == 0 ? 1 : samples[offset + 3]
        }
        return output
    }

    /// Median corrected color of the red core. Ring pixels blend toward this instead of their own green and blue.
    private static func pupilFill(
        samples: [Float],
        mask: [UInt8],
        width: Int,
        height: Int
    ) -> (red: Float, green: Float, blue: Float)? {
        var reds: [Float] = []
        var greens: [Float] = []
        var blues: [Float] = []
        let count = width * height
        for index in 0..<count where mask[index] != 0 {
            let offset = index * 4
            let red = samples[offset]
            let green = samples[offset + 1]
            let blue = samples[offset + 2]
            guard isPupilRed(red, green, blue) else { continue }
            reds.append(min(red, min(green, blue)))
            greens.append(green)
            blues.append(blue)
        }
        guard !reds.isEmpty else { return nil }
        return (medianChannel(reds), medianChannel(greens), medianChannel(blues))
    }

    private static func medianChannel(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) * 0.5
    }

    private static func isPupilRed(_ red: Float, _ green: Float, _ blue: Float) -> Bool {
        let other = max(green, blue)
        guard red > RedEyeGate.minRed, other < RedEyeGate.maxOther else { return false }
        guard red > other * RedEyeGate.minRatio else { return false }
        return red - other > RedEyeGate.minGap
    }

    private static func isPupilFringe(_ red: Float, _ green: Float, _ blue: Float) -> Bool {
        let other = max(green, blue)
        guard red > 0.15, other < RedEyeGate.fringeOther else { return false }
        guard red > other * RedEyeGate.fringeRatio else { return false }
        return red - other > RedEyeGate.fringeGap
    }

    private static func reddestPupil(
        samples: [Float],
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        radius: Int
    ) -> Int? {
        var bestIndex: Int?
        var bestScore: Float = -1
        let reach = radius * radius
        let y0 = max(0, y - radius)
        let y1 = min(height - 1, y + radius)
        let x0 = max(0, x - radius)
        let x1 = min(width - 1, x + radius)
        for row in y0...y1 {
            for column in x0...x1 {
                let dx = column - x
                let dy = row - y
                if dx * dx + dy * dy > reach { continue }
                let offset = (row * width + column) * 4
                let red = samples[offset]
                let green = samples[offset + 1]
                let blue = samples[offset + 2]
                guard isPupilRed(red, green, blue) else { continue }
                let score = (red - max(green, blue)) - Float(dx * dx + dy * dy) * 0.0008
                if score > bestScore {
                    bestScore = score
                    bestIndex = row * width + column
                }
            }
        }
        return bestIndex
    }

    private static func neighborIsSet(_ mask: [UInt8], width: Int, height: Int, x: Int, y: Int) -> Bool {
        for step in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nx = x + step.0
            let ny = y + step.1
            if nx >= 0, ny >= 0, nx < width, ny < height, mask[ny * width + nx] != 0 {
                return true
            }
        }
        return false
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

    /// The painted circle, plus a ring that grows with it. A 16 px circle stays a small patch.
    struct WorkPatch {
        var minX: Int
        var minY: Int
        var width: Int
        var height: Int
    }

    static func workPatch(mask: [UInt8], width: Int, height: Int, scratch: Bool) -> WorkPatch? {
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        var found = false
        for index in mask.indices where mask[index] != 0 {
            let x = index % width
            let y = index / width
            found = true
            if x < minX { minX = x }
            if y < minY { minY = y }
            if x > maxX { maxX = x }
            if y > maxY { maxY = y }
        }
        guard found, width > 0 else { return nil }
        let span = max(maxX - minX, maxY - minY) + 1
        let radius = max(1, span / 2)
        // Spot keeps the donor ring used by a click. Scratch only needs the feather beside the stroke.
        let margin = scratch ? 8 + radius / 5 : 40 + max(6, radius / 5)
        let x0 = max(0, minX - margin)
        let y0 = max(0, minY - margin)
        let x1 = min(width - 1, maxX + margin)
        let y1 = min(height - 1, maxY + margin)
        return WorkPatch(minX: x0, minY: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    static func cropMask(_ mask: [UInt8], width: Int, patch: WorkPatch) -> [UInt8] {
        var local = [UInt8](repeating: 0, count: patch.width * patch.height)
        for row in 0..<patch.height {
            let src = (patch.minY + row) * width + patch.minX
            let dst = row * patch.width
            local.replaceSubrange(dst..<(dst + patch.width), with: mask[src..<(src + patch.width)])
        }
        return local
    }

    /// One repaired region per dust speck, so a dozen specks fill on a dozen cores. A long scratch is cut into short pieces.
    static func localPatches(mask: [UInt8], width: Int, height: Int, scratch: Bool) -> [WorkPatch] {
        guard width > 1, height > 1, mask.count >= width * height else { return [] }
        if max(width, height) <= 256 {
            guard let patch = workPatch(mask: mask, width: width, height: height, scratch: scratch) else { return [] }
            return [patch]
        }
        let blobs = components(mask, width: width, height: height, response: [])
        guard !blobs.isEmpty else { return [] }
        let cores: [CoreRect]
        if scratch {
            var tiles: [CoreRect] = []
            for blob in blobs {
                let span = max(blob.maxX - blob.minX, blob.maxY - blob.minY) + 1
                if span > 160 {
                    tiles.append(contentsOf: scratchTiles(of: blob, width: width))
                } else {
                    tiles.append(CoreRect(minX: blob.minX, minY: blob.minY, maxX: blob.maxX, maxY: blob.maxY))
                }
            }
            cores = tiles.sorted { lhs, rhs in
                if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
                return lhs.minX < rhs.minX
            }
        } else {
            cores = blobs.map { CoreRect(minX: $0.minX, minY: $0.minY, maxX: $0.maxX, maxY: $0.maxY) }
                .sorted { lhs, rhs in
                    if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
                    return lhs.minX < rhs.minX
                }
        }
        return cores.map { expand($0, width: width, height: height, scratch: scratch) }
    }

    /// Blurs and fills each marked area on its own. Pixels outside those areas stay as they were.
    static func repair(samples: [Float], mask: [UInt8], width: Int, height: Int, scratch: Bool) -> [Float] {
        let patches = localPatches(mask: mask, width: width, height: height, scratch: scratch)
        guard let first = patches.first else { return samples }
        if patches.count == 1 {
            return repairOne(samples: samples, mask: mask, width: width, height: height, scratch: scratch, patch: first)
        }
        let boxes = patches.map { _ in RepairBox() }
        performJobs(patches.count) { index in
            let patch = patches[index]
            let localSamples = cropFloat(samples, width: width, patch: patch)
            let localMask = cropMask(mask, width: width, patch: patch)
            boxes[index].original = localSamples
            boxes[index].local = repairPixels(
                samples: localSamples,
                mask: localMask,
                width: patch.width,
                height: patch.height,
                scratch: scratch
            )
        }
        var pixels = samples
        pixels.withUnsafeMutableBufferPointer { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for index in patches.indices {
                guard let local = boxes[index].local, let original = boxes[index].original else { continue }
                pasteChanged(local, original: original, into: destinationBase, width: width, patch: patches[index])
            }
        }
        return pixels
    }

    private final class RepairBox: @unchecked Sendable {
        var local: [Float]?
        var original: [Float]?
    }

    private static func repairOne(
        samples: [Float],
        mask: [UInt8],
        width: Int,
        height: Int,
        scratch: Bool,
        patch: WorkPatch
    ) -> [Float] {
        if patch.minX == 0, patch.minY == 0, patch.width == width, patch.height == height {
            return repairPixels(samples: samples, mask: mask, width: width, height: height, scratch: scratch)
        }
        let localSamples = cropFloat(samples, width: width, patch: patch)
        let localMask = cropMask(mask, width: width, patch: patch)
        let local = repairPixels(
            samples: localSamples,
            mask: localMask,
            width: patch.width,
            height: patch.height,
            scratch: scratch
        )
        return pasteFloat(local, into: samples, width: width, patch: patch)
    }

    private struct CoreRect {
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int
    }

    /// Buckets a long stroke into 160 px cells. The cells are not joined back into one box.
    private static func scratchTiles(of blob: Blob, width: Int) -> [CoreRect] {
        let stride = width / 160 + 1
        var buckets: [Int: CoreRect] = [:]
        for index in blob.pixels {
            let x = index % width
            let y = index / width
            let key = (y / 160) * stride + (x / 160)
            if var rect = buckets[key] {
                rect.minX = min(rect.minX, x)
                rect.maxX = max(rect.maxX, x)
                rect.minY = min(rect.minY, y)
                rect.maxY = max(rect.maxY, y)
                buckets[key] = rect
            } else {
                buckets[key] = CoreRect(minX: x, minY: y, maxX: x, maxY: y)
            }
        }
        return Array(buckets.values)
    }

    private static func expand(_ core: CoreRect, width: Int, height: Int, scratch: Bool) -> WorkPatch {
        let span = max(core.maxX - core.minX, core.maxY - core.minY) + 1
        let radius = max(1, span / 2)
        let margin = scratch ? 8 + radius / 5 : 40 + max(6, radius / 5)
        let x0 = max(0, core.minX - margin)
        let y0 = max(0, core.minY - margin)
        let x1 = min(width - 1, core.maxX + margin)
        let y1 = min(height - 1, core.maxY + margin)
        return WorkPatch(minX: x0, minY: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    private static func cropFloat(_ samples: [Float], width: Int, patch: WorkPatch) -> [Float] {
        var local = [Float](repeating: 0, count: patch.width * patch.height * 4)
        let rowCount = patch.width * 4
        samples.withUnsafeBufferPointer { source in
            local.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
                for row in 0..<patch.height {
                    let src = ((patch.minY + row) * width + patch.minX) * 4
                    destinationBase.advanced(by: row * rowCount).update(from: sourceBase.advanced(by: src), count: rowCount)
                }
            }
        }
        return local
    }

    /// Writes pixels this patch actually changed, so a neighboring patch's repair survives the overlap.
    private static func pasteChanged(
        _ local: [Float],
        original: [Float],
        into destination: UnsafeMutablePointer<Float>,
        width: Int,
        patch: WorkPatch
    ) {
        let rowCount = patch.width * 4
        local.withUnsafeBufferPointer { localBuffer in
            original.withUnsafeBufferPointer { originalBuffer in
                guard let localBase = localBuffer.baseAddress, let originalBase = originalBuffer.baseAddress else { return }
                for row in 0..<patch.height {
                    let source = row * rowCount
                    let dest = ((patch.minY + row) * width + patch.minX) * 4
                    for column in 0..<rowCount where localBase[source + column] != originalBase[source + column] {
                        destination[dest + column] = localBase[source + column]
                    }
                }
            }
        }
    }

    private static func pasteFloat(_ local: [Float], into samples: [Float], width: Int, patch: WorkPatch) -> [Float] {
        var pixels = samples
        let rowCount = patch.width * 4
        local.withUnsafeBufferPointer { source in
            pixels.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
                for row in 0..<patch.height {
                    let dst = ((patch.minY + row) * width + patch.minX) * 4
                    destinationBase.advanced(by: dst).update(from: sourceBase.advanced(by: row * rowCount), count: rowCount)
                }
            }
        }
        return pixels
    }

    private static func repairPixels(samples: [Float], mask: [UInt8], width: Int, height: Int, scratch: Bool) -> [Float] {
        let hole = dilate(mask, width: width, height: height, radius: 1)
        var alpha = blurMask(mask, width: width, height: height, radius: scratch ? 3 : 1)
        if scratch {
            for index in mask.indices where mask[index] != 0 {
                alpha[index] = 1
            }
        }
        var filled = samples
        let blobs = components(hole, width: width, height: height, response: alpha)
        if scratch {
            for blob in blobs where !blob.pixels.isEmpty {
                fillScratch(
                    filled: &filled,
                    samples: samples,
                    hole: hole,
                    blob: blob,
                    width: width,
                    height: height
                )
            }
        } else {
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
            for blob in blobs where !blob.pixels.isEmpty {
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

    struct ClickRepair {
        var maskPNG: Data
        var local: [Float]
        var original: [Float]
        var patch: WorkPatch
    }

    private final class ClickBox: @unchecked Sendable {
        var repair: ClickRepair?
    }

    struct ClickBatch {
        var operations: [InpaintOp]
        var pixels: [Float]
    }

    /// The click's circle plus its donor ring. The returned pixels are that window, not a copy of the photograph.
    static func repairClick(
        samples: [Float],
        width: Int,
        height: Int,
        bitmapPoint: CGPoint,
        radius: Int
    ) -> ClickRepair? {
        let radius = max(1, radius)
        let margin = 40 + max(6, radius / 5)
        let centerX = Int(bitmapPoint.x.rounded(.down))
        let centerY = Int(bitmapPoint.y.rounded(.down))
        let minX = max(0, centerX - radius - margin)
        let maxX = min(width - 1, centerX + radius + margin)
        let minY = max(0, centerY - radius - margin)
        let maxY = min(height - 1, centerY + radius + margin)
        let patch = WorkPatch(
            minX: minX,
            minY: minY,
            width: max(1, maxX - minX + 1),
            height: max(1, maxY - minY + 1)
        )
        let localSamples: [Float]
        let localPoint: CGPoint
        if patch.width == width, patch.height == height {
            localSamples = samples
            localPoint = bitmapPoint
        } else {
            localSamples = cropFloat(samples, width: width, patch: patch)
            localPoint = CGPoint(
                x: bitmapPoint.x - CGFloat(patch.minX),
                y: bitmapPoint.y - CGFloat(patch.minY)
            )
        }
        guard let localMask = spotMask(
            samples: localSamples,
            width: patch.width,
            height: patch.height,
            bitmapPoint: localPoint,
            radius: radius
        ) else { return nil }
        let localPixels = repair(
            samples: localSamples,
            mask: localMask,
            width: patch.width,
            height: patch.height,
            scratch: false
        )
        var full = [UInt8](repeating: 0, count: width * height)
        if patch.width == width, patch.height == height {
            full = localMask
        } else {
            for row in 0..<patch.height {
                let source = row * patch.width
                let destination = (patch.minY + row) * width + patch.minX
                full.replaceSubrange(
                    destination..<(destination + patch.width),
                    with: localMask[source..<(source + patch.width)]
                )
            }
        }
        let png = maskPNG(full, width: width, height: height)
        guard !png.isEmpty else { return nil }
        return ClickRepair(maskPNG: png, local: localPixels, original: localSamples, patch: patch)
    }

    static func install(_ repair: ClickRepair, into samples: [Float], width: Int) -> [Float] {
        if repair.patch.minX == 0, repair.patch.minY == 0, repair.local.count == samples.count {
            return repair.local
        }
        return pasteFloat(repair.local, into: samples, width: width, patch: repair.patch)
    }

    /// Each click is filled from the same pixels, on its own core. Changed pixels are written in click order.
    static func repairClicks(
        samples: [Float],
        width: Int,
        height: Int,
        spots: [(CGPoint, Int)]
    ) -> ClickBatch {
        let boxes = spots.map { _ in ClickBox() }
        performJobs(spots.count) { index in
            let spot = spots[index]
            boxes[index].repair = repairClick(
                samples: samples,
                width: width,
                height: height,
                bitmapPoint: spot.0,
                radius: spot.1
            )
        }
        var pixels = samples
        var operations: [InpaintOp] = []
        operations.reserveCapacity(spots.count)
        for box in boxes {
            guard let repair = box.repair else { continue }
            let before = cropFloat(pixels, width: width, patch: repair.patch)
            pixels.withUnsafeMutableBufferPointer { destination in
                guard let base = destination.baseAddress else { return }
                pasteChanged(repair.local, original: repair.original, into: base, width: width, patch: repair.patch)
            }
            let after = cropFloat(pixels, width: width, patch: repair.patch)
            var operation = InpaintOp(id: UUID(), maskPNG: repair.maskPNG, modelID: InpaintModel.dust, featherPx: 2)
            operation.patch = Touchup.makePatch(
                before: before,
                after: after,
                width: repair.patch.width,
                height: repair.patch.height,
                originX: repair.patch.minX,
                originY: repair.patch.minY,
                rasterWidth: width,
                rasterHeight: height
            )
            operations.append(operation)
        }
        return ClickBatch(operations: operations, pixels: pixels)
    }

    /// Counts patches as they finish. The lock keeps the count right when several cores finish together.
    private final class JobCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.lock()
            value += 1
            let current = value
            lock.unlock()
            return current
        }
    }

    /// One saved dust mask per entry. Nil when none of them mark a pixel. Fills run together, then paste in order.
    /// `progress` is finished patches and the patch count. It returns immediately.
    static func repairMasks(
        samples: [Float],
        masks: [[UInt8]],
        width: Int,
        height: Int,
        scratch: Bool,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> [Float]? {
        struct Job {
            var maskIndex: Int
            var patch: WorkPatch
        }
        var jobs: [Job] = []
        for (maskIndex, mask) in masks.enumerated() where mask.count >= width * height {
            for patch in localPatches(mask: mask, width: width, height: height, scratch: scratch) {
                jobs.append(Job(maskIndex: maskIndex, patch: patch))
            }
        }
        guard !jobs.isEmpty else { return nil }
        if jobs.count == 1, let job = jobs.first {
            progress?(0, 1)
            let pixels = repairOne(
                samples: samples,
                mask: masks[job.maskIndex],
                width: width,
                height: height,
                scratch: scratch,
                patch: job.patch
            )
            progress?(1, 1)
            return pixels
        }
        let boxes = jobs.map { _ in RepairBox() }
        let counter = JobCounter()
        let jobCount = jobs.count
        progress?(0, jobCount)
        performJobs(jobCount) { index in
            if isCancelled() { return }
            let job = jobs[index]
            let localSamples = cropFloat(samples, width: width, patch: job.patch)
            let localMask = cropMask(masks[job.maskIndex], width: width, patch: job.patch)
            boxes[index].original = localSamples
            boxes[index].local = repairPixels(
                samples: localSamples,
                mask: localMask,
                width: job.patch.width,
                height: job.patch.height,
                scratch: scratch
            )
            let finished = counter.increment()
            progress?(finished, jobCount)
        }
        if isCancelled() { return nil }
        var pixels = samples
        pixels.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            for index in jobs.indices {
                guard let local = boxes[index].local, let original = boxes[index].original else { continue }
                pasteChanged(local, original: original, into: base, width: width, patch: jobs[index].patch)
            }
        }
        return pixels
    }

    /// Clockwise quarter-turns of a top-row-first gray mask. The stored repair stays in the orientation it was drawn.
    static func rotatedMaskPNG(_ png: Data, quarterTurns: Int) -> Data? {
        let turns = GeometryPipeline.wrap(quarterTurns)
        guard turns != 0 else { return png }
        guard let decoded = topDownMask(png), decoded.width > 0, decoded.height > 0 else { return nil }
        let width = decoded.width
        let height = decoded.height
        let newWidth = turns % 2 == 0 ? width : height
        let newHeight = turns % 2 == 0 ? height : width
        var source = decoded.pixels
        var destination = [UInt8](repeating: 0, count: newWidth * newHeight)
        guard source.count >= width * height, destination.count == newWidth * newHeight else { return nil }
        let error: vImage_Error = source.withUnsafeMutableBytes { sourceBuffer in
            destination.withUnsafeMutableBytes { destinationBuffer in
                guard let sourceAddress = sourceBuffer.baseAddress,
                      let destinationAddress = destinationBuffer.baseAddress else {
                    return kvImageNullPointerArgument
                }
                var sourceImage = vImage_Buffer(
                    data: sourceAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var destinationImage = vImage_Buffer(
                    data: destinationAddress,
                    height: vImagePixelCount(newHeight),
                    width: vImagePixelCount(newWidth),
                    rowBytes: newWidth
                )
                return vImageRotate90_Planar8(
                    &sourceImage,
                    &destinationImage,
                    UInt8(turns),
                    0,
                    vImage_Flags(kvImageNoFlags)
                )
            }
        }
        guard error == kvImageNoError else { return nil }
        let encoded = InpaintPipeline.encodeGrayPNG(destination, width: newWidth, height: newHeight)
        return encoded.isEmpty ? nil : encoded
    }

    /// Left/right or top/bottom of a top-row-first gray mask.
    static func flippedMaskPNG(_ png: Data, horizontal: Bool) -> Data? {
        guard let decoded = topDownMask(png), decoded.width > 0, decoded.height > 0 else { return nil }
        let width = decoded.width
        let height = decoded.height
        var source = decoded.pixels
        var destination = [UInt8](repeating: 0, count: width * height)
        guard source.count >= width * height else { return nil }
        let error: vImage_Error = source.withUnsafeMutableBytes { sourceBuffer in
            destination.withUnsafeMutableBytes { destinationBuffer in
                guard let sourceAddress = sourceBuffer.baseAddress,
                      let destinationAddress = destinationBuffer.baseAddress else {
                    return kvImageNullPointerArgument
                }
                var sourceImage = vImage_Buffer(
                    data: sourceAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var destinationImage = vImage_Buffer(
                    data: destinationAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                if horizontal {
                    return vImageHorizontalReflect_Planar8(&sourceImage, &destinationImage, vImage_Flags(kvImageNoFlags))
                }
                return vImageVerticalReflect_Planar8(&sourceImage, &destinationImage, vImage_Flags(kvImageNoFlags))
            }
        }
        guard error == kvImageNoError else { return nil }
        let encoded = InpaintPipeline.encodeGrayPNG(destination, width: width, height: height)
        return encoded.isEmpty ? nil : encoded
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
        if decoded.width == width, decoded.height == height {
            mask.withUnsafeMutableBufferPointer { destination in
                decoded.pixels.withUnsafeBufferPointer { source in
                    guard let destBase = destination.baseAddress, let sourceBase = source.baseAddress else { return }
                    for row in 0..<height {
                        let top = sourceBase.advanced(by: (height - 1 - row) * width)
                        let bottom = destBase.advanced(by: row * width)
                        for x in 0..<width {
                            bottom[x] = top[x] > 16 ? 255 : 0
                        }
                    }
                }
            }
            return mask
        }
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
        luma.withUnsafeMutableBufferPointer { lumaBuffer in
            samples.withUnsafeBufferPointer { sampleBuffer in
                guard let lumaBase = lumaBuffer.baseAddress, let sampleBase = sampleBuffer.baseAddress else { return }
                let lumaRaw = UInt(bitPattern: lumaBase)
                let sampleRaw = UInt(bitPattern: sampleBase)
                parallelRows(width: width, height: height) { y in
                    let lumaPointer = UnsafeMutablePointer<Float>(bitPattern: lumaRaw)!
                    let samplePointer = UnsafePointer<Float>(bitPattern: sampleRaw)!
                    let row = y * width
                    for x in 0..<width {
                        let offset = (row + x) * 4
                        let linear = 0.2126 * max(samplePointer[offset], 0)
                            + 0.7152 * max(samplePointer[offset + 1], 0)
                            + 0.0722 * max(samplePointer[offset + 2], 0)
                        lumaPointer[row + x] = pow(linear, 0.45)
                    }
                }
            }
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
        horizontal.withUnsafeMutableBufferPointer { horizontalBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                source.withUnsafeBufferPointer { sourceBuffer in
                    guard let horizontalBase = horizontalBuffer.baseAddress,
                          let outputBase = outputBuffer.baseAddress,
                          let sourceBase = sourceBuffer.baseAddress else { return }
                    let horizontalRaw = UInt(bitPattern: horizontalBase)
                    let outputRaw = UInt(bitPattern: outputBase)
                    let sourceRaw = UInt(bitPattern: sourceBase)
                    parallelRows(width: width, height: height) { y in
                        let horizontalPointer = UnsafeMutablePointer<Float>(bitPattern: horizontalRaw)!
                        let sourcePointer = UnsafePointer<Float>(bitPattern: sourceRaw)!
                        let row = y * width
                        for x in 0..<width {
                            var value = sourcePointer[row + x]
                            let start = max(0, x - radius)
                            let end = min(width - 1, x + radius)
                            for sample in start...end {
                                let next = sourcePointer[row + sample]
                                value = minimum ? min(value, next) : max(value, next)
                            }
                            horizontalPointer[row + x] = value
                        }
                    }
                    parallelRows(width: width, height: height) { y in
                        let horizontalPointer = UnsafePointer<Float>(bitPattern: horizontalRaw)!
                        let outputPointer = UnsafeMutablePointer<Float>(bitPattern: outputRaw)!
                        let row = y * width
                        let start = max(0, y - radius)
                        let end = min(height - 1, y + radius)
                        for x in 0..<width {
                            var value = horizontalPointer[start * width + x]
                            if end > start {
                                for sample in (start + 1)...end {
                                    let next = horizontalPointer[sample * width + x]
                                    value = minimum ? min(value, next) : max(value, next)
                                }
                            }
                            outputPointer[row + x] = value
                        }
                    }
                }
            }
        }
        return output
    }

    private static func gradientMagnitude(_ source: [Float], width: Int, height: Int) -> [Float] {
        var output = [Float](repeating: 0, count: width * height)
        guard width > 2, height > 2 else { return output }
        output.withUnsafeMutableBufferPointer { outputBuffer in
            source.withUnsafeBufferPointer { sourceBuffer in
                guard let outputBase = outputBuffer.baseAddress, let sourceBase = sourceBuffer.baseAddress else { return }
                let outputRaw = UInt(bitPattern: outputBase)
                let sourceRaw = UInt(bitPattern: sourceBase)
                parallelRows(width: width, height: height) { y in
                    guard y > 0, y < height - 1 else { return }
                    let outputPointer = UnsafeMutablePointer<Float>(bitPattern: outputRaw)!
                    let sourcePointer = UnsafePointer<Float>(bitPattern: sourceRaw)!
                    for x in 1..<(width - 1) {
                        let index = y * width + x
                        outputPointer[index] = abs(sourcePointer[index + 1] - sourcePointer[index - 1])
                            + abs(sourcePointer[index + width] - sourcePointer[index - width])
                    }
                }
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
        output.withUnsafeMutableBufferPointer { outputBuffer in
            source.withUnsafeBufferPointer { sourceBuffer in
                guard let outputBase = outputBuffer.baseAddress, let sourceBase = sourceBuffer.baseAddress else { return }
                let outputRaw = UInt(bitPattern: outputBase)
                let sourceRaw = UInt(bitPattern: sourceBase)
                parallelRows(width: smallWidth, height: smallHeight) { y in
                    let outputPointer = UnsafeMutablePointer<Float>(bitPattern: outputRaw)!
                    let sourcePointer = UnsafePointer<Float>(bitPattern: sourceRaw)!
                    for x in 0..<smallWidth {
                        var sum: Float = 0
                        var count: Float = 0
                        for dy in 0..<factor {
                            for dx in 0..<factor {
                                let sx = min(width - 1, x * factor + dx)
                                let sy = min(height - 1, y * factor + dy)
                                sum += sourcePointer[sy * width + sx]
                                count += 1
                            }
                        }
                        outputPointer[y * smallWidth + x] = sum / max(count, 1)
                    }
                }
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
        scores.withUnsafeMutableBufferPointer { scoreBuffer in
            luma.withUnsafeBufferPointer { lumaBuffer in
                blur.withUnsafeBufferPointer { blurBuffer in
                    guard let scoreBase = scoreBuffer.baseAddress,
                          let lumaBase = lumaBuffer.baseAddress,
                          let blurBase = blurBuffer.baseAddress else { return }
                    let scoreRaw = UInt(bitPattern: scoreBase)
                    let lumaRaw = UInt(bitPattern: lumaBase)
                    let blurRaw = UInt(bitPattern: blurBase)
                    parallelRows(width: width, height: height) { y in
                        guard y >= margin, y < height - margin else { return }
                        let scorePointer = UnsafeMutablePointer<Float>(bitPattern: scoreRaw)!
                        let lumaPointer = UnsafePointer<Float>(bitPattern: lumaRaw)!
                        let blurPointer = UnsafePointer<Float>(bitPattern: blurRaw)!
                        for x in margin..<(width - margin) {
                            let index = y * width + x
                            if abs(lumaPointer[index] - blurPointer[index]) < 0.035 { continue }
                            let center = lumaPointer[index]
                            var best: Float = -1
                            var second: Float = -1
                            for direction in directions {
                                let along = median3(
                                    sampleAt(lumaPointer, width: width, height: height, x: x, y: y, dx: direction.0, dy: direction.1, distance: 3),
                                    sampleAt(lumaPointer, width: width, height: height, x: x, y: y, dx: direction.0, dy: direction.1, distance: 7),
                                    sampleAt(lumaPointer, width: width, height: height, x: x, y: y, dx: -direction.0, dy: -direction.1, distance: 7)
                                )
                                let positive = median3(
                                    sampleAt(lumaPointer, width: width, height: height, x: x, y: y, dx: -direction.1, dy: direction.0, distance: 5),
                                    sampleAt(lumaPointer, width: width, height: height, x: x, y: y, dx: -direction.1, dy: direction.0, distance: 9),
                                    sampleAt(lumaPointer, width: width, height: height, x: x, y: y, dx: -direction.1, dy: direction.0, distance: 14)
                                )
                                let negative = median3(
                                    sampleAt(lumaPointer, width: width, height: height, x: x, y: y, dx: direction.1, dy: -direction.0, distance: 5),
                                    sampleAt(lumaPointer, width: width, height: height, x: x, y: y, dx: direction.1, dy: -direction.0, distance: 9),
                                    sampleAt(lumaPointer, width: width, height: height, x: x, y: y, dx: direction.1, dy: -direction.0, distance: 14)
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
                                scorePointer[index] = best
                            }
                        }
                    }
                }
            }
        }
        return scores
    }

    private static func sampleAt(
        _ luma: UnsafePointer<Float>,
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        dx: Float,
        dy: Float,
        distance: Int
    ) -> Float {
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
        var any = false
        for blob in blobs {
            for index in blob.pixels {
                any = true
                stampSquare(
                    mask: &mask,
                    width: width,
                    height: height,
                    x: index % width,
                    y: index / width,
                    radius: radius
                )
            }
        }
        return any ? mask : nil
    }

    /// Square growth, the same pixels a full-frame dilate of this radius would turn on.
    private static func stampSquare(mask: inout [UInt8], width: Int, height: Int, x: Int, y: Int, radius: Int) {
        let y0 = max(0, y - radius)
        let y1 = min(height - 1, y + radius)
        let x0 = max(0, x - radius)
        let x1 = min(width - 1, x + radius)
        for yy in y0...y1 {
            let row = yy * width
            for xx in x0...x1 {
                mask[row + xx] = 255
            }
        }
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
        horizontal.withUnsafeMutableBufferPointer { horizontalBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                source.withUnsafeBufferPointer { sourceBuffer in
                    guard let horizontalBase = horizontalBuffer.baseAddress,
                          let outputBase = outputBuffer.baseAddress,
                          let sourceBase = sourceBuffer.baseAddress else { return }
                    let horizontalRaw = UInt(bitPattern: horizontalBase)
                    let outputRaw = UInt(bitPattern: outputBase)
                    let sourceRaw = UInt(bitPattern: sourceBase)
                    parallelRows(width: width, height: height) { y in
                        let horizontalPointer = UnsafeMutablePointer<Float>(bitPattern: horizontalRaw)!
                        let sourcePointer = UnsafePointer<Float>(bitPattern: sourceRaw)!
                        let row = y * width
                        for x in 0..<width {
                            var sum: Float = 0
                            var count: Float = 0
                            for sample in max(0, x - radius)...min(width - 1, x + radius) {
                                sum += sourcePointer[row + sample]
                                count += 1
                            }
                            horizontalPointer[row + x] = sum / max(count, 1)
                        }
                    }
                    parallelRows(width: width, height: height) { y in
                        let horizontalPointer = UnsafePointer<Float>(bitPattern: horizontalRaw)!
                        let outputPointer = UnsafeMutablePointer<Float>(bitPattern: outputRaw)!
                        let row = y * width
                        let start = max(0, y - radius)
                        let end = min(height - 1, y + radius)
                        for x in 0..<width {
                            var sum: Float = 0
                            var count: Float = 0
                            for sample in start...end {
                                sum += horizontalPointer[sample * width + x]
                                count += 1
                            }
                            outputPointer[row + x] = sum / max(count, 1)
                        }
                    }
                }
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
        let bytesPerPixel = image.bitsPerPixel / 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rawCount = CFDataGetLength(raw)
        // Device-gray masks are one byte per pixel. Copy each row. A byte loop over a 1920×2560 frame is the long pause.
        if bytesPerPixel == 1, image.bytesPerRow > 0 {
            pixels.withUnsafeMutableBytes { destination in
                guard let base = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let rowBytes = image.bytesPerRow
                if rowBytes == width, rawCount >= width * height {
                    base.update(from: pointer, count: width * height)
                    return
                }
                for y in 0..<height {
                    let source = y * rowBytes
                    guard source >= 0, source + width <= rawCount else { break }
                    base.advanced(by: y * width).update(from: pointer.advanced(by: source), count: width)
                }
            }
            return (pixels, width, height)
        }
        let step = max(1, bytesPerPixel)
        for y in 0..<height {
            for x in 0..<width {
                let source = y * image.bytesPerRow + x * step
                if source < rawCount {
                    pixels[y * width + x] = pointer[source]
                }
            }
        }
        return (pixels, width, height)
    }
}
