import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ZImager

final class X3FPreviewTests: XCTestCase {
    func testNotX3FReturnsTheVisibleError() throws {
        let url = temporaryFile("not-x3f.bin")
        try Data("ABCD not an x3f".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try X3FPreview.open(url: url)) { error in
            let openError = error as? X3FOpenError
            XCTAssertEqual(openError, .notX3F)
            XCTAssertEqual(openError?.localizedDescription, "Not an X3F file.")
        }
    }

    @MainActor
    func testNotX3FShowsTheErrorOnTheCanvas() async throws {
        let url = temporaryFile("not-x3f.x3f")
        try Data("ABCD".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = EditorModel()
        model.openSecurityScopedFile(at: url)
        try await waitUntil(model.canvasMessage != nil || model.proxy != nil)
        XCTAssertNil(model.proxy)
        XCTAssertEqual(model.canvasMessage, "Not an X3F file.")
        XCTAssertEqual(model.decodeSupport, .unsupported)
    }

    func testEmbeddedJPEGOpensAsPreviewOnly() throws {
        let small = try jpegData(width: 8, height: 8)
        let large = try jpegData(width: 48, height: 32)
        XCTAssertGreaterThan(large.count, small.count)
        let url = temporaryFile("embedded-jpeg.x3f")
        try writeX3F(smallJPEG: small, largeJPEG: large, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let opened = try X3FPreview.open(url: url)
        XCTAssertEqual(opened.decodeSupport, .previewOnly)
        XCTAssertEqual(opened.decodeSupport.rawValue, "preview_only")
        XCTAssertEqual(opened.banner, "Sigma X3F preview only. Full Foveon decode is not available.")
        XCTAssertEqual(opened.proxy.entryPoint, .imageIOThumbnail)
        XCTAssertLessThanOrEqual(opened.proxy.longEdge, ProxyRenderer.maxLongEdge)
        XCTAssertEqual(opened.proxy.width, 48)
        XCTAssertEqual(opened.proxy.height, 32)
        XCTAssertEqual(opened.jpegByteCount, large.count)
        XCTAssertLessThan(opened.bytesRead, X3FPreview.readBudget)
    }

    @MainActor
    func testModelShowsThePreviewBanner() async throws {
        let small = try jpegData(width: 8, height: 8)
        let large = try jpegData(width: 48, height: 32)
        let url = temporaryFile("embedded-jpeg.x3f")
        try writeX3F(smallJPEG: small, largeJPEG: large, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = EditorModel()
        model.openSecurityScopedFile(at: url)
        try await waitUntil(model.previewBanner != nil || model.canvasMessage != nil)
        XCTAssertEqual(model.previewBanner, X3FPreview.banner)
        XCTAssertEqual(model.decodeSupport, .previewOnly)
        XCTAssertEqual(model.proxy?.entryPoint, .imageIOThumbnail)
        XCTAssertLessThanOrEqual(model.proxy?.longEdge ?? Int.max, ProxyRenderer.maxLongEdge)
    }

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zimage-\(UUID().uuidString)-\(name)")
    }

    @MainActor
    private func waitUntil(_ ready: @autoclosure () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !ready(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// FOVb file with a skipped PROP section, a small raw JPEG, a larger SECi JPEG, and one entry past EOF.
    private func writeX3F(smallJPEG: Data, largeJPEG: Data, to url: URL) throws {
        var body = Data("FOVb".utf8)
        let junk = Data("PROP".utf8) + Data(count: 8)
        let junkOffset = UInt64(body.count)
        body.append(junk)

        let smallOffset = UInt64(body.count)
        body.append(smallJPEG)

        var header = Data("SECi".utf8)
        header.append(le32(0))
        header.append(le32(2))
        header.append(le32(18))
        while header.count < 28 {
            header.append(0)
        }
        let sectionOffset = UInt64(body.count)
        body.append(header)
        body.append(largeJPEG)
        let sectionLength = UInt64(header.count + largeJPEG.count)

        let directory = UInt32(body.count)
        var table = Data("SECd".utf8)
        table.append(le32(0))
        table.append(le32(4))
        table.append(entry(offset: junkOffset, length: UInt64(junk.count), type: "PROP"))
        table.append(entry(offset: smallOffset, length: UInt64(smallJPEG.count), type: "IMAG"))
        table.append(entry(offset: sectionOffset, length: sectionLength, type: "IMA2"))
        table.append(entry(offset: 0, length: 20_000_000, type: "IMAG"))
        body.append(table)
        body.append(le32(directory))
        try body.write(to: url)
    }

    private func entry(offset: UInt64, length: UInt64, type: String) -> Data {
        var data = Data()
        data.append(le32(UInt32(offset)))
        data.append(le32(UInt32(length)))
        data.append(Data(type.utf8))
        return data
    }

    private func le32(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 4)
    }

    private func jpegData(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not allocate a raster")
            throw X3FOpenError.noPreview("jpeg")
        }
        context.setFillColor(CGColor(red: 0.7, green: 0.2, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw X3FOpenError.noPreview("jpeg")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw X3FOpenError.noPreview("jpeg")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw X3FOpenError.noPreview("jpeg")
        }
        return data as Data
    }
}
