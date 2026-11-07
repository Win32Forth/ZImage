import CoreGraphics
import CoreImage
import XCTest
@testable import ZImage

final class TonePipelineTests: XCTestCase {
    func testIdentityMapsLeaveContrastSaturationAndHighlightsAtOne() {
        XCTAssertEqual(ToneMaps.contrastInput(0), 1, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.contrastInput(1), 4, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.contrastInput(-1), 0.25, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.saturationInput(0), 1, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.saturationInput(-1), 0, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.saturationInput(1), 2, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.highlightAmount(0), 1, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.highlightAmount(1), 1, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.highlightAmount(-1), 0.3, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.blacksY(0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.whitesY(0), 0.75, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.blacksY(-1), 0, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.blacksY(1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.whitesY(-1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.whitesY(1), 1, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.scaledRadius(longEdge: 2560, coefficient: 32), 32, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.scaledRadius(longEdge: 2560, coefficient: 1.5), 1.5, accuracy: 0.0001)
        XCTAssertEqual(ToneMaps.scaledRadius(longEdge: 2560, coefficient: 30), 30, accuracy: 0.0001)
    }

    func testContextWorkingFormatIsHalfFloat() {
        XCTAssertEqual(TonePipeline.makeContext().workingFormat, .RGBAh)
    }

    func testDefaultToneMatchesUnfilteredMidGray() {
        let patch = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let context = TonePipeline.makeContext()
        let plain = TonePipeline.rgba8(of: patch, context: context)
        let identity = TonePipeline.rgba8(
            of: TonePipeline.apply(base: patch, tone: .identity, longEdge: 16),
            context: context
        )
        XCTAssertEqual(identity, plain)
    }

    func testTwoExposuresChangeTheDownsampledHash() throws {
        let image = try fixtureJPEG()
        let context = TonePipeline.makeContext()
        var boosted = ToneState.identity
        boosted.exposureEV = 1
        let edge = max(image.extent.width, image.extent.height)
        let original = downsampledHash(image, context: context)
        let untouched = downsampledHash(
            TonePipeline.apply(base: image, tone: .identity, longEdge: edge),
            context: context
        )
        let brighter = downsampledHash(
            TonePipeline.apply(base: image, tone: boosted, longEdge: edge),
            context: context
        )
        XCTAssertEqual(untouched, original)
        XCTAssertNotEqual(brighter, original)
    }

    @MainActor
    func testSixToneGesturesUndoToIdentity() {
        let model = EditorModel()
        for value in [0.2, -0.4, 0.6, -0.2, 0.8, -0.6] {
            model.beginToneDrag()
            model.nudgeTone(\.exposureEV, to: value, label: "Exposure")
            model.endToneDrag()
        }
        XCTAssertEqual(model.log.cursor, 6)
        XCTAssertEqual(model.log.state.tone.exposureEV, -0.6, accuracy: 0.0001)
        XCTAssertEqual(model.log.commands.last?.historyTitle, "Exposure")
        for _ in 0..<6 {
            model.undo()
        }
        XCTAssertEqual(model.log.state, .identity)
        XCTAssertEqual(model.draftTone, .identity)
        XCTAssertFalse(model.log.canUndo)
    }

    @MainActor
    func testKeyboardNudgesCommitOnceAfterIdle() async throws {
        let model = EditorModel()
        model.nudgeTone(\.contrast, to: 0.2, label: "Contrast")
        model.nudgeTone(\.contrast, to: 0.4, label: "Contrast")
        XCTAssertEqual(model.log.commands.count, 0)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.log.commands.count, 1)
        XCTAssertEqual(model.log.state.tone.contrast, 0.4, accuracy: 0.0001)
        XCTAssertEqual(model.log.commands[0].historyTitle, "Contrast")
    }

    func testDehazeKernelROIIsTheOutputTile() throws {
        let tile = CGRect(x: 32, y: 16, width: 64, height: 64)
        let roi = DehazeKernel.roi(forInput: 0, arguments: ["dehaze": 0.4], outputRect: tile)
        XCTAssertEqual(roi, tile)
        XCTAssertNotEqual(roi, CGRect(x: 0, y: 0, width: 4096, height: 4096))

        let patch = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let context = TonePipeline.makeContext()
        let copied = try DehazeKernel.apply(
            withExtent: patch.extent,
            inputs: [patch, patch],
            arguments: ["dehaze": 0]
        )
        XCTAssertEqual(TonePipeline.rgba8(of: copied, context: context), TonePipeline.rgba8(of: patch, context: context))

        DehazeTileTrace.reset()
        var tone = ToneState.identity
        tone.dehaze = 1
        let hazed = TonePipeline.apply(base: patch, tone: tone, longEdge: 64)
        let before = TonePipeline.rgba8(of: patch, context: context)
        let after = TonePipeline.rgba8(of: hazed, context: context)
        XCTAssertFalse(DehazeTileTrace.inputPixelCounts.isEmpty)
        for count in DehazeTileTrace.inputPixelCounts {
            XCTAssertLessThanOrEqual(count, 64 * 64, "Dehaze input region must stay the output tile")
        }
        XCTAssertLessThan(meanRGB(after), meanRGB(before))
    }

    func testNegativeTextureSoftensACheckerboard() {
        let checker = checkerboard(width: 32, height: 32)
        var tone = ToneState.identity
        tone.texture = -1
        let softened = TonePipeline.apply(base: checker, tone: tone, longEdge: 2560)
        let context = TonePipeline.makeContext()
        let before = edgeEnergy(TonePipeline.rgba8(of: checker, context: context), width: 32)
        let after = edgeEnergy(TonePipeline.rgba8(of: softened, context: context), width: 32)
        XCTAssertLessThan(after, before * 0.85)
    }

    func testLinearDisplayP3WhiteRoundTrips() {
        let white = LinearDisplayP3.xyz(r: 1, g: 1, b: 1)
        let lab = LinearDisplayP3.lab(x: white.x, y: white.y, z: white.z)
        XCTAssertEqual(lab.L, 100, accuracy: 0.05)
        XCTAssertEqual(lab.a, 0, accuracy: 0.05)
        XCTAssertEqual(lab.b, 0, accuracy: 0.05)
        let back = LinearDisplayP3.p3(L: lab.L, a: lab.a, b: lab.b)
        XCTAssertEqual(back.r, 1, accuracy: 0.001)
        XCTAssertEqual(back.g, 1, accuracy: 0.001)
        XCTAssertEqual(back.b, 1, accuracy: 0.001)
    }

    func testSkinGradeChangesAColorPatch() {
        let patch = CIImage(color: CIColor(red: 0.6, green: 0.3, blue: 0.2, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        var tone = ToneState.identity
        tone.skinGrade = SkinGrade(
            presetID: "deep",
            sample: LabColor(L: 50, a: 10, b: 10),
            target: LabColor(L: 50, a: 30, b: 10),
            deltaA: 25,
            deltaB: -10
        )
        let context = TonePipeline.makeContext()
        let plain = TonePipeline.rgba8(of: TonePipeline.apply(base: patch, tone: .identity, longEdge: 8), context: context)
        let graded = TonePipeline.rgba8(of: TonePipeline.apply(base: patch, tone: tone, longEdge: 8), context: context)
        XCTAssertNotEqual(graded, plain)
    }

    private func fixtureJPEG() throws -> CIImage {
        let bundle = Bundle(for: TonePipelineTests.self)
        let url = bundle.url(forResource: "proxy-small", withExtension: "jpg", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "proxy-small", withExtension: "jpg")
        let unwrapped = try XCTUnwrap(url)
        return try XCTUnwrap(CIImage(contentsOf: unwrapped))
    }

    private func downsampledHash(_ image: CIImage, context: CIContext) -> UInt64 {
        let scale = min(8 / image.extent.width, 8 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bytes = TonePipeline.rgba8(of: scaled, context: context)
        var hash: UInt64 = 14695981039346656037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    private func meanRGB(_ bytes: [UInt8]) -> Double {
        var sum = 0
        var count = 0
        var index = 0
        while index + 3 < bytes.count {
            sum += Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])
            count += 3
            index += 4
        }
        return Double(sum) / Double(max(count, 1))
    }

    private func edgeEnergy(_ bytes: [UInt8], width: Int) -> Double {
        let height = bytes.count / (width * 4)
        var energy = 0.0
        guard width > 1, height > 1 else { return 0 }
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let left = (y * width + x) * 4
                let right = left + 4
                energy += abs(Double(bytes[left]) - Double(bytes[right]))
            }
        }
        return energy
    }

    private func checkerboard(width: Int, height: Int) -> CIImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for y in 0..<height {
            for x in 0..<width {
                let on = (x / 2 + y / 2).isMultiple(of: 2)
                context.setFillColor(on
                    ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                    : CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return CIImage(cgImage: context.makeImage()!)
    }
}
