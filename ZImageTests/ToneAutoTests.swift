import CoreGraphics
import CoreImage
import XCTest
@testable import ZImager

final class ToneAutoTests: XCTestCase {
    func testDarkFieldRaisesExposureWithoutContrastOrLoweredBlacks() {
        let levels = ToneAuto.levels(rgba: flat(byte: 46))
        let tone = ToneAuto.applying(levels!, to: .identity)
        XCTAssertGreaterThan(tone.exposureEV, 1.5)
        XCTAssertEqual(tone.contrast, 0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(tone.blacks, 0)
    }

    func testBrightFieldLowersExposure() {
        let levels = ToneAuto.levels(rgba: flat(byte: 210))
        let tone = ToneAuto.applying(levels!, to: .identity)
        XCTAssertLessThan(tone.exposureEV, 0)
    }

    func testAutoLeavesDetailsTextureAndClarity() {
        var tone = ToneState.identity
        tone.details = 0.4
        tone.texture = 0.2
        tone.clarity = -0.3
        let levels = ToneAuto.levels(rgba: flat(byte: 46))
        let next = ToneAuto.applying(levels!, to: tone)
        XCTAssertEqual(next.details, 0.4, accuracy: 1e-9)
        XCTAssertEqual(next.texture, 0.2, accuracy: 1e-9)
        XCTAssertEqual(next.clarity, -0.3, accuracy: 1e-9)
    }

    func testDarkGrayStaysLighterAfterTheTonePipeline() {
        let source = srgbPatch(0.18)
        let before = srgbByte(source)
        let levels = ToneAuto.levels(rgba: flat(byte: before))
        let tone = ToneAuto.applying(levels!, to: .identity)
        let graded = TonePipeline.apply(base: source, tone: tone, longEdge: 32)
        let after = srgbByte(graded)
        XCTAssertGreaterThan(after, before)
    }

    private func flat(byte: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64 * 4)
        for index in 0..<64 {
            bytes[index * 4] = byte
            bytes[index * 4 + 1] = byte
            bytes[index * 4 + 2] = byte
            bytes[index * 4 + 3] = 255
        }
        return bytes
    }

    private func srgbPatch(_ value: CGFloat) -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(colorSpace: space, components: [value, value, value, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return CIImage(cgImage: context.makeImage()!)
    }

    private func srgbByte(_ image: CIImage) -> UInt8 {
        let context = TonePipeline.makeContext()
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &bytes,
            rowBytes: 4,
            bounds: CGRect(x: 16, y: 16, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        return bytes[0]
    }
}
