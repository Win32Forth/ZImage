import CoreImage
import ImageIO
import XCTest
@testable import ZImager

final class LinearDNGTests: XCTestCase {
    private let context = TonePipeline.makeContext()

    func testLinearDNGTagsAndImageIO() throws {
        let image = try patch(width: 32, height: 24)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-linear.dng")
        try? FileManager.default.removeItem(at: url)
        try StillExporter.write(image: image, request: .standard(.dng), to: url, context: context)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data[0], 0x49)
        XCTAssertEqual(data[1], 0x49)
        XCTAssertEqual(u16(data, 2), 42)
        let root = directory(data, at: Int(u32(data, 4)))
        let version = root.values[50706] ?? 0
        XCTAssertEqual(version & 0xff, 1)
        XCTAssertEqual((version >> 8) & 0xff, 4)
        XCTAssertEqual((version >> 16) & 0xff, 0)
        XCTAssertEqual((version >> 24) & 0xff, 0)
        let raw = directory(data, at: Int(root.values[330] ?? 0))
        XCTAssertEqual(raw.values[256], 32)
        XCTAssertEqual(raw.values[257], 24)
        XCTAssertEqual(raw.values[262], 34892)
        XCTAssertEqual(raw.values[259], 1)
        XCTAssertEqual(raw.values[277], 3)
        XCTAssertEqual(raw.types[258], 3)
        XCTAssertEqual(raw.counts[258], 3)
        let bits = Int(raw.values[258] ?? 0)
        XCTAssertEqual(u16(data, bits), 16)
        XCTAssertEqual(u16(data, bits + 2), 16)
        XCTAssertEqual(u16(data, bits + 4), 16)
        XCTAssertEqual(raw.values[50778], 21)
        let modelAt = Int(raw.values[50708] ?? 0)
        let model = String(data: data.subdata(in: modelAt..<(modelAt + 6)), encoding: .utf8)
        XCTAssertEqual(model, "ZImage")
        XCTAssertEqual(
            LinearDNGWriter.adobeNotice,
            "This product includes DNG technology under license by Adobe."
        )

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual((props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 32)
        XCTAssertEqual((props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 24)

        let noticeURL = try XCTUnwrap(Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"))
        let notice = try String(contentsOf: noticeURL, encoding: .utf8)
        XCTAssertTrue(notice.contains(LinearDNGWriter.adobeNotice))
    }

    private func patch(width: Int, height: Int) throws -> CIImage {
        let bytesPerRow = width * 8
        var data = Data(count: height * bytesPerRow)
        data.withUnsafeMutableBytes { raw in
            let pixels = raw.bindMemory(to: Float16.self)
            for index in 0..<(width * height) {
                pixels[index * 4] = 0.5
                pixels[index * 4 + 1] = 0.25
                pixels[index * 4 + 2] = 0.125
                pixels[index * 4 + 3] = 1
            }
        }
        return CIImage(
            bitmapData: data,
            bytesPerRow: bytesPerRow,
            size: CGSize(width: width, height: height),
            format: .RGBAh,
            colorSpace: TonePipeline.workingColorSpace
        )
    }

    private func directory(_ data: Data, at offset: Int) -> (values: [UInt16: UInt32], types: [UInt16: UInt16], counts: [UInt16: UInt32]) {
        let count = Int(u16(data, offset))
        var values: [UInt16: UInt32] = [:]
        var types: [UInt16: UInt16] = [:]
        var counts: [UInt16: UInt32] = [:]
        for index in 0..<count {
            let entry = offset + 2 + index * 12
            let tag = u16(data, entry)
            types[tag] = u16(data, entry + 2)
            counts[tag] = u32(data, entry + 4)
            values[tag] = u32(data, entry + 8)
        }
        return (values, types, counts)
    }

    private func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
