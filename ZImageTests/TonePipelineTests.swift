import CoreGraphics
import CoreImage
import XCTest
@testable import ZImager

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

    func testPositiveDetailsRaisesEdgeEnergy() {
        let step = grayStep(width: 32, height: 16)
        var tone = ToneState.identity
        tone.details = 1
        let sharp = TonePipeline.apply(base: step, tone: tone, longEdge: 2560)
        let context = TonePipeline.makeContext()
        let before = edgeEnergy(TonePipeline.rgba8(of: step, context: context), width: 32)
        let after = edgeEnergy(TonePipeline.rgba8(of: sharp, context: context), width: 32)
        XCTAssertGreaterThan(after, before)
    }

    func testVignetteCenterStaysClearAndTheCornerIsCovered() {
        let frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        let center = VignetteShape.coverage(x: 32, y: 32, frame: frame, midpoint: 0.5, roundness: 0, feather: 0.5)
        let corner = VignetteShape.coverage(x: 0.5, y: 0.5, frame: frame, midpoint: 0.5, roundness: 0, feather: 0.5)
        XCTAssertEqual(center, 0, accuracy: 0.001)
        XCTAssertEqual(corner, 1, accuracy: 0.001)
        let squared = VignetteShape.coverage(x: 0.5, y: 0.5, frame: frame, midpoint: 0.5, roundness: -1, feather: 0.5)
        XCTAssertLessThan(squared, corner)
    }

    func testRoundnessDarkensTheLongEdgeOfAWideFrame() {
        let frame = CGRect(x: 0, y: 0, width: 64, height: 16)
        let ellipse = VignetteShape.coverage(x: 0.5, y: 8, frame: frame, midpoint: 0.5, roundness: 0, feather: 0.5)
        let circle = VignetteShape.coverage(x: 0.5, y: 8, frame: frame, midpoint: 0.5, roundness: 1, feather: 0.5)
        XCTAssertGreaterThan(circle, ellipse)
    }

    func testVignetteShadeDarkensAndLiftsWithoutCrushingHighlights() {
        XCTAssertEqual(VignetteShape.shade(sample: 0.5, amount: -1, coverage: 1), 0, accuracy: 0.0001)
        XCTAssertEqual(VignetteShape.shade(sample: 0.5, amount: -1, coverage: 0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(VignetteShape.shade(sample: 0.5, amount: 1, coverage: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(VignetteShape.shade(sample: 1.5, amount: 1, coverage: 1), 1.5, accuracy: 0.0001)
    }

    func testNegativeVignetteDarkensTheCornerAndLeavesTheCenter() {
        let patch = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        var tone = ToneState.identity
        tone.vignetteAmount = -1
        tone.vignetteMidpoint = 0.2
        tone.vignetteFeather = 0.2
        let context = TonePipeline.makeContext()
        let plain = TonePipeline.apply(base: patch, tone: .identity, longEdge: 64)
        let graded = TonePipeline.apply(base: patch, tone: tone, longEdge: 64)
        let plainCenter = red(of: plain, x: 32, y: 16, context: context)
        let center = red(of: graded, x: 32, y: 16, context: context)
        let corner = red(of: graded, x: 1, y: 1, context: context)
        XCTAssertEqual(center, plainCenter, accuracy: 3)
        XCTAssertLessThan(corner, center / 2)
    }

    func testPositiveVignetteLiftsTheCorner() {
        let patch = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        var tone = ToneState.identity
        tone.vignetteAmount = 1
        tone.vignetteMidpoint = 0.2
        tone.vignetteFeather = 0.2
        let context = TonePipeline.makeContext()
        let graded = TonePipeline.apply(base: patch, tone: tone, longEdge: 64)
        let center = red(of: graded, x: 32, y: 16, context: context)
        let corner = red(of: graded, x: 1, y: 1, context: context)
        XCTAssertGreaterThan(corner, center + 20)
    }

    func testZeroVignetteAmountMatchesThePlainPicture() {
        let patch = CIImage(color: CIColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        var tone = ToneState.identity
        tone.vignetteMidpoint = 0
        tone.vignetteRoundness = 1
        tone.vignetteFeather = 0
        let context = TonePipeline.makeContext()
        let plain = TonePipeline.rgba8(of: patch, context: context)
        let graded = TonePipeline.rgba8(
            of: TonePipeline.apply(base: patch, tone: tone, longEdge: 16),
            context: context
        )
        XCTAssertEqual(graded, plain)
    }

    func testOlderToneWithoutVignetteDecodesAsNone() throws {
        let data = try JSONEncoder().encode(ToneState.identity)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "vignetteAmount")
        object.removeValue(forKey: "vignetteMidpoint")
        object.removeValue(forKey: "vignetteRoundness")
        object.removeValue(forKey: "vignetteFeather")
        object.removeValue(forKey: "vignetteCenterX")
        object.removeValue(forKey: "vignetteCenterY")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ToneState.self, from: stripped)
        XCTAssertEqual(decoded.vignetteAmount, 0)
        XCTAssertEqual(decoded.vignetteMidpoint, 0.5)
        XCTAssertEqual(decoded.vignetteRoundness, 0)
        XCTAssertEqual(decoded.vignetteFeather, 0.5)
        XCTAssertEqual(decoded.vignetteCenterX, 0)
        XCTAssertEqual(decoded.vignetteCenterY, 0)
        XCTAssertEqual(decoded, .identity)
    }

    func testVignetteCenterMovesTheDarkEdge() {
        let patch = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        var tone = ToneState.identity
        tone.vignetteAmount = -1
        tone.vignetteMidpoint = 0.2
        tone.vignetteFeather = 0.2
        tone.vignetteCenterX = 0.8
        let context = TonePipeline.makeContext()
        let shifted = TonePipeline.apply(base: patch, tone: tone, longEdge: 64)
        let left = red(of: shifted, x: 1, y: 16, context: context)
        let right = red(of: shifted, x: 62, y: 16, context: context)
        XCTAssertLessThan(left, right)

        tone.vignetteCenterX = 0
        tone.vignetteCenterY = 0.8
        let lifted = TonePipeline.apply(base: patch, tone: tone, longEdge: 64)
        let bottom = red(of: lifted, x: 32, y: 1, context: context)
        let top = red(of: lifted, x: 32, y: 30, context: context)
        XCTAssertLessThan(bottom, top)
    }

    func testLinearCurveStaysTheDiagonalPastTheEnds() {
        XCTAssertEqual(ToneCurve.linear.evaluate(0.37), 0.37, accuracy: 0.0001)
        XCTAssertEqual(ToneCurve.linear.evaluate(1.4), 1.4, accuracy: 0.0001)
        XCTAssertEqual(ToneCurve.linear.evaluate(-0.25), -0.25, accuracy: 0.0001)
        let lookup = CurveLookup(.identity)
        XCTAssertEqual(lookup.red[0], 0, accuracy: 0.0001)
        XCTAssertEqual(lookup.red[255], 1, accuracy: 0.0001)
        XCTAssertEqual(Double(lookup.red[128]), 128.0 / 255, accuracy: 0.002)
        XCTAssertEqual(lookup.lowR, 1, accuracy: 0.01)
        XCTAssertEqual(lookup.highG, 1, accuracy: 0.01)
    }

    func testCurvePresetsPassThroughTheirHandles() {
        for preset in CurvePreset.allCases {
            let curve = preset.curve
            XCTAssertGreaterThanOrEqual(curve.points.count, 2)
            XCTAssertEqual(curve.points.first?.x ?? -1, 0, accuracy: 0.0001)
            XCTAssertEqual(curve.points.last?.x ?? -1, 1, accuracy: 0.0001)
            for index in 1..<curve.points.count {
                XCTAssertGreaterThan(curve.points[index].x, curve.points[index - 1].x)
            }
            for point in curve.points {
                XCTAssertEqual(curve.evaluate(point.x), point.y, accuracy: 0.0001)
            }
        }
        XCTAssertTrue(CurvePreset.linear.curve.isLinear)
        XCTAssertTrue(CurvePreset.linear.matches(.identity))
        XCTAssertFalse(CurvePreset.punch.curve.isLinear)
        XCTAssertEqual(CurvePreset.matte.curve.evaluate(0), 0.09, accuracy: 0.0001)
        XCTAssertEqual(CurvePreset.matte.curve.evaluate(1), 0.88, accuracy: 0.0001)
        XCTAssertEqual(CurvePreset.punch.curve.evaluate(0.22), 0.12, accuracy: 0.0001)
        XCTAssertEqual(CurvePreset.punch.curve.evaluate(0.78), 0.88, accuracy: 0.0001)
        XCTAssertEqual(CurvePreset.filmMoody.curve.evaluate(0), 0.04, accuracy: 0.0001)
        XCTAssertEqual(CurvePreset.loFi.curve.evaluate(1), 0.84, accuracy: 0.0001)
        XCTAssertLessThan(CurvePreset.punch.curve.evaluate(0.22), 0.22)
        XCTAssertGreaterThan(CurvePreset.punch.curve.evaluate(0.78), 0.78)
    }

    func testCurveHandlesClampAndStayWithinEight() {
        guard let added = ToneCurve.linear.inserting(x: 0.4) else {
            XCTFail("The curve did not take a handle")
            return
        }
        XCTAssertEqual(added.index, 1)
        XCTAssertEqual(added.curve.points.count, 3)
        XCTAssertEqual(added.curve.evaluate(0.4), 0.4, accuracy: 0.001)
        let moved = added.curve.moving(index: 1, x: 0.1, y: 0.8)
        XCTAssertEqual(moved.points[1].x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(moved.points[1].y, 0.8, accuracy: 0.0001)
        XCTAssertEqual(moved.removing(index: 1).points.count, 2)
        XCTAssertEqual(ToneCurve.linear.removing(index: 0), ToneCurve.linear)
        let lifted = ToneCurve.linear.moving(index: 0, x: 0.5, y: 0.15)
        XCTAssertEqual(lifted.points[0].x, 0, accuracy: 0.0001)
        XCTAssertEqual(lifted.points[0].y, 0.15, accuracy: 0.0001)
        XCTAssertEqual(lifted.resettingEndpoint(0).points[0].y, 0, accuracy: 0.0001)
        let clamped = CurvePreset.punch.curve.moving(index: 1, x: 0.99, y: 0.2)
        XCTAssertEqual(clamped.points[1].x, 0.48, accuracy: 0.0001)
        XCTAssertEqual(clamped.points[1].y, 0.2, accuracy: 0.0001)
        var crowded = [CurvePoint(x: 0, y: 0)]
        for index in 1...10 {
            crowded.append(CurvePoint(x: Double(index) / 11, y: Double(index) / 11))
        }
        crowded.append(CurvePoint(x: 1, y: 1))
        let limited = ToneCurve(points: crowded)
        XCTAssertEqual(limited.points.count, ToneCurve.maxPoints)
        XCTAssertEqual(limited.points.first?.x ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(limited.points.last?.x ?? -1, 1, accuracy: 0.0001)
        XCTAssertNil(limited.inserting(x: 0.5))
    }

    func testMasterCurveFeedsTheChannelLookup() {
        var curves = ToneCurves.identity
        curves.master = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0.5)])
        curves.red = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0)])
        let lookup = CurveLookup(curves)
        XCTAssertEqual(lookup.red[255], 0, accuracy: 0.0001)
        XCTAssertEqual(lookup.green[255], 0.5, accuracy: 0.01)
        XCTAssertEqual(lookup.blue[128], Float(128.0 / 255 * 0.5), accuracy: 0.02)
    }

    func testToneCurveDarkensMidGrayAndALinearCurveDoesNot() {
        let patch = CIImage(color: CIColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let context = TonePipeline.makeContext()
        let plain = TonePipeline.rgba8(of: patch, context: context)
        let identity = TonePipeline.rgba8(
            of: TonePipeline.apply(base: patch, tone: .identity, longEdge: 8),
            context: context
        )
        var bent = ToneState.identity
        bent.curves.master = ToneCurve(points: [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 1, y: 0.35),
        ])
        let graded = TonePipeline.rgba8(
            of: TonePipeline.apply(base: patch, tone: bent, longEdge: 8),
            context: context
        )
        XCTAssertEqual(identity, plain)
        XCTAssertLessThan(graded[0], plain[0] / 2)
    }

    func testRedCurvePullsRedDownAndLeavesGreen() {
        let patch = CIImage(color: CIColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let context = TonePipeline.makeContext()
        let plain = TonePipeline.rgba8(of: patch, context: context)
        var bent = ToneState.identity
        bent.curves.red = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0)])
        let graded = TonePipeline.rgba8(
            of: TonePipeline.apply(base: patch, tone: bent, longEdge: 8),
            context: context
        )
        XCTAssertLessThan(graded[0], 15)
        XCTAssertLessThan(abs(Int(graded[1]) - Int(plain[1])), 8)
    }

    func testCurveHistogramCountsEachChannel() {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = 255
        bytes[1] = 0
        bytes[2] = 10
        bytes[3] = 255
        bytes[4] = 255
        bytes[5] = 0
        bytes[6] = 10
        bytes[7] = 0
        let histogram = CurveHistogram.make(rgba: bytes)
        XCTAssertEqual(histogram.red[255], 1)
        XCTAssertEqual(histogram.green[0], 1)
        XCTAssertEqual(histogram.blue[10], 1)
        XCTAssertEqual(histogram.luma.reduce(0, +), 1)
    }

    func testCurveRoundTripsAndAnOlderToneStaysLinear() throws {
        var tone = ToneState.identity
        tone.curves.master = CurvePreset.punch.curve
        tone.curves.red = ToneCurve(points: [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.4, y: 0.5),
            CurvePoint(x: 1, y: 1),
        ])
        let decoded = try JSONDecoder().decode(ToneState.self, from: JSONEncoder().encode(tone))
        XCTAssertEqual(decoded.curves, tone.curves)
        let identity = try JSONEncoder().encode(ToneState.identity)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: identity) as? [String: Any])
        object.removeValue(forKey: "curves")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let old = try JSONDecoder().decode(ToneState.self, from: stripped)
        XCTAssertEqual(old.curves, .identity)
        XCTAssertEqual(old, .identity)
    }

    func testOlderToneWithoutDetailsStaysAtZero() throws {
        let data = try JSONEncoder().encode(ToneState.identity)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "details")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ToneState.self, from: stripped)
        XCTAssertEqual(decoded.details, 0)
        XCTAssertEqual(decoded, .identity)
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

    private func red(of image: CIImage, x: CGFloat, y: CGFloat, context: CIContext) -> Int {
        let crop = image.cropped(to: CGRect(x: x, y: y, width: 1, height: 1))
        let bytes = TonePipeline.rgba8(of: crop, context: context)
        return Int(bytes.first ?? 0)
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

    private func grayStep(width: Int, height: Int) -> CIImage {
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
                let shade: CGFloat = x < width / 2 ? 0.35 : 0.65
                context.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return CIImage(cgImage: context.makeImage()!)
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
