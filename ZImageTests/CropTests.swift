import CoreGraphics
import CoreImage
import XCTest
@testable import ZImage

final class CropTests: XCTestCase {
    func testCropKeepsTheLeftHalfAndTheTopHalf() {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1))
            .cropped(to: CGRect(x: 20, y: 0, width: 20, height: 20))
        let image = blue.composited(over: red)
        let context = TonePipeline.makeContext()

        let left = CropRect.apply(image, crop: NormRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(Int(left.extent.width.rounded()), 20)
        XCTAssertEqual(Int(left.extent.height.rounded()), 20)
        let leftBytes = TonePipeline.rgba8(of: left, context: context)
        XCTAssertGreaterThan(leftBytes[0], 200)
        XCTAssertLessThan(leftBytes[2], 40)

        let top = CropRect.apply(image, crop: NormRect(x: 0, y: 0, width: 1, height: 0.5))
        XCTAssertEqual(Int(top.extent.width.rounded()), 40)
        XCTAssertEqual(Int(top.extent.height.rounded()), 10)
        XCTAssertEqual(Int(top.extent.minX.rounded()), 0)
        XCTAssertEqual(Int(top.extent.minY.rounded()), 0)
    }

    func testASecondCropComposesIntoTheFirst() {
        let first = NormRect(x: 0.2, y: 0.1, width: 0.5, height: 0.4)
        let inner = NormRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let composed = CropRect.composed(inner, within: first)
        XCTAssertEqual(composed.x, 0.45, accuracy: 1e-9)
        XCTAssertEqual(composed.y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(composed.width, 0.25, accuracy: 1e-9)
        XCTAssertEqual(composed.height, 0.4, accuracy: 1e-9)

        var log = HistoryLog()
        log.commit(.setCrop(first))
        log.commit(.setCrop(composed))
        XCTAssertEqual(log.state.crop, composed)
        XCTAssertEqual(log.commands.last?.historyTitle, "Crop")
        log.undo()
        XCTAssertEqual(log.state.crop, first)
    }

    func testHandlesResizeAndADragOutsideStartsANewRectangle() {
        let start = NormRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let wider = CropMarquee.resized(start, handle: .right, by: NormPoint(x: 0.1, y: 0))
        XCTAssertEqual(wider, NormRect(x: 0.2, y: 0.2, width: 0.5, height: 0.4))
        let shorter = CropMarquee.resized(start, handle: .top, by: NormPoint(x: 0, y: 0.1))
        XCTAssertEqual(shorter, NormRect(x: 0.2, y: 0.3, width: 0.4, height: 0.3))
        let moved = CropMarquee.moved(start, by: NormPoint(x: 0.7, y: -1))
        XCTAssertEqual(moved.x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(moved.y, 0, accuracy: 1e-9)
        XCTAssertEqual(moved.width, 0.4, accuracy: 1e-9)

        let map = ImageViewMap(
            viewSize: CGSize(width: 200, height: 200),
            imageSize: CGSize(width: 100, height: 100),
            magnification: 1,
            offset: .zero
        )
        let rect = map.viewRect(for: start)
        XCTAssertEqual(Double(rect.minX), 70, accuracy: 0.1)
        XCTAssertEqual(Double(rect.minY), 70, accuracy: 0.1)
        XCTAssertEqual(Double(rect.width), 40, accuracy: 0.1)
        XCTAssertEqual(CropMarquee.hitHandle(at: CGPoint(x: rect.minX + 2, y: rect.minY + 2), in: rect), .topLeft)
        XCTAssertEqual(CropMarquee.hitHandle(at: CGPoint(x: rect.midX, y: rect.maxY), in: rect), .bottom)
        XCTAssertEqual(CropMarquee.begin(at: CGPoint(x: rect.midX, y: rect.midY), selection: start, map: map), .move)
        XCTAssertEqual(CropMarquee.begin(at: CGPoint(x: 4, y: 4), selection: start, map: map), .create)
        XCTAssertFalse(CropRect.isUsable(NormRect(x: 0, y: 0, width: 0.01, height: 0.5), pixelWidth: 100, pixelHeight: 100))
        XCTAssertTrue(CropRect.isUsable(NormRect(x: 0, y: 0, width: 0.1, height: 0.1), pixelWidth: 100, pixelHeight: 100))
    }

    func testAnOlderEditStateOpensWithoutACrop() throws {
        let data = try JSONEncoder().encode(EditState.identity)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "crop")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(EditState.self, from: stripped)
        XCTAssertNil(decoded.crop)
        XCTAssertEqual(decoded.tone, .identity)
        XCTAssertEqual(decoded.geometry, .identity)
    }
}