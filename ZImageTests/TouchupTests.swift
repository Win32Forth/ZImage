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
