import CoreGraphics
import ImageIO
import Security
import UniformTypeIdentifiers
import XCTest
@testable import ZImage

final class ProxyRendererTests: XCTestCase {
    func testJPEGFixtureUsesThumbnailAndStaysWithinLongEdge() throws {
        let url = try fixture("proxy-small", "jpg")
        let proxy = try ProxyRenderer.open(url: url)
        XCTAssertEqual(proxy.entryPoint, .imageIOThumbnail)
        XCTAssertNil(proxy.appliedScaleFactor)
        XCTAssertLessThanOrEqual(proxy.longEdge, ProxyRenderer.maxLongEdge)
        XCTAssertEqual(proxy.width, 64)
        XCTAssertEqual(proxy.height, 40)
    }

    func testLargeJPEGThumbnailIsCappedAt2560() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-wide-\(UUID().uuidString).jpg")
        try writeRaster(width: 4000, height: 1000, uti: .jpeg, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let proxy = try ProxyRenderer.open(url: url)
        XCTAssertEqual(proxy.entryPoint, .imageIOThumbnail)
        XCTAssertNil(proxy.appliedScaleFactor)
        XCTAssertLessThanOrEqual(proxy.longEdge, 2560)
        XCTAssertGreaterThan(proxy.longEdge, 2000)
    }

    func testPNGAndTIFFUseThumbnailEntryPoint() throws {
        for type in [UTType.png, UTType.tiff] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("zimage-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
            try writeRaster(width: 80, height: 50, uti: type, to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let proxy = try ProxyRenderer.open(url: url)
            XCTAssertEqual(proxy.entryPoint, .imageIOThumbnail, type.identifier)
            XCTAssertNil(proxy.appliedScaleFactor)
            XCTAssertLessThanOrEqual(proxy.longEdge, 2560)
        }
    }

    func testDNGFixtureUsesScaleFactor() throws {
        let url = try fixture("proxy-raw", "dng")
        let proxy = try ProxyRenderer.open(url: url)
        XCTAssertEqual(proxy.entryPoint, .cirawScaleFactor)
        XCTAssertEqual(proxy.nativeLongEdge, 32)
        XCTAssertEqual(proxy.appliedScaleFactor ?? -1, 1, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(proxy.longEdge, 2560)
        XCTAssertEqual(proxy.longEdge, 32)
    }

    func testLargeDNGScaleFactorCapsLongEdge() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-wide-\(UUID().uuidString).dng")
        try writeSyntheticDNG(width: 3000, height: 4, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let proxy = try ProxyRenderer.open(url: url)
        XCTAssertEqual(proxy.entryPoint, .cirawScaleFactor)
        XCTAssertEqual(proxy.nativeLongEdge, 3000)
        XCTAssertEqual(Double(proxy.appliedScaleFactor ?? -1), 2560.0 / 3000.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(proxy.longEdge, 2560)
        XCTAssertGreaterThan(proxy.longEdge, 2000)
    }

    func testX3FAndPDFAreRejectedWithoutAProxy() throws {
        let x3f = FileManager.default.temporaryDirectory.appendingPathComponent("sample.x3f")
        try Data([0x46, 0x4F, 0x56, 0x62]).write(to: x3f)
        defer { try? FileManager.default.removeItem(at: x3f) }
        XCTAssertThrowsError(try ProxyRenderer.open(url: x3f)) { error in
            XCTAssertEqual(
                error as? ProxyOpenError,
                .unsupported(fileName: "sample.x3f", uti: "unknown")
            )
        }

        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("page.pdf")
        try Data("%PDF-1.1\n".utf8).write(to: pdf)
        defer { try? FileManager.default.removeItem(at: pdf) }
        XCTAssertThrowsError(try ProxyRenderer.open(url: pdf)) { error in
            guard case .unsupported(let name, _)? = error as? ProxyOpenError else {
                return XCTFail("Expected an unsupported error, got \(error)")
            }
            XCTAssertEqual(name, "page.pdf")
        }
    }

    func testBuiltAppIsNotSandboxed() throws {
        let bundle = Bundle(identifier: "com.Win32Forth.ZImage") ?? Bundle.main
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code)
        XCTAssertEqual(created, errSecSuccess)
        let staticCode = try XCTUnwrap(code)
        var information: CFDictionary?
        let copied = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        XCTAssertEqual(copied, errSecSuccess)
        let info = try XCTUnwrap(information as? [String: Any])
        let entitlements = try XCTUnwrap(info[kSecCodeInfoEntitlementsDict as String] as? [String: Any])
        XCTAssertNotEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertNil(entitlements["com.apple.security.files.bookmarks.app-scope"])
        XCTAssertNil(entitlements["com.apple.security.files.user-selected.read-write"])
        XCTAssertNil(entitlements["com.apple.security.files.user-selected.read-only"])
        XCTAssertNil(entitlements["com.apple.security.network.client"])
        XCTAssertNil(entitlements["com.apple.security.network.server"])
        let groups = entitlements["keychain-access-groups"] as? [String]
        XCTAssertEqual(groups, ["X5YCJL3LJ8.com.Win32Forth.ZImage"])
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: ProxyRendererTests.self)
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
            return url
        }
        if let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        XCTFail("Missing test fixture \(name).\(ext)")
        throw ProxyOpenError.cannotRead("\(name).\(ext)")
    }

    private func writeRaster(width: Int, height: Int, uti: UTType, to url: URL) throws {
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
            return
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, uti.identifier as CFString, 1, nil)
        else {
            XCTFail("Could not create an image destination")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            XCTFail("Could not write \(url.lastPathComponent)")
        }
    }

    /// An RGB DNG that `CIRAWFilter` accepts on this Mac and honors `scaleFactor` for.
    /// It is not a camera mosaic. The extension selects the RAW entry point.
    /// A 3000×4 frame scales. The same layout at a few hundred rows is rejected by the RAW reader.
    private func writeSyntheticDNG(width: Int, height: Int, to url: URL) throws {
        var rgb = Data()
        rgb.reserveCapacity(width * height * 3)
        let sample = Data([20, 80, 140])
        for _ in 0..<(width * height) {
            rgb.append(sample)
        }
        let bits = Data([8, 0, 8, 0, 8, 0])
        let model = Data("ZImage\0".utf8)
        let longType: UInt16 = 4
        let shortType: UInt16 = 3
        let byteType: UInt16 = 1
        let asciiType: UInt16 = 2

        struct Entry {
            var tag: UInt16
            var type: UInt16
            var count: UInt32
            var inline: Data?
            var extraIndex: Int?
        }

        var extras: [Data] = []
        func extra(_ data: Data) -> Int {
            extras.append(data)
            return extras.count - 1
        }
        func longValue(_ value: UInt32) -> Data {
            var little = value.littleEndian
            return Data(bytes: &little, count: 4)
        }
        func shortValue(_ value: UInt16) -> Data {
            var data = Data(count: 4)
            data[0] = UInt8(value & 0xff)
            data[1] = UInt8(value >> 8)
            return data
        }

        var entries = [
            Entry(tag: 254, type: longType, count: 1, inline: longValue(0), extraIndex: nil),
            Entry(tag: 256, type: longType, count: 1, inline: longValue(UInt32(width)), extraIndex: nil),
            Entry(tag: 257, type: longType, count: 1, inline: longValue(UInt32(height)), extraIndex: nil),
            Entry(tag: 258, type: shortType, count: 3, inline: nil, extraIndex: extra(bits)),
            Entry(tag: 259, type: shortType, count: 1, inline: shortValue(1), extraIndex: nil),
            Entry(tag: 262, type: shortType, count: 1, inline: shortValue(2), extraIndex: nil),
            Entry(tag: 274, type: shortType, count: 1, inline: shortValue(1), extraIndex: nil),
            Entry(tag: 277, type: shortType, count: 1, inline: shortValue(3), extraIndex: nil),
            Entry(tag: 278, type: longType, count: 1, inline: longValue(UInt32(height)), extraIndex: nil),
            Entry(tag: 279, type: longType, count: 1, inline: longValue(UInt32(rgb.count)), extraIndex: nil),
            Entry(tag: 284, type: shortType, count: 1, inline: shortValue(1), extraIndex: nil),
            Entry(tag: 50706, type: byteType, count: 4, inline: Data([1, 4, 0, 0]), extraIndex: nil),
            Entry(tag: 50707, type: byteType, count: 4, inline: Data([1, 1, 0, 0]), extraIndex: nil),
            Entry(tag: 50708, type: asciiType, count: UInt32(model.count), inline: nil, extraIndex: extra(model)),
            Entry(tag: 273, type: longType, count: 1, inline: nil, extraIndex: nil),
        ]
        entries.sort { $0.tag < $1.tag }

        let extraOffset = 8 + 2 + entries.count * 12 + 4
        var blob = Data()
        var extraOffsets: [Int] = []
        for data in extras {
            if blob.count % 2 == 1 {
                blob.append(0)
            }
            extraOffsets.append(blob.count)
            blob.append(data)
        }
        let pixelOffset = UInt32(extraOffset + blob.count)

        var out = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
        var count = UInt16(entries.count).littleEndian
        out.append(Data(bytes: &count, count: 2))
        for entry in entries {
            var tag = entry.tag.littleEndian
            var type = entry.type.littleEndian
            var count = entry.count.littleEndian
            out.append(Data(bytes: &tag, count: 2))
            out.append(Data(bytes: &type, count: 2))
            out.append(Data(bytes: &count, count: 4))
            if entry.tag == 273 {
                var offset = pixelOffset.littleEndian
                out.append(Data(bytes: &offset, count: 4))
            } else if let index = entry.extraIndex {
                var offset = UInt32(extraOffset + extraOffsets[index]).littleEndian
                out.append(Data(bytes: &offset, count: 4))
            } else {
                var inline = entry.inline ?? Data()
                if inline.count < 4 {
                    inline.append(Data(count: 4 - inline.count))
                }
                out.append(inline.prefix(4))
            }
        }
        out.append(Data([0, 0, 0, 0]))
        XCTAssertEqual(out.count, extraOffset)
        out.append(blob)
        out.append(rgb)
        try out.write(to: url)
    }
}
