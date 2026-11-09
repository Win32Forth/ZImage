import CoreGraphics
import CoreImage
import CoreML
import XCTest
@testable import ZImager

final class InpaintTests: XCTestCase {
    private let context = TonePipeline.makeContext()

    func testClickMaskContainsTheClickAndStaysSmall() throws {
        let image = fixture()
        let click = CGPoint(x: 40, y: 40)
        let operation = InpaintPipeline.select(image: image, bitmapPoint: click, context: context)
        let decoded = try XCTUnwrap(decodedMask(operation.maskPNG))
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 1024)
        XCTAssertLessThan(operation.maskPNG.count, 1_000_000)
        let box = try XCTUnwrap(boundingBox(decoded.bytes, width: decoded.width, height: decoded.height))
        let mapped = CGPoint(
            x: click.x / 80 * CGFloat(decoded.width),
            y: click.y / 80 * CGFloat(decoded.height)
        )
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(mapped))

        let color = InpaintPipeline.colorMask(image: image, bitmapPoint: click, context: context)
        let colorDecoded = try XCTUnwrap(decodedMask(color))
        let colorBox = try XCTUnwrap(boundingBox(colorDecoded.bytes, width: colorDecoded.width, height: colorDecoded.height))
        XCTAssertTrue(colorBox.insetBy(dx: -1, dy: -1).contains(click))
        XCTAssertEqual(colorDecoded.bytes[0], 0)
        XCTAssertEqual(
            EditCommand.addInpaint(InpaintOp(id: UUID(), maskPNG: color, modelID: InpaintModel.colorSelection, featherPx: 8)).historyTitle,
            "Remove object, color selection"
        )
    }

    func testUndoDropsTheInpaintFromTheReplayedState() {
        let operation = InpaintOp(id: UUID(), maskPNG: Data([1, 2, 3]), modelID: InpaintModel.lama, featherPx: 8)
        var log = HistoryLog()
        log.commit(.addInpaint(operation))
        XCTAssertEqual(log.state.inpaints.count, 1)
        log.undo()
        let replayed = EditState.replay(Array(log.commands.prefix(log.cursor)))
        XCTAssertTrue(replayed.inpaints.isEmpty)
        XCTAssertEqual(log.state, replayed)
    }

    func testStubBlursTheMaskAndLeavesTheCorner() throws {
        XCTAssertNil(InpaintPipeline.modelURL())
        let image = fixture()
        let mask = InpaintPipeline.colorMask(image: image, bitmapPoint: CGPoint(x: 40, y: 40), context: context)
        let operation = InpaintOp(id: UUID(), maskPNG: mask, modelID: InpaintModel.colorSelection, featherPx: 8)
        let filled = InpaintPipeline.applyInteractive(base: image, operations: [operation])
        let before = Eyedropper.linearSamples(image, context: context)
        let after = Eyedropper.linearSamples(filled, context: context)
        XCTAssertEqual(before.count, 80 * 80)
        XCTAssertEqual(after.count, before.count)
        let corner = before[0]
        let cornerAfter = after[0]
        XCTAssertEqual(cornerAfter.r, corner.r, accuracy: 0.02)
        XCTAssertEqual(cornerAfter.g, corner.g, accuracy: 0.02)
        XCTAssertEqual(cornerAfter.b, corner.b, accuracy: 0.02)
        let center = 40 * 80 + 40
        let shift = abs(after[center].r - before[center].r) + abs(after[center].b - before[center].b)
        XCTAssertGreaterThan(shift, 0.05)
    }

    func testExportRefusesAMissingModel() {
        var state = EditState.identity
        XCTAssertNoThrow(try InpaintPipeline.validateForExport(state))
        state.inpaints = [InpaintOp.empty()]
        XCTAssertThrowsError(try InpaintPipeline.validateForExport(state)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testPlannedModelInputAndExportTilesStayInsideTheCaps() {
        let interactive = InpaintPipeline.modelInputSize(crop: CGSize(width: 4000, height: 2000), maxEdge: InpaintPipeline.interactiveLongEdge)
        XCTAssertLessThanOrEqual(max(interactive.width, interactive.height), 1024)
        let export = InpaintPipeline.modelInputSize(crop: CGSize(width: 4000, height: 2000), maxEdge: InpaintPipeline.exportLongEdge)
        XCTAssertLessThanOrEqual(max(export.width, export.height), 2048)

        let tiles = InpaintPipeline.tiles(covering: CGSize(width: 5000, height: 3000))
        XCTAssertFalse(tiles.isEmpty)
        for tile in tiles {
            XCTAssertLessThanOrEqual(tile.width, 2048)
            XCTAssertLessThanOrEqual(tile.height, 2048)
        }
        let overlap = tiles[0].maxX - tiles[1].minX
        XCTAssertEqual(overlap, 128, accuracy: 0.1)

        let extent = CGRect(x: 0, y: 0, width: 400, height: 300)
        let crop = InpaintPipeline.paddedCrop(of: CGRect(x: 10, y: 10, width: 100, height: 40), in: extent)
        XCTAssertEqual(crop.minX, 0, accuracy: 0.1)
        XCTAssertEqual(crop.minY, 0, accuracy: 0.1)
        XCTAssertGreaterThan(crop.width, 100)
    }

    func testCoreMLInputLongEdgeWhenTheModelIsPresent() throws {
        guard let url = InpaintPipeline.modelURL() else {
            throw XCTSkip("LaMa model is not in the bundle. Interactive removal uses StubInpainter.")
        }
        let model = try MLModel(contentsOf: url)
        var longest = 0
        for description in model.modelDescription.inputDescriptionsByName.values {
            if let image = description.imageConstraint {
                longest = max(longest, image.pixelsWide, image.pixelsHigh)
            }
        }
        XCTAssertGreaterThan(longest, 0)
        XCTAssertLessThanOrEqual(longest, InpaintPipeline.interactiveLongEdge)
    }

    private func fixture() -> CIImage {
        let width = 80
        let height = 80
        var samples = [Float](repeating: 0, count: width * height * 4)
        for bitmapY in 0..<height {
            let row = height - 1 - bitmapY
            for x in 0..<width {
                let inside = (30..<50).contains(x) && (30..<50).contains(bitmapY)
                let offset = (row * width + x) * 4
                if inside {
                    samples[offset] = 0.85
                    samples[offset + 1] = 0.15
                    samples[offset + 2] = 0.1
                } else {
                    samples[offset] = 0.2
                    samples[offset + 1] = 0.3
                    samples[offset + 2] = 0.8
                }
                samples[offset + 3] = 1
            }
        }
        let data = samples.withUnsafeBytes { Data($0) }
        return CIImage(
            bitmapData: data,
            bytesPerRow: width * 16,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: TonePipeline.workingColorSpace
        )
    }

    private func decodedMask(_ data: Data) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let provider = image.dataProvider,
              let raw = provider.data,
              let pointer = CFDataGetBytePtr(raw) else {
            return nil
        }
        let count = CFDataGetLength(raw)
        var bytes = [UInt8](repeating: 0, count: image.height * image.width)
        let rowBytes = image.bytesPerRow
        for y in 0..<image.height {
            for x in 0..<image.width {
                let source = y * rowBytes + x * max(1, image.bitsPerPixel / 8)
                if source < count {
                    bytes[y * image.width + x] = pointer[source]
                }
            }
        }
        return (image.width, image.height, bytes)
    }

    private func boundingBox(_ bytes: [UInt8], width: Int, height: Int) -> CGRect? {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[y * width + x] > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
