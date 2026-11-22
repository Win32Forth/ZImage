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
        try await waitUntil(model.decodeSupport != nil || model.canvasMessage != nil)
        XCTAssertEqual(model.previewBanner, X3FPreview.banner)
        XCTAssertEqual(model.decodeSupport, .previewOnly)
        XCTAssertEqual(model.proxy?.entryPoint, .imageIOThumbnail)
        XCTAssertLessThanOrEqual(model.proxy?.longEdge ?? Int.max, ProxyRenderer.maxLongEdge)
    }

    func testARejectedSensorDecodeKeepsThePreview() throws {
        setenv("ZIMAGER_X3F", "/usr/bin/false", 1)
        defer { unsetenv("ZIMAGER_X3F") }
        let jpeg = try jpegData(width: 16, height: 12)
        let url = temporaryFile("rejected-sensor.x3f")
        try writeContainer([
            ("PROP", Data(count: 70_000)),
            ("IMA2", seci(format: 18, columns: 16, rows: 12, rowSize: 0, payload: jpeg)),
        ], to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let opened = try X3FFiles.open(url: url).get()
        XCTAssertEqual(opened.decodeSupport, .previewOnly)
        XCTAssertEqual(opened.banner, X3FPreview.banner)
        XCTAssertEqual(opened.proxy.width, 16)
        XCTAssertEqual(opened.proxy.height, 12)
    }

    func testAcknowledgementsNameTheSensorDecoder() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Sang Lee"))
        XCTAssertTrue(text.contains("Roland Karlsson"))
        XCTAssertTrue(text.contains("Apache-2.0"))
    }

    func testPlainRGBKeepsThePaddedRow() throws {
        let rowSize = 8
        let payload = plainPayload(columns: 2, rows: 2, stride: rowSize, rowsRGB: [
            [200, 10, 20, 30, 40, 50],
            [1, 2, 3, 4, 5, 6],
        ])
        let url = temporaryFile("plain.x3f")
        try writeContainer([
            ("IMA2", seci(format: 3, columns: 2, rows: 2, rowSize: UInt32(rowSize), payload: payload)),
        ], to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let opened = try X3FPreview.open(url: url)
        XCTAssertEqual(opened.decodeSupport, .previewOnly)
        XCTAssertEqual(opened.proxy.width, 2)
        XCTAssertEqual(opened.proxy.height, 2)
        assertRGB(opened.proxy.image, 0, 0, 200, 10, 20)
        assertRGB(opened.proxy.image, 1, 0, 30, 40, 50)
        assertRGB(opened.proxy.image, 0, 1, 1, 2, 3)
        assertRGB(opened.proxy.image, 1, 1, 4, 5, 6)
    }

    func testHuffmanDifferenceWrapsInEightBits() throws {
        let payload = huffmanPayload(rows: [
            [200, 0, 0, 57, 0, 0],
            [9, 8, 7, 1, 0, 0],
        ])
        let url = temporaryFile("huffman.x3f")
        try writeContainer([
            ("IMA2", seci(format: 11, columns: 2, rows: 2, rowSize: 0, payload: payload)),
        ], to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let opened = try X3FPreview.open(url: url)
        XCTAssertEqual(opened.proxy.width, 2)
        XCTAssertEqual(opened.proxy.height, 2)
        assertRGB(opened.proxy.image, 0, 0, 200, 0, 0)
        assertRGB(opened.proxy.image, 1, 0, 1, 0, 0)
        assertRGB(opened.proxy.image, 0, 1, 9, 8, 7)
        assertRGB(opened.proxy.image, 1, 1, 10, 8, 7)
    }

    func testJPEGLargerThanEightMegabytesOpens() throws {
        let jpeg = padJPEG(try jpegData(width: 32, height: 24), extra: 8 * 1024 * 1024 + 64)
        XCTAssertGreaterThan(jpeg.count, 8 * 1024 * 1024)
        let tiny = plainPayload(columns: 1, rows: 1, stride: 4, rowsRGB: [[9, 8, 7]])
        let url = temporaryFile("large-jpeg.x3f")
        try writeContainer([
            ("IMAG", seci(format: 3, columns: 1, rows: 1, rowSize: 4, payload: tiny)),
            ("IMA2", seci(format: 18, columns: 32, rows: 24, rowSize: 0, payload: jpeg)),
        ], to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let opened = try X3FPreview.open(url: url)
        XCTAssertEqual(opened.decodeSupport, .previewOnly)
        XCTAssertEqual(opened.proxy.width, 32)
        XCTAssertEqual(opened.proxy.height, 24)
        XCTAssertGreaterThan(opened.jpegByteCount, 8 * 1024 * 1024)
        XCTAssertGreaterThan(opened.bytesRead, 8 * 1024 * 1024)
        XCTAssertLessThan(opened.bytesRead, X3FPreview.readBudget)
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

    private func writeContainer(_ parts: [(type: String, bytes: Data)], to url: URL) throws {
        var body = Data("FOVb".utf8)
        var placed: [(UInt64, UInt64, String)] = []
        for part in parts {
            placed.append((UInt64(body.count), UInt64(part.bytes.count), part.type))
            body.append(part.bytes)
        }
        let directory = UInt32(body.count)
        var table = Data("SECd".utf8)
        table.append(le32(0))
        table.append(le32(UInt32(placed.count)))
        for item in placed {
            table.append(entry(offset: item.0, length: item.1, type: item.2))
        }
        body.append(table)
        body.append(le32(directory))
        try body.write(to: url)
    }

    private func seci(format: UInt32, columns: UInt32, rows: UInt32, rowSize: UInt32, payload: Data) -> Data {
        var header = Data("SECi".utf8)
        header.append(le32(0))
        header.append(le32(2))
        header.append(le32(format))
        header.append(le32(columns))
        header.append(le32(rows))
        header.append(le32(rowSize))
        return header + payload
    }

    private func plainPayload(columns: Int, rows: Int, stride: Int, rowsRGB: [[UInt8]]) -> Data {
        var data = Data()
        for row in rowsRGB.prefix(rows) {
            var bytes = Data(row.prefix(columns * 3))
            if bytes.count < stride {
                bytes.append(Data(repeating: 0xEE, count: stride - bytes.count))
            }
            data.append(bytes.prefix(stride))
        }
        return data
    }

    /// Eight-bit identity codes. Each row is padded with 0xFF so a reader that ignores row offsets fails.
    private func huffmanPayload(rows: [[UInt8]]) -> Data {
        var table = Data(count: 256 * 4)
        for symbol in 0..<256 {
            let code = (UInt32(8) << 27) | UInt32(symbol)
            table.replaceSubrange(symbol * 4..<(symbol + 1) * 4, with: le32(code))
        }
        var encoded = Data()
        var offsets = Data()
        for row in rows {
            offsets.append(le32(UInt32(encoded.count)))
            encoded.append(contentsOf: row)
            while encoded.count % 4 != 0 {
                encoded.append(0xFF)
            }
        }
        return table + encoded + offsets
    }

    private func padJPEG(_ jpeg: Data, extra: Int) -> Data {
        var out = Data(jpeg.prefix(2))
        var remaining = extra
        while remaining > 0 {
            let payload = min(remaining, 65533)
            let length = payload + 2
            out.append(0xFF)
            out.append(0xFE)
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8(length & 0xFF))
            out.append(Data(count: payload))
            remaining -= payload
        }
        out.append(jpeg.dropFirst(2))
        return out
    }

    private func assertRGB(_ image: CGImage, _ x: Int, _ y: Int, _ red: UInt8, _ green: UInt8, _ blue: UInt8, file: StaticString = #filePath, line: UInt = #line) {
        let pixel = storedRGB(image, x, y)
        XCTAssertEqual(pixel.0, red, file: file, line: line)
        XCTAssertEqual(pixel.1, green, file: file, line: line)
        XCTAssertEqual(pixel.2, blue, file: file, line: line)
    }

    private func storedRGB(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        guard let provider = image.dataProvider, let data = provider.data else {
            return (0, 0, 0)
        }
        let bytes = data as Data
        let offset = y * image.bytesPerRow + x * 4
        guard offset + 2 < bytes.count else { return (0, 0, 0) }
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
}
