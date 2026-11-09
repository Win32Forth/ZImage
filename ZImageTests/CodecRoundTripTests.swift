import XCTest
@testable import ZImager

final class CodecRoundTripTests: XCTestCase {
    func testWebPLossyRoundTripsDimensions() throws {
        let rgba = gradientRGBA(width: 32, height: 32)
        let encoded = try WebPWriter.encodeRGBA(rgba, width: 32, height: 32, quality: WebPWriter.defaultQuality)
        let decoded = try WebPWriter.decodeRGBA(encoded)
        XCTAssertEqual(decoded.width, 32)
        XCTAssertEqual(decoded.height, 32)
        XCTAssertEqual(WebPWriter.defaultQuality, 80)
    }

    func testWebPLosslessMatchesOpaquePixels() throws {
        let rgba = gradientRGBA(width: 32, height: 32)
        let encoded = try WebPWriter.encodeLosslessRGBA(rgba, width: 32, height: 32)
        let decoded = try WebPWriter.decodeRGBA(encoded)
        XCTAssertEqual(decoded.rgba, rgba)
    }

    func testJPEGXLLossyRoundTripsDimensions() throws {
        XCTAssertEqual(JPEGXLWriter.effort, 7)
        XCTAssertEqual(JPEGXLWriter.lossyDistance, 1)
        let rgb = gradientRGB(width: 32, height: 32)
        let encoded = try JPEGXLWriter.encodeRGB(rgb, width: 32, height: 32, lossless: false)
        let decoded = try JPEGXLWriter.decodeRGB(encoded)
        XCTAssertEqual(decoded.width, 32)
        XCTAssertEqual(decoded.height, 32)
    }

    func testJPEGXLLosslessMatchesPixels() throws {
        let rgb = gradientRGB(width: 32, height: 32)
        let encoded = try JPEGXLWriter.encodeRGB(rgb, width: 32, height: 32, lossless: true)
        let decoded = try JPEGXLWriter.decodeRGB(encoded)
        XCTAssertEqual(decoded.width, 32)
        XCTAssertEqual(decoded.height, 32)
        XCTAssertEqual(decoded.rgb, rgb)
    }

    private func gradientRGBA(width: Int, height: Int) -> Data {
        var bytes = Data(count: width * height * 4)
        for index in 0..<(width * height) {
            bytes[index * 4] = UInt8(index & 255)
            bytes[index * 4 + 1] = UInt8((index * 3) & 255)
            bytes[index * 4 + 2] = UInt8((index * 7) & 255)
            bytes[index * 4 + 3] = 255
        }
        return bytes
    }

    private func gradientRGB(width: Int, height: Int) -> Data {
        var bytes = Data(count: width * height * 3)
        for index in 0..<(width * height) {
            bytes[index * 3] = UInt8(index & 255)
            bytes[index * 3 + 1] = UInt8((index * 3) & 255)
            bytes[index * 3 + 2] = UInt8((index * 7) & 255)
        }
        return bytes
    }
}
