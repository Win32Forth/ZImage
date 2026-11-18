import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ZImager

final class PhotoMergeTests: XCTestCase {
    func testFileNameUsesBothStemsAndSkipsANameThatExists() {
        let open = PhotoMerge.fileName(first: "Left.jpg", second: "Right.png") { _ in false }
        XCTAssertEqual(open, "Left-Right.tiff")
        let taken = PhotoMerge.fileName(first: "Left.jpg", second: "Right.png") { $0 == "Left-Right.tiff" }
        XCTAssertEqual(taken, "Left-Right-2.tiff")
        let long = String(repeating: "a", count: 150)
        let shortened = PhotoMerge.fileName(first: "\(long).jpg", second: "\(long).png") { _ in false }
        XCTAssertEqual(shortened, "\(String(repeating: "a", count: 100))-\(String(repeating: "a", count: 100)).tiff")
    }

    func testHorizontalJoinPutsTheFirstPhotoOnTheLeft() throws {
        let joined = try XCTUnwrap(PhotoMerge.render(
            first: solid(width: 20, height: 10, red: 220, green: 0, blue: 0),
            second: solid(width: 20, height: 10, red: 0, green: 0, blue: 220),
            axis: .horizontal
        ))
        XCTAssertEqual(joined.width, 40)
        XCTAssertEqual(joined.height, 10)
        let field = try pixels(joined)
        assertColor(field, x: 0, y: 0, red: 220, green: 0, blue: 0)
        assertColor(field, x: 19, y: 5, red: 220, green: 0, blue: 0)
        assertColor(field, x: 20, y: 5, red: 0, green: 0, blue: 220)
        assertColor(field, x: 39, y: 9, red: 0, green: 0, blue: 220)
    }

    func testIdenticalPhotosStaySideBySide() throws {
        let red = solid(width: 20, height: 10, red: 200, green: 0, blue: 0)
        let joined = try XCTUnwrap(PhotoMerge.render(first: red, second: red, axis: .horizontal))
        XCTAssertEqual(joined.width, 40)
        XCTAssertEqual(joined.height, 10)
    }

    func testHorizontalJoinScalesTheSecondPhotoToTheSharedHeight() throws {
        let joined = try XCTUnwrap(PhotoMerge.render(
            first: solid(width: 20, height: 10, red: 220, green: 0, blue: 0),
            second: solid(width: 10, height: 20, red: 0, green: 0, blue: 220),
            axis: .horizontal
        ))
        XCTAssertEqual(joined.width, 25)
        XCTAssertEqual(joined.height, 10)
        let field = try pixels(joined)
        assertColor(field, x: 19, y: 5, red: 220, green: 0, blue: 0)
        assertColor(field, x: 20, y: 5, red: 0, green: 0, blue: 220)
        assertColor(field, x: 24, y: 0, red: 0, green: 0, blue: 220)
    }

    func testVerticalJoinPutsTheFirstPhotoOnTop() throws {
        let joined = try XCTUnwrap(PhotoMerge.render(
            first: solid(width: 10, height: 8, red: 220, green: 0, blue: 0),
            second: solid(width: 10, height: 8, red: 0, green: 0, blue: 220),
            axis: .vertical
        ))
        XCTAssertEqual(joined.width, 10)
        XCTAssertEqual(joined.height, 16)
        let field = try pixels(joined)
        assertColor(field, x: 3, y: 0, red: 220, green: 0, blue: 0)
        assertColor(field, x: 3, y: 7, red: 220, green: 0, blue: 0)
        assertColor(field, x: 3, y: 8, red: 0, green: 0, blue: 220)
        assertColor(field, x: 3, y: 15, red: 0, green: 0, blue: 220)
    }

    func testOverlapFadesFromTheFirstPhotoAndKeepsTheShift() throws {
        let first = pattern(width: 40, height: 16) { x, y in (UInt8(x), UInt8(y), 0) }
        let second = pattern(width: 40, height: 16) { x, y in
            if x < 24, y + 2 < 16 { return (UInt8(16 + x), UInt8(y + 2), 0) }
            return (255, 0, 0)
        }
        let joined = try XCTUnwrap(PhotoMerge.render(first: first, second: second, axis: .horizontal))
        XCTAssertEqual(joined.width, 56, "overlap should be the 24 repeated columns")
        XCTAssertEqual(joined.height, 18, "the second photo slides down by 2")
        let field = try pixels(joined)
        assertColor(field, x: 0, y: 0, red: 0, green: 0, blue: 0)
        assertColor(field, x: 16, y: 0, red: 16, green: 0, blue: 0)
        assertColor(field, x: 16, y: 2, red: 16, green: 2, blue: 0)
        assertColor(field, x: 39, y: 2, red: 39, green: 2, blue: 0)
        assertColor(field, x: 40, y: 2, red: 255, green: 0, blue: 0)
        assertColor(field, x: 40, y: 0, red: 255, green: 0, blue: 0)
        assertColor(field, x: 0, y: 16, red: 0, green: 15, blue: 0)
    }

    func testRepeatedEdgeFadesInFromTheFirstPhoto() throws {
        let first = pattern(width: 80, height: 16) { x, _ in
            if x >= 78 { return (0, 0, 0) }
            if x >= 50 { return (0, 100, 0) }
            return (0, 10, 0)
        }
        let second = pattern(width: 50, height: 16) { x, _ in
            x < 28 ? (0, 112, 0) : (0, 40, 0)
        }
        let joined = try XCTUnwrap(PhotoMerge.render(first: first, second: second, axis: .horizontal))
        let overlap = 80 + 50 - joined.width
        XCTAssertGreaterThan(overlap, 16)
        XCTAssertLessThan(overlap, 32)
        XCTAssertEqual(joined.height, 16)
        let field = try pixels(joined)
        let seam = 80 - overlap
        let start = color(field, x: seam, y: 8)
        let towardSecond = color(field, x: min(seam + overlap - 4, 77), y: 8)
        XCTAssertLessThan(abs(Int(start.green) - 100), abs(Int(start.green) - 112))
        XCTAssertLessThan(abs(Int(towardSecond.green) - 112), abs(Int(towardSecond.green) - 100))
    }

    func testSeamSlidesWithoutEatingThePhoto() throws {
        let first = pattern(width: 30, height: 40) { _, y in (0, UInt8(y), 0) }
        let second = pattern(width: 30, height: 40) { _, y in
            y < 34 ? (0, UInt8(y + 6), 0) : (0, 0, 0)
        }
        let joined = try XCTUnwrap(PhotoMerge.render(first: first, second: second, axis: .horizontal))
        XCTAssertEqual(joined.width, 60)
        XCTAssertEqual(joined.height, 46)
        let field = try pixels(joined)
        assertColor(field, x: 0, y: 5, red: 0, green: 5, blue: 0)
        assertColor(field, x: 30, y: 6, red: 0, green: 6, blue: 0)
        assertColor(field, x: 30, y: 0, red: 0, green: 6, blue: 0)
    }

    func testPerformWritesAnEightBitTiffUsingTheSelectionOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("Alpha.png")
        let second = dir.appendingPathComponent("Beta.png")
        try writePNG(solid(width: 8, height: 8, red: 210, green: 0, blue: 0), to: first)
        try writePNG(solid(width: 8, height: 8, red: 0, green: 0, blue: 210), to: second)
        let same = PhotoMerge.perform(first: first, second: first, axis: .horizontal, directory: dir)
        guard case .failure(.samePhoto) = same else {
            return XCTFail("the same file twice should be refused")
        }
        let written = PhotoMerge.perform(first: first, second: second, axis: .horizontal, directory: dir)
        guard case .success(let name) = written else {
            return XCTFail("expected a TIFF name, got \(written)")
        }
        XCTAssertEqual(name, "Alpha-Beta.tiff")
        let url = dir.appendingPathComponent(name)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 8)
        let field = try pixels(image)
        assertColor(field, x: 0, y: 0, red: 210, green: 0, blue: 0)
        assertColor(field, x: 15, y: 0, red: 0, green: 0, blue: 210)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let depth = (properties?[kCGImagePropertyDepth] as? NSNumber)?.intValue
        XCTAssertEqual(depth, 8)
    }

    func testManualOffsetMovesTheSecondPhotoAndExtendsTheWedge() throws {
        let joined = try XCTUnwrap(PhotoMerge.render(
            first: solid(width: 20, height: 10, red: 220, green: 0, blue: 0),
            second: solid(width: 20, height: 10, red: 0, green: 0, blue: 220),
            axis: .horizontal,
            right: -4,
            down: 5
        ))
        XCTAssertEqual(joined.width, 36)
        XCTAssertEqual(joined.height, 15)
        let field = try pixels(joined)
        assertColor(field, x: 0, y: 0, red: 220, green: 0, blue: 0)
        assertColor(field, x: 16, y: 5, red: 220, green: 0, blue: 0)
        assertColor(field, x: 19, y: 5, red: 0, green: 0, blue: 220)
        assertColor(field, x: 20, y: 5, red: 0, green: 0, blue: 220)
        assertColor(field, x: 30, y: 0, red: 0, green: 0, blue: 220)
        assertColor(field, x: 0, y: 14, red: 220, green: 0, blue: 0)
    }

    func testManualGapStaysBlack() throws {
        let joined = try XCTUnwrap(PhotoMerge.render(
            first: solid(width: 20, height: 10, red: 220, green: 0, blue: 0),
            second: solid(width: 20, height: 10, red: 0, green: 0, blue: 220),
            axis: .horizontal,
            right: 4,
            down: 0
        ))
        XCTAssertEqual(joined.width, 44)
        XCTAssertEqual(joined.height, 10)
        let field = try pixels(joined)
        assertColor(field, x: 19, y: 5, red: 220, green: 0, blue: 0)
        assertColor(field, x: 22, y: 5, red: 0, green: 0, blue: 0)
        assertColor(field, x: 24, y: 5, red: 0, green: 0, blue: 220)
    }

    func testManualVerticalOffsetPutsTheSecondPhotoUnderTheFirst() throws {
        let joined = try XCTUnwrap(PhotoMerge.render(
            first: solid(width: 10, height: 8, red: 220, green: 0, blue: 0),
            second: solid(width: 10, height: 8, red: 0, green: 0, blue: 220),
            axis: .vertical,
            right: 0,
            down: -3
        ))
        XCTAssertEqual(joined.width, 10)
        XCTAssertEqual(joined.height, 13)
        let field = try pixels(joined)
        assertColor(field, x: 3, y: 0, red: 220, green: 0, blue: 0)
        assertColor(field, x: 3, y: 5, red: 220, green: 0, blue: 0)
        assertColor(field, x: 3, y: 7, red: 0, green: 0, blue: 220)
        assertColor(field, x: 3, y: 8, red: 0, green: 0, blue: 220)
    }

    func testManualOffsetStopsAtOnePhoto() throws {
        let image = solid(width: 20, height: 10, red: 200, green: 0, blue: 0)
        let joined = try XCTUnwrap(PhotoMerge.render(
            first: image,
            second: image,
            axis: .horizontal,
            right: -10_000,
            down: 10_000
        ))
        XCTAssertEqual(joined.width, 21)
        XCTAssertEqual(joined.height, 19)
    }

    func testMergePreviewZoomKeepsTheClickedPixel() {
        var view = MergePreviewViewport.fitted(
            imageWidth: 100,
            imageHeight: 80,
            viewWidth: 50,
            viewHeight: 40
        )
        XCTAssertEqual(view.scale, 0.5, accuracy: 0.0001)
        XCTAssertEqual(view.originX, 0, accuracy: 0.0001)
        XCTAssertEqual(view.originY, 0, accuracy: 0.0001)
        let point = CGPoint(x: 10, y: 16)
        view.zoom(
            by: 2,
            at: point,
            imageWidth: 100,
            imageHeight: 80,
            viewWidth: 50,
            viewHeight: 40
        )
        XCTAssertEqual(view.scale, 1, accuracy: 0.0001)
        XCTAssertEqual((point.x - view.originX) / view.scale, 20, accuracy: 0.0001)
        XCTAssertEqual((point.y - view.originY) / view.scale, 32, accuracy: 0.0001)
        XCTAssertEqual(MergePreviewViewport.zoomStep, 2.0.squareRoot(), accuracy: 0.0001)
        XCTAssertEqual(MergePreviewViewport.maximumScale, 4)
    }

    func testMergePreviewOptionZoomStopsAtFit() {
        var view = MergePreviewViewport.fitted(
            imageWidth: 100,
            imageHeight: 80,
            viewWidth: 50,
            viewHeight: 40
        )
        let fit = view.scale
        view.zoom(
            by: 1 / MergePreviewViewport.zoomStep,
            at: CGPoint(x: 25, y: 20),
            imageWidth: 100,
            imageHeight: 80,
            viewWidth: 50,
            viewHeight: 40
        )
        XCTAssertEqual(view.scale, fit, accuracy: 0.0001)
    }

    func testMergePreviewPanMovesTheWholePhoto() {
        var view = MergePreviewViewport.actualSize(
            focusX: 50,
            focusY: 40,
            imageWidth: 100,
            imageHeight: 80,
            viewWidth: 20,
            viewHeight: 20
        )
        let scale = view.scale
        let originX = view.originX
        view.pan(dx: 5, dy: 0, imageWidth: 100, imageHeight: 80, viewWidth: 20, viewHeight: 20)
        XCTAssertEqual(view.scale, scale, accuracy: 0.0001)
        XCTAssertEqual(view.originX, originX + 5, accuracy: 0.0001)
        view.pan(dx: 1000, dy: 0, imageWidth: 100, imageHeight: 80, viewWidth: 20, viewHeight: 20)
        XCTAssertEqual(view.originX, 0, accuracy: 0.0001)
        XCTAssertEqual(view.scale, scale, accuracy: 0.0001)
    }

    func testCommandClickKeepsTheFirstPhotoFirst() {
        let order = SelectionOrder.update(
            previous: ["a"],
            gridOrder: ["a", "b", "c"],
            anchor: "a",
            clicked: "b",
            shift: false,
            extend: true,
            keys: ["a", "b"]
        )
        XCTAssertEqual(order, ["a", "b"])
    }

    func testBackwardShiftPutsTheAnchorFirst() {
        let order = SelectionOrder.update(
            previous: ["c"],
            gridOrder: ["a", "b", "c", "d"],
            anchor: "c",
            clicked: "a",
            shift: true,
            extend: false,
            keys: ["a", "b", "c"]
        )
        XCTAssertEqual(order, ["c", "b", "a"])
    }

    private func solid(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage {
        pattern(width: width, height: height) { _, _ in (red, green, blue) }
    }

    private func pattern(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                let index = (y * width + x) * 4
                bytes[index] = color.0
                bytes[index + 1] = color.1
                bytes[index + 2] = color.2
                bytes[index + 3] = 255
            }
        }
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private struct Field {
        var width: Int
        var height: Int
        var bytes: [UInt8]
    }

    private func pixels(_ image: CGImage) throws -> Field {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Field(width: image.width, height: image.height, bytes: bytes)
    }

    private func color(_ field: Field, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let index = (y * field.width + x) * 4
        return (field.bytes[index], field.bytes[index + 1], field.bytes[index + 2])
    }

    private func assertColor(
        _ field: Field,
        x: Int,
        y: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pixel = color(field, x: x, y: y)
        XCTAssertLessThanOrEqual(abs(Int(pixel.red) - Int(red)), 8, "red \(pixel.red) at \(x),\(y)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(pixel.green) - Int(green)), 8, "green \(pixel.green) at \(x),\(y)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(pixel.blue) - Int(blue)), 8, "blue \(pixel.blue) at \(x),\(y)", file: file, line: line)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
