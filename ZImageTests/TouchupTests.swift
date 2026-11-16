import CoreGraphics
import CoreImage
import XCTest
@testable import ZImager

final class TouchupTests: XCTestCase {
    func testDustLiftsASpeckAndLeavesTheCorner() {
        let width = 64
        let height = 64
        var samples = flat(width: width, height: height, value: 0.45)
        fill(rect: 30..<32, rows: 30..<32, samples: &samples, width: width, height: height, value: 0)
        let built = Touchup.dust(samples: samples, width: width, height: height)
        let repair = try? XCTUnwrap(built)
        XCTAssertNotNil(repair)
        guard let repair else { return }
        let center = index(31, 31, width: width, height: height)
        XCTAssertGreaterThan(repair.pixels[center], 0.25)
        XCTAssertEqual(repair.pixels[0], samples[0], accuracy: 0.01)
        XCTAssertEqual(repair.pixels[1], samples[1], accuracy: 0.01)
        XCTAssertEqual(repair.operation.modelID, InpaintModel.dust)
        XCTAssertEqual(EditCommand.addInpaint(repair.operation).historyTitle, "Dust")
    }

    func testDustFollowsAGradient() {
        let width = 48
        let height = 48
        var samples = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let value = 0.2 + 0.6 * Float(row) / Float(height - 1)
            for x in 0..<width {
                let offset = (row * width + x) * 4
                samples[offset] = value
                samples[offset + 1] = value
                samples[offset + 2] = value
                samples[offset + 3] = 1
            }
        }
        let speck = index(24, 24, width: width, height: height)
        samples[speck] = 0
        samples[speck + 1] = 0
        samples[speck + 2] = 0
        let before = samples[index(24, 26, width: width, height: height)]
        let built = try? XCTUnwrap(Touchup.dust(samples: samples, width: width, height: height))
        XCTAssertNotNil(built)
        guard let built else { return }
        XCTAssertEqual(built.pixels[speck], before, accuracy: 0.08)
        XCTAssertEqual(built.pixels[0], samples[0], accuracy: 0.01)
    }

    func testScratchLiftsAThinLineAndIgnoresAnEdge() {
        let width = 80
        let height = 80
        var scratched = flat(width: width, height: height, value: 0.55)
        for x in 8..<72 {
            let offset = index(x, 40, width: width, height: height)
            scratched[offset] = 0.05
            scratched[offset + 1] = 0.05
            scratched[offset + 2] = 0.05
        }
        let repair = try? XCTUnwrap(Touchup.scratches(samples: scratched, width: width, height: height))
        XCTAssertNotNil(repair)
        guard let repair else { return }
        let onLine = index(40, 40, width: width, height: height)
        XCTAssertGreaterThan(repair.pixels[onLine], 0.35)
        XCTAssertEqual(repair.pixels[0], scratched[0], accuracy: 0.01)
        XCTAssertEqual(EditCommand.addInpaint(repair.operation).historyTitle, "Scratches")

        var edge = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for x in 0..<width {
                let value: Float = x < 40 ? 0.12 : 0.82
                let offset = (row * width + x) * 4
                edge[offset] = value
                edge[offset + 1] = value
                edge[offset + 2] = value
                edge[offset + 3] = 1
            }
        }
        XCTAssertNil(Touchup.scratches(samples: edge, width: width, height: height))
    }

    func testMarkedScratchAndSpotUseTheClick() {
        let width = 72
        let height = 72
        var samples = flat(width: width, height: height, value: 0.5)
        for x in 6..<66 {
            let offset = index(x, 36, width: width, height: height)
            samples[offset] = 0.02
            samples[offset + 1] = 0.02
            samples[offset + 2] = 0.02
        }
        let marked = Touchup.markedScratch(
            samples: samples,
            width: width,
            height: height,
            from: CGPoint(x: 8, y: 36),
            to: CGPoint(x: 64, y: 36)
        )
        let repair = try? XCTUnwrap(marked)
        XCTAssertNotNil(repair)
        guard let repair else { return }
        XCTAssertGreaterThan(repair.pixels[index(36, 36, width: width, height: height)], 0.3)

        var spotSamples = flat(width: width, height: height, value: 0.48)
        fill(rect: 20..<23, rows: 18..<21, samples: &spotSamples, width: width, height: height, value: 0)
        let spot = Touchup.spot(
            samples: spotSamples,
            width: width,
            height: height,
            bitmapPoint: CGPoint(x: 21, y: 19)
        )
        XCTAssertNotNil(spot)
        XCTAssertGreaterThan(spot?.pixels[index(21, 19, width: width, height: height)] ?? 0, 0.25)
    }

    func testRedEyeClickDarkensThePupilAndLeavesTheCatchlight() throws {
        let width = 96
        let height = 96
        var samples = flat(width: width, height: height, value: 0.45)
        // Skin-like surround. Red is high, but green and blue are too high to be a pupil.
        for row in 0..<height {
            for x in 0..<width {
                let offset = index(x, row, width: width, height: height)
                samples[offset] = 0.78
                samples[offset + 1] = 0.50
                samples[offset + 2] = 0.48
            }
        }
        paintDisk(cx: 48, cy: 48, radius: 10, red: 0.72, green: 0.16, blue: 0.14, samples: &samples, width: width)
        let catchlight = index(48, 48, width: width, height: height)
        samples[catchlight] = 0.98
        samples[catchlight + 1] = 0.97
        samples[catchlight + 2] = 0.96
        // A lip-colored disk must stay red when the click is on the eye, and a click on it does nothing.
        paintDisk(cx: 12, cy: 80, radius: 6, red: 0.70, green: 0.33, blue: 0.39, samples: &samples, width: width)

        let built = try XCTUnwrap(Touchup.redEye(
            samples: samples,
            width: width,
            height: height,
            bitmapPoint: CGPoint(x: 48, y: 40)
        ))
        let pupil = index(48, 40, width: width, height: height)
        XCTAssertLessThan(built.pixels[pupil], 0.25)
        XCTAssertEqual(built.pixels[pupil + 1], samples[pupil + 1], accuracy: 0.02)
        XCTAssertGreaterThan(built.pixels[catchlight], 0.9)
        XCTAssertEqual(built.pixels[catchlight + 1], samples[catchlight + 1], accuracy: 0.02)
        // Radius 10 grown by 20% includes y=59 and y=60. Those skin pixels take the pupil's dark color.
        let ring = index(48, 59, width: width, height: height)
        XCTAssertLessThan(built.pixels[ring], 0.25)
        XCTAssertLessThan(built.pixels[ring + 1], 0.30)
        let ringEdge = index(48, 60, width: width, height: height)
        XCTAssertLessThan(built.pixels[ringEdge], 0.25)
        let outside = index(48, 62, width: width, height: height)
        XCTAssertGreaterThan(built.pixels[outside], 0.7)
        let lip = index(12, 80, width: width, height: height)
        XCTAssertEqual(built.pixels[lip], samples[lip], accuracy: 0.02)
        let corner = index(90, 8, width: width, height: height)
        XCTAssertEqual(built.pixels[corner], samples[corner], accuracy: 0.02)
        XCTAssertEqual(built.operation.modelID, InpaintModel.redEye)
        XCTAssertEqual(EditCommand.addInpaint(built.operation).historyTitle, "Red eye")
        XCTAssertFalse(InpaintModel.needsLama(InpaintModel.redEye))

        let missed = Touchup.redEye(
            samples: samples,
            width: width,
            height: height,
            bitmapPoint: CGPoint(x: 12, y: 80)
        )
        XCTAssertNil(missed)

        let beside = try XCTUnwrap(Touchup.redEye(
            samples: samples,
            width: width,
            height: height,
            bitmapPoint: CGPoint(x: 48, y: 64)
        ))
        XCTAssertLessThan(beside.pixels[pupil], 0.25)

        let image = Touchup.ciImage(
            samples,
            width: width,
            height: height,
            extent: CGRect(x: 0, y: 0, width: width, height: height)
        )
        let applied = Touchup.apply(base: image, operation: built.operation, chain: 1)
        let read = try XCTUnwrap(Touchup.read(applied))
        let replayed = index(48, 40, width: read.width, height: read.height)
        XCTAssertLessThan(read.samples[replayed], 0.3)
        XCTAssertGreaterThan(read.samples[index(48, 48, width: read.width, height: read.height)], 0.9)
        XCTAssertLessThan(read.samples[index(48, 59, width: read.width, height: read.height)], 0.35)
        XCTAssertGreaterThan(read.samples[index(48, 62, width: read.width, height: read.height)], 0.7)
    }

    func testScratchContinuesBothSidesWithoutPaintingAColumn() {
        let width = 120
        let height = 90
        var samples = flat(width: width, height: height, value: 0.42)
        fill(rect: 15..<105, rows: 44..<48, samples: &samples, width: width, height: height, value: 0.05)
        let spike = index(60, 31, width: width, height: height)
        samples[spike] = 1
        samples[spike + 1] = 1
        samples[spike + 2] = 1
        let repaired = Touchup.markedScratch(
            samples: samples,
            width: width,
            height: height,
            from: CGPoint(x: 20, y: 44),
            to: CGPoint(x: 100, y: 44),
            radius: 12
        )
        XCTAssertGreaterThan(repaired?.pixels[index(60, 44, width: width, height: height)] ?? 0, 0.3)
        var bright = 0
        for y in 32..<56 {
            let value = repaired?.pixels[index(60, y, width: width, height: height)] ?? 0
            if value > 0.7 { bright += 1 }
        }
        XCTAssertLessThan(bright, 3)
        XCTAssertEqual(repaired?.pixels[index(4, 4, width: width, height: height)] ?? 0, 0.42, accuracy: 0.02)
    }

    func testMarkedScratchBlendsTheWholeBrush() {
        let width = 160
        let height = 100
        var samples = flat(width: width, height: height, value: 0.62)
        fill(rect: 8..<150, rows: 46..<55, samples: &samples, width: width, height: height, value: 0.04)
        let repaired = Touchup.markedScratch(
            samples: samples,
            width: width,
            height: height,
            from: CGPoint(x: 20, y: 50),
            to: CGPoint(x: 140, y: 50),
            radius: 30
        )
        XCTAssertGreaterThan(repaired?.pixels[index(80, 50, width: width, height: height)] ?? 0, 0.4)
        XCTAssertEqual(repaired?.pixels[index(4, 4, width: width, height: height)] ?? 0, 0.62, accuracy: 0.02)
    }

    /// Size slider of 16 px is a circle 16 px across, so the repair radius is 8.
    func testSixteenPixelCircleReplaysInsideItsNeighborhood() throws {
        let width = 800
        let height = 600
        var samples = flat(width: width, height: height, value: 0.55)
        fill(rect: 398..<403, rows: 298..<303, samples: &samples, width: width, height: height, value: 0.02)
        let built = try XCTUnwrap(Touchup.spot(
            samples: samples,
            width: width,
            height: height,
            bitmapPoint: CGPoint(x: 400, y: 300),
            radius: 8
        ))
        let image = Touchup.ciImage(
            samples,
            width: width,
            height: height,
            extent: CGRect(x: 0, y: 0, width: width, height: height)
        )
        let output = Touchup.apply(base: image, operation: built.operation, chain: 1)
        XCTAssertEqual(output.extent.integral.width, CGFloat(width))
        XCTAssertEqual(output.extent.integral.height, CGFloat(height))
        let read = try XCTUnwrap(Touchup.read(output))
        let center = index(400, 300, width: width, height: height)
        XCTAssertEqual(read.samples[center], built.pixels[center], accuracy: 0.02)
        XCTAssertGreaterThan(read.samples[center], 0.25)
        XCTAssertEqual(read.samples[index(4, 4, width: width, height: height)], 0.55, accuracy: 0.02)
        XCTAssertEqual(read.samples[index(790, 590, width: width, height: height)], 0.55, accuracy: 0.02)
    }

    func testSpotOnAWideFrameRepairsTheSpeckAndLeavesTheCorner() {
        let width = 400
        let height = 300
        var samples = flat(width: width, height: height, value: 0.55)
        fill(rect: 198..<203, rows: 148..<153, samples: &samples, width: width, height: height, value: 0.02)
        let repaired = Touchup.spot(
            samples: samples,
            width: width,
            height: height,
            bitmapPoint: CGPoint(x: 200, y: 150),
            radius: 16
        )
        XCTAssertGreaterThan(repaired?.pixels[index(200, 150, width: width, height: height)] ?? 0, 0.25)
        XCTAssertEqual(repaired?.pixels[index(4, 4, width: width, height: height)] ?? 0, 0.55, accuracy: 0.02)
        XCTAssertEqual(repaired?.pixels[index(390, 290, width: width, height: height)] ?? 0, 0.55, accuracy: 0.02)
    }

    func testLargeSpotNeedsACircleThatReachesTheSurroundings() {
        let width = 80
        let height = 80
        var samples = flat(width: width, height: height, value: 0.55)
        fill(rect: 28..<52, rows: 28..<52, samples: &samples, width: width, height: height, value: 0.05)
        let click = CGPoint(x: 40, y: 40)
        XCTAssertNil(Touchup.spot(samples: samples, width: width, height: height, bitmapPoint: click, radius: 6))
        let repaired = Touchup.spot(samples: samples, width: width, height: height, bitmapPoint: click, radius: 28)
        XCTAssertGreaterThan(repaired?.pixels[index(40, 40, width: width, height: height)] ?? 0, 0.3)
        XCTAssertEqual(repaired?.pixels[index(4, 4, width: width, height: height)] ?? 0, 0.55, accuracy: 0.02)
    }

    func testStrengthZeroLeavesThePhotoAndDustExportDoesNotNeedLaMa() throws {
        let width = 32
        let height = 32
        var samples = flat(width: width, height: height, value: 0.4)
        fill(rect: 14..<17, rows: 14..<17, samples: &samples, width: width, height: height, value: 0)
        let built = try XCTUnwrap(Touchup.dust(samples: samples, width: width, height: height))
        var faded = built.operation
        faded.strength = 0
        let image = Touchup.ciImage(samples, width: width, height: height, extent: CGRect(x: 0, y: 0, width: width, height: height))
        let output = InpaintPipeline.applyInteractive(base: image, operations: [faded])
        let read = try XCTUnwrap(Touchup.read(output))
        XCTAssertEqual(read.samples[0], samples[0], accuracy: 0.001)
        let center = index(15, 15, width: width, height: height)
        XCTAssertEqual(read.samples[center], samples[center], accuracy: 0.001)

        var state = EditState.identity
        state.inpaints = [built.operation]
        XCTAssertNoThrow(try InpaintPipeline.validateForExport(state))
        XCTAssertEqual(
            EditCommand.setInpaintStrength(id: built.operation.id, strength: 0.5, label: "Dust amount").historyTitle,
            "Dust amount"
        )
    }

    func testSpotQueueHoldsSixtyFourAndCountsSpotsLeft() {
        var queue = TouchupQueue()
        XCTAssertTrue(queue.add(QueuedTouchup(banner: "Removing the spot…", empty: "empty", work: .spot(.zero, 8))))
        for index in 1..<TouchupQueue.cap {
            let job = QueuedTouchup(
                banner: "Removing the spot…",
                empty: "empty",
                work: .spot(CGPoint(x: index, y: 1), 8)
            )
            XCTAssertTrue(queue.add(job))
        }
        XCTAssertFalse(queue.add(QueuedTouchup(banner: "Removing the spot…", empty: "empty", work: .spot(.zero, 8))))
        XCTAssertEqual(queue.count, TouchupQueue.cap)
        XCTAssertEqual(queue.spotsRemaining, TouchupQueue.cap)
        XCTAssertNotNil(queue.finishRunning())
        XCTAssertEqual(queue.spotsRemaining, TouchupQueue.cap - 1)
        XCTAssertTrue(queue.add(QueuedTouchup(banner: "Removing the scratch…", empty: "empty", work: .scratch([.zero, CGPoint(x: 3, y: 3)], 8))))
        XCTAssertEqual(queue.count, TouchupQueue.cap)
        XCTAssertEqual(queue.spotsRemaining, TouchupQueue.cap - 1)
        XCTAssertFalse(queue.add(QueuedTouchup(banner: "Removing dust…", empty: "empty", work: .dust)))
    }

    func testSpotQueueIgnoresARunningScratch() {
        var queue = TouchupQueue()
        XCTAssertTrue(queue.add(QueuedTouchup(banner: "Removing scratches…", empty: "empty", work: .scratches)))
        XCTAssertTrue(queue.add(QueuedTouchup(banner: "Removing the spot…", empty: "empty", work: .spot(.zero, 4))))
        XCTAssertEqual(queue.spotsRemaining, 1)
        XCTAssertEqual(queue.count, 2)
        XCTAssertTrue(queue.takeLeadingSpots().isEmpty)
        XCTAssertEqual(queue.spotsRemaining, 1)
        XCTAssertEqual(queue.count, 2)
    }

    func testSpotQueueBatchesLeadingSpotsAndStopsAtAScratch() {
        var queue = TouchupQueue()
        XCTAssertTrue(queue.add(QueuedTouchup(banner: "Removing the spot…", empty: "empty", work: .spot(.zero, 8))))
        for index in 1..<12 {
            XCTAssertTrue(queue.add(QueuedTouchup(
                banner: "Removing the spot…",
                empty: "empty",
                work: .spot(CGPoint(x: index * 20, y: 30), 8)
            )))
        }
        XCTAssertTrue(queue.add(QueuedTouchup(
            banner: "Removing the scratch…",
            empty: "empty",
            work: .scratch([.zero, CGPoint(x: 8, y: 8)], 6)
        )))
        XCTAssertEqual(queue.spotsRemaining, 12)
        XCTAssertEqual(queue.count, 13)
        let batch = queue.takeLeadingSpots()
        XCTAssertEqual(batch.count, 12)
        XCTAssertEqual(queue.spotsRemaining, 12)
        XCTAssertEqual(queue.count, 13)
        XCTAssertEqual(queue.waiting.count, 1)
        XCTAssertTrue(queue.add(QueuedTouchup(banner: "Removing the spot…", empty: "empty", work: .spot(CGPoint(x: 9, y: 9), 8))))
        XCTAssertEqual(queue.spotsRemaining, 13)
        let next = queue.finishRunning()
        XCTAssertEqual(queue.spotsRemaining, 1)
        XCTAssertEqual(queue.count, 2)
        guard let next else {
            XCTFail("The scratch should be the job that runs after the spots")
            return
        }
        guard case .scratch(_, _) = next.work else {
            XCTFail("The scratch should be the job that runs after the spots")
            return
        }
    }

    /// Undo of the latest spot must get the picture from before that spot, not the one after it.
    func testUndoPictureRestoresTheSpotBeforeTheLatest() {
        var pictures = TouchupPictures(cap: 6)
        let earlierOps = [spotOperation(1)]
        let laterOps = earlierOps + [spotOperation(2)]
        let earlier = TouchupShown(
            token: 7,
            operations: earlierOps,
            image: solid(0.2, width: 8),
            tone: .identity,
            preview: onePixel(),
            spectrum: [1]
        )
        let later = TouchupShown(
            token: 7,
            operations: laterOps,
            image: solid(0.8, width: 12),
            tone: .identity,
            preview: onePixel(),
            spectrum: [2]
        )
        pictures.remember(earlier)
        pictures.remember(later)
        let restored = pictures.frame(token: 7, operations: earlierOps)
        XCTAssertEqual(restored?.image?.extent.width, 8)
        XCTAssertEqual(restored?.spectrum, [1])
        XCTAssertEqual(pictures.frame(token: 7, operations: laterOps)?.image?.extent.width, 12)

        let screenOnly = TouchupShown(
            token: 7,
            operations: earlierOps,
            image: nil,
            tone: .identity,
            preview: onePixel(),
            spectrum: [3]
        )
        pictures.remember(screenOnly)
        XCTAssertEqual(pictures.frame(token: 7, operations: earlierOps)?.image?.extent.width, 8)
        XCTAssertEqual(pictures.frame(token: 7, operations: earlierOps)?.spectrum, [3])
        XCTAssertEqual(pictures.count, 2)
    }

    func testUndoPictureDropsTheOldestWhenTheListIsFull() {
        var pictures = TouchupPictures(cap: 2)
        pictures.remember(shown(ops: [spotOperation(1)], width: 4))
        pictures.remember(shown(ops: [spotOperation(1), spotOperation(2)], width: 5))
        pictures.remember(shown(ops: [spotOperation(1), spotOperation(2), spotOperation(3)], width: 6))
        XCTAssertEqual(pictures.count, 2)
        XCTAssertNil(pictures.frame(token: 1, operations: [spotOperation(1)]))
        XCTAssertEqual(
            pictures.frame(token: 1, operations: [spotOperation(1), spotOperation(2), spotOperation(3)])?.image?.extent.width,
            6
        )
    }

    func testDustReplayProgressCountsFinishedRepairs() {
        let reading = TouchupReplayScale.measure(doneBefore: 0, runCount: 30, jobDone: 0, jobTotal: 0, total: 30)
        XCTAssertEqual(reading.done, 0)
        XCTAssertEqual(reading.fraction, 0, accuracy: 0.0001)

        let tenth = TouchupReplayScale.measure(doneBefore: 0, runCount: 30, jobDone: 10, jobTotal: 30, total: 30)
        XCTAssertEqual(tenth.done, 10)
        XCTAssertEqual(tenth.fraction, 10.0 / 30.0, accuracy: 0.0001)

        let almost = TouchupReplayScale.measure(doneBefore: 0, runCount: 30, jobDone: 29, jobTotal: 30, total: 30)
        XCTAssertEqual(almost.done, 29)

        let finished = TouchupReplayScale.measure(doneBefore: 0, runCount: 30, jobDone: 30, jobTotal: 30, total: 30)
        XCTAssertEqual(finished.done, 30)
        XCTAssertEqual(finished.fraction, 1, accuracy: 0.0001)

        let split = TouchupReplayScale.measure(doneBefore: 4, runCount: 8, jobDone: 1, jobTotal: 4, total: 12)
        XCTAssertEqual(split.done, 6)
        XCTAssertEqual(split.fraction, 0.5, accuracy: 0.0001)

        let halfSpot = TouchupReplayScale.measure(doneBefore: 0, runCount: 30, jobDone: 1, jobTotal: 60, total: 30)
        XCTAssertEqual(halfSpot.done, 0)
        XCTAssertGreaterThan(halfSpot.fraction, 0)

        let capped = TouchupReplayScale.measure(doneBefore: 28, runCount: 4, jobDone: 4, jobTotal: 4, total: 30)
        XCTAssertEqual(capped.done, 30)
        XCTAssertEqual(capped.fraction, 1, accuracy: 0.0001)
    }

    func testMissingStrengthDecodesAsFull() throws {
        let operation = InpaintOp(id: UUID(), maskPNG: Data([9]), modelID: InpaintModel.scratch, featherPx: 2, strength: 0.25)
        let encoded = try JSONEncoder().encode(operation)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "strength")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(InpaintOp.self, from: stripped)
        XCTAssertEqual(decoded.strength, 1)
        XCTAssertEqual(decoded.modelID, InpaintModel.scratch)
    }

    /// Two specks far apart on a frame larger than 256 px. Each is repaired, and the middle stays put.
    func testDustRepairsSeparatedSpecksOnAWideFrame() throws {
        let width = 800
        let height = 600
        var samples = flat(width: width, height: height, value: 0.55)
        fill(rect: 48..<52, rows: 48..<52, samples: &samples, width: width, height: height, value: 0.02)
        fill(rect: 700..<704, rows: 500..<504, samples: &samples, width: width, height: height, value: 0.02)
        let built = try XCTUnwrap(Touchup.dust(samples: samples, width: width, height: height))
        let near = index(50, 50, width: width, height: height)
        let farSpeck = index(702, 502, width: width, height: height)
        let middle = index(400, 300, width: width, height: height)
        XCTAssertGreaterThan(built.pixels[near], 0.25)
        XCTAssertGreaterThan(built.pixels[farSpeck], 0.25)
        XCTAssertEqual(built.pixels[middle], 0.55, accuracy: 0.02)
        XCTAssertEqual(built.pixels[index(790, 20, width: width, height: height)], 0.55, accuracy: 0.02)
        let image = Touchup.ciImage(
            samples,
            width: width,
            height: height,
            extent: CGRect(x: 0, y: 0, width: width, height: height)
        )
        let output = Touchup.apply(base: image, operation: built.operation, chain: 11)
        let read = try XCTUnwrap(Touchup.read(output))
        XCTAssertEqual(read.samples[near], built.pixels[near], accuracy: 0.02)
        XCTAssertEqual(read.samples[farSpeck], built.pixels[farSpeck], accuracy: 0.02)
        XCTAssertEqual(read.samples[middle], 0.55, accuracy: 0.02)
        XCTAssertEqual(output.extent.integral.width, CGFloat(width))
        XCTAssertEqual(output.extent.integral.height, CGFloat(height))
    }

    /// A stroke longer than one tile. The middle and both ends lift, and a corner stays the original gray.
    func testLongMarkedScratchRepairsEachPiece() throws {
        let width = 640
        let height = 240
        var samples = flat(width: width, height: height, value: 0.5)
        for x in 16..<624 {
            let offset = index(x, 120, width: width, height: height)
            samples[offset] = 0.02
            samples[offset + 1] = 0.02
            samples[offset + 2] = 0.02
        }
        let built = try XCTUnwrap(Touchup.markedScratch(
            samples: samples,
            width: width,
            height: height,
            from: CGPoint(x: 20, y: 120),
            to: CGPoint(x: 620, y: 120),
            radius: 6
        ))
        XCTAssertGreaterThan(built.pixels[index(80, 120, width: width, height: height)], 0.3)
        XCTAssertGreaterThan(built.pixels[index(320, 120, width: width, height: height)], 0.3)
        XCTAssertGreaterThan(built.pixels[index(560, 120, width: width, height: height)], 0.3)
        XCTAssertEqual(built.pixels[index(8, 8, width: width, height: height)], 0.5, accuracy: 0.02)
        let image = Touchup.ciImage(
            samples,
            width: width,
            height: height,
            extent: CGRect(x: 0, y: 0, width: width, height: height)
        )
        let output = Touchup.apply(base: image, operation: built.operation, chain: 12)
        let read = try XCTUnwrap(Touchup.read(output))
        let middle = index(320, 120, width: width, height: height)
        XCTAssertEqual(read.samples[middle], built.pixels[middle], accuracy: 0.02)
        XCTAssertEqual(read.samples[index(8, 8, width: width, height: height)], 0.5, accuracy: 0.02)
        XCTAssertGreaterThan(read.samples[index(80, 120, width: width, height: height)], 0.3)
        XCTAssertGreaterThan(read.samples[index(560, 120, width: width, height: height)], 0.3)
    }

    /// Twelve specks far enough apart that each repair is its own patch. Replaying them together matches repairing each one.
    func testADozenSpotsRepairTogether() throws {
        let width = 800
        let height = 600
        var samples = flat(width: width, height: height, value: 0.55)
        var points: [CGPoint] = []
        for row in 0..<3 {
            for column in 0..<4 {
                let x = 80 + column * 200
                let y = 80 + row * 220
                points.append(CGPoint(x: x, y: y))
                fill(rect: (x - 2)..<(x + 2), rows: (y - 2)..<(y + 2), samples: &samples, width: width, height: height, value: 0.02)
            }
        }
        var operations: [InpaintOp] = []
        var centers: [Int] = []
        var expected: [Float] = []
        for point in points {
            let built = try XCTUnwrap(Touchup.spot(
                samples: samples,
                width: width,
                height: height,
                bitmapPoint: point,
                radius: 8
            ))
            operations.append(built.operation)
            let center = index(Int(point.x), Int(point.y), width: width, height: height)
            centers.append(center)
            expected.append(built.pixels[center])
            XCTAssertGreaterThan(built.pixels[center], 0.25)
        }
        let image = Touchup.ciImage(
            samples,
            width: width,
            height: height,
            extent: CGRect(x: 0, y: 0, width: width, height: height)
        )
        let output = InpaintPipeline.applyInteractive(base: image, operations: operations, imageToken: 12)
        let read = try XCTUnwrap(Touchup.read(output))
        for index in centers.indices {
            XCTAssertEqual(read.samples[centers[index]], expected[index], accuracy: 0.02)
            XCTAssertGreaterThan(read.samples[centers[index]], 0.25)
        }
        XCTAssertEqual(read.samples[self.index(4, 4, width: width, height: height)], 0.55, accuracy: 0.02)
        XCTAssertEqual(read.samples[self.index(790, 20, width: width, height: height)], 0.55, accuracy: 0.02)
        XCTAssertEqual(output.extent.integral.width, CGFloat(width))
        XCTAssertEqual(output.extent.integral.height, CGFloat(height))
    }

    /// A faded repair stays between the photograph and the full fill, including when a full spot sits beside it.
    func testFadedDustStaysBetweenThePhotoAndTheRepair() throws {
        let width = 800
        let height = 400
        var samples = flat(width: width, height: height, value: 0.55)
        fill(rect: 98..<102, rows: 198..<202, samples: &samples, width: width, height: height, value: 0.02)
        fill(rect: 698..<702, rows: 198..<202, samples: &samples, width: width, height: height, value: 0.02)
        let first = try XCTUnwrap(Touchup.spot(
            samples: samples, width: width, height: height, bitmapPoint: CGPoint(x: 100, y: 200), radius: 8
        ))
        let second = try XCTUnwrap(Touchup.spot(
            samples: samples, width: width, height: height, bitmapPoint: CGPoint(x: 700, y: 200), radius: 8
        ))
        var faded = second.operation
        faded.strength = 0.5
        let image = Touchup.ciImage(
            samples,
            width: width,
            height: height,
            extent: CGRect(x: 0, y: 0, width: width, height: height)
        )
        let output = InpaintPipeline.applyInteractive(base: image, operations: [first.operation, faded], imageToken: 4)
        let read = try XCTUnwrap(Touchup.read(output))
        let near = index(100, 200, width: width, height: height)
        let far = index(700, 200, width: width, height: height)
        XCTAssertEqual(read.samples[near], first.pixels[near], accuracy: 0.02)
        XCTAssertGreaterThan(read.samples[far], samples[far] + 0.05)
        XCTAssertGreaterThan(second.pixels[far] - read.samples[far], 0.08)
    }

    func testUndoPastesTheSmallPatchAndLeavesTheRest() throws {
        let width = 32
        let height = 24
        let before = flat(width: width, height: height, value: 0.2)
        var first = before
        let near = index(4, 2, width: width, height: height)
        first[near] = 0.85
        first[near + 1] = 0.15
        first[near + 2] = 0.4
        var second = first
        let far = index(20, 18, width: width, height: height)
        second[far] = 0.05
        second[far + 1] = 0.7
        second[far + 2] = 0.9
        var firstPatch = try XCTUnwrap(Touchup.makePatch(
            before: before,
            after: first,
            width: width,
            height: height,
            rasterWidth: width,
            rasterHeight: height
        ))
        var secondPatch = try XCTUnwrap(Touchup.makePatch(
            before: first,
            after: second,
            width: width,
            height: height,
            rasterWidth: width,
            rasterHeight: height
        ))
        XCTAssertEqual(firstPatch.tiles.count, 1)
        XCTAssertEqual(firstPatch.tiles[0].minX, 4)
        XCTAssertEqual(firstPatch.tiles[0].minY, 2)
        XCTAssertEqual(firstPatch.tiles[0].width, 1)
        XCTAssertEqual(firstPatch.tiles[0].height, 1)
        XCTAssertEqual(secondPatch.tiles[0].minX, 20)
        XCTAssertEqual(secondPatch.tiles[0].minY, 18)
        firstPatch.frameToken = 11
        secondPatch.frameToken = 11
        let firstOp = InpaintOp(
            id: UUID(),
            maskPNG: Data([1]),
            modelID: InpaintModel.dust,
            featherPx: 2,
            patch: firstPatch
        )
        let secondOp = InpaintOp(
            id: UUID(),
            maskPNG: Data([2]),
            modelID: InpaintModel.dust,
            featherPx: 2,
            patch: secondPatch
        )
        let base = Touchup.ciImage(
            before,
            width: width,
            height: height,
            extent: CGRect(x: 0, y: 0, width: width, height: height)
        )
        let both = try XCTUnwrap(Touchup.stampAfter([firstOp, secondOp], onto: base, frameToken: 11))
        let bothRead = try XCTUnwrap(Touchup.read(both))
        XCTAssertEqual(bothRead.samples[near], 0.85, accuracy: 0.02)
        XCTAssertEqual(bothRead.samples[near + 1], 0.15, accuracy: 0.02)
        XCTAssertEqual(bothRead.samples[far], 0.05, accuracy: 0.02)
        XCTAssertEqual(bothRead.samples[0], 0.2, accuracy: 0.02)
        let undone = try XCTUnwrap(Touchup.stampBefore([secondOp], onto: both, frameToken: 11))
        let undoneRead = try XCTUnwrap(Touchup.read(undone))
        XCTAssertEqual(undoneRead.samples[near], 0.85, accuracy: 0.02)
        XCTAssertEqual(undoneRead.samples[far], 0.2, accuracy: 0.02)
        XCTAssertEqual(undoneRead.samples[0], 0.2, accuracy: 0.02)
        let cleared = try XCTUnwrap(Touchup.stampBefore([firstOp], onto: undone, frameToken: 11))
        let clearedRead = try XCTUnwrap(Touchup.read(cleared))
        XCTAssertEqual(clearedRead.samples[near], 0.2, accuracy: 0.02)
        XCTAssertNil(Touchup.stampAfter([firstOp], onto: base, frameToken: 99))
        let bare = InpaintOp(id: UUID(), maskPNG: Data([1]), modelID: InpaintModel.dust, featherPx: 2)
        XCTAssertNil(Touchup.stampAfter([bare], onto: base, frameToken: 11))
        let encoded = try JSONEncoder().encode(EditCommand.addInpaint(firstOp))
        let decoded = try JSONDecoder().decode(EditCommand.self, from: encoded)
        guard case .addInpaint(let roundTrip) = decoded else {
            XCTFail("Expected the repair")
            return
        }
        XCTAssertEqual(roundTrip.patch?.tiles.count, 1)
        XCTAssertEqual(roundTrip.patch?.tiles[0].minX, 4)
        XCTAssertEqual(roundTrip.patch?.frameToken, 11)
        let old = try JSONEncoder().encode(bare)
        let oldText = String(data: old, encoding: .utf8) ?? ""
        XCTAssertFalse(oldText.contains("\"patch\""))
        let oldDecoded = try JSONDecoder().decode(InpaintOp.self, from: old)
        XCTAssertNil(oldDecoded.patch)
    }

    func testAWideChangeKeepsSeparateSmallPictures() throws {
        let width = 400
        let height = 40
        let before = flat(width: width, height: height, value: 0.3)
        var after = before
        let left = index(2, 3, width: width, height: height)
        let right = index(320, 8, width: width, height: height)
        after[left] = 0.9
        after[right] = 0.1
        let patch = try XCTUnwrap(Touchup.makePatch(
            before: before,
            after: after,
            width: width,
            height: height,
            rasterWidth: width,
            rasterHeight: height
        ))
        XCTAssertEqual(patch.tiles.count, 2)
        XCTAssertEqual(patch.tiles[0].minX, 2)
        XCTAssertEqual(patch.tiles[0].minY, 3)
        XCTAssertEqual(patch.tiles[0].width, 1)
        XCTAssertEqual(patch.tiles[0].height, 1)
        XCTAssertEqual(patch.tiles[1].minX, 320)
        XCTAssertEqual(patch.tiles[1].minY, 8)
        XCTAssertEqual(patch.tiles[1].width, 1)
        XCTAssertEqual(patch.tiles[1].height, 1)
    }

    private func spotOperation(_ mark: Int) -> InpaintOp {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", mark))!
        return InpaintOp(id: id, maskPNG: Data([UInt8(mark)]), modelID: InpaintModel.dust, featherPx: 2)
    }

    private func solid(_ value: CGFloat, width: Int) -> CIImage {
        CIImage(color: CIColor(red: value, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: width))
    }

    private func onePixel() -> CGImage {
        let bytes: [UInt8] = [0, 0, 0, 255]
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func shown(ops: [InpaintOp], width: Int) -> TouchupShown {
        TouchupShown(
            token: 1,
            operations: ops,
            image: solid(0.4, width: width),
            tone: .identity,
            preview: onePixel(),
            spectrum: []
        )
    }

    private func flat(width: Int, height: Int, value: Float) -> [Float] {
        var samples = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            samples[index * 4] = value
            samples[index * 4 + 1] = value
            samples[index * 4 + 2] = value
            samples[index * 4 + 3] = 1
        }
        return samples
    }

    private func paintDisk(
        cx: Int,
        cy: Int,
        radius: Int,
        red: Float,
        green: Float,
        blue: Float,
        samples: inout [Float],
        width: Int
    ) {
        let reach = radius * radius
        let count = samples.count / 4
        let height = count / width
        for row in 0..<height {
            for x in 0..<width {
                let dx = x - cx
                let dy = row - cy
                if dx * dx + dy * dy > reach { continue }
                let offset = index(x, row, width: width, height: height)
                samples[offset] = red
                samples[offset + 1] = green
                samples[offset + 2] = blue
                samples[offset + 3] = 1
            }
        }
    }

    private func fill(rect: Range<Int>, rows: Range<Int>, samples: inout [Float], width: Int, height: Int, value: Float) {
        for row in rows {
            for x in rect {
                let offset = index(x, row, width: width, height: height)
                samples[offset] = value
                samples[offset + 1] = value
                samples[offset + 2] = value
            }
        }
    }

    private func index(_ x: Int, _ row: Int, width: Int, height: Int) -> Int {
        _ = height
        return (row * width + x) * 4
    }
}
