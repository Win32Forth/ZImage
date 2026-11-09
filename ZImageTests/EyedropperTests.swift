import CoreImage
import XCTest
@testable import ZImager

final class EyedropperTests: XCTestCase {
    private let context = TonePipeline.makeContext()

    func testPresetLabelsStayInOrder() {
        XCTAssertEqual(
            SkinPresets.all.map(\.label),
            ["Caucasian", "Asian", "Southeast Asian", "Middle Eastern", "Hispanic", "South Asian", "African"]
        )
        XCTAssertEqual(SkinPresets.all.map(\.id), ["light", "lightGolden", "mediumGolden", "mediumOlive", "mediumWarm", "mediumDeep", "deep"])
        XCTAssertEqual(SkinPresets.preset(id: "deep")?.mst, 9)
        for preset in SkinPresets.all {
            XCTAssertGreaterThanOrEqual(preset.lab.a, 10, preset.label)
            XCTAssertGreaterThanOrEqual(preset.lab.b, 14, preset.label)
            let hex = preset.sRGBHex
            let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
            let red = Double((value >> 16) & 0xff)
            let green = Double((value >> 8) & 0xff)
            let blue = Double(value & 0xff)
            XCTAssertGreaterThan(red, green, preset.label)
            XCTAssertGreaterThan(green, blue, preset.label)
        }
    }

    func testNoUIStringOrHistoryLabelUsesTheReplacedWord() {
        let banned = "Negro"
        for text in EyedropperCopy.userFacing {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(banned), text)
        }
        let image = Eyedropper.solid(0.5, 0.4, 0.3, side: 32)
        let point = CGPoint(x: 16, y: 16)
        let white = Eyedropper.whiteGrade(image: image, bitmapPoint: point, context: context, base: .identity)
        XCTAssertFalse(white.label.localizedCaseInsensitiveContains(banned))
        for preset in SkinPresets.all {
            let grade = Eyedropper.skinGrade(image: image, bitmapPoint: point, preset: preset, context: context, base: .identity)
            XCTAssertEqual(grade.label, preset.label)
            XCTAssertFalse(grade.label.localizedCaseInsensitiveContains(banned))
        }
    }

    func testWhiteModeBringsAWarmPatchNearNeutral() {
        let image = Eyedropper.solid(0.5, 0.4, 0.3, side: 16)
        let grade = Eyedropper.whiteGrade(
            image: image,
            bitmapPoint: CGPoint(x: 8, y: 8),
            context: context,
            base: .identity
        )
        XCTAssertEqual(grade.label, "White")
        XCTAssertNil(grade.tone.skinGrade)
        XCTAssertGreaterThanOrEqual(grade.tone.temperature, 2000)
        XCTAssertLessThanOrEqual(grade.tone.temperature, 50000)
        XCTAssertGreaterThanOrEqual(grade.tone.tint, -150)
        XCTAssertLessThanOrEqual(grade.tone.tint, 150)

        let graded = TonePipeline.apply(base: image, tone: grade.tone, longEdge: 16)
        let pixel = Eyedropper.linearSamples(graded, context: context)[0]
        let sample = Eyedropper.lab(pixel)
        XCTAssertLessThanOrEqual(hypot(sample.a, sample.b), 2, "Lab \(sample) temperature \(grade.tone.temperature) tint \(grade.tone.tint)")
    }

    func testSkinModeShiftsACoolPatchTowardThePresetAndKeepsLightness() {
        let target = SkinPresets.preset(id: "light")!
        XCTAssertEqual(target.label, "Caucasian")
        let p3 = LinearDisplayP3.p3(L: 60, a: 2, b: 4)
        let image = Eyedropper.solid(p3.r, p3.g, p3.b, side: 32)
        let grade = Eyedropper.skinGrade(
            image: image,
            bitmapPoint: CGPoint(x: 16, y: 16),
            preset: target,
            context: context,
            base: .identity
        )
        XCTAssertEqual(grade.label, "Caucasian")
        XCTAssertEqual(grade.tone.skinGrade?.presetID, "light")
        XCTAssertEqual(grade.tone.skinGrade?.target.a ?? 0, target.lab.a, accuracy: 0.0001)
        XCTAssertEqual(grade.tone.skinGrade?.target.b ?? 0, target.lab.b, accuracy: 0.0001)

        let before = Eyedropper.lab((r: p3.r, g: p3.g, b: p3.b))
        let graded = TonePipeline.apply(base: image, tone: grade.tone, longEdge: 32)
        let after = Eyedropper.lab(Eyedropper.linearSamples(graded, context: context)[0])
        XCTAssertLessThan(abs(after.L - before.L), 1)
        XCTAssertLessThan(abs(after.a - target.lab.a), abs(before.a - target.lab.a))
        XCTAssertLessThan(abs(after.b - target.lab.b), abs(before.b - target.lab.b))
    }
}
