import XCTest
@testable import ZImager

final class InspectorSliderTests: XCTestCase {
    func testDoubleClickReturnsTheKnobToTheMiddleExceptTemperatureAndLens() {
        XCTAssertEqual(SliderReset.middle(of: -5...5), 0, accuracy: 1e-9)
        XCTAssertEqual(SliderReset.middle(of: -1...1), 0, accuracy: 1e-9)
        XCTAssertEqual(SliderReset.middle(of: 0...1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SliderReset.middle(of: -150...150), 0, accuracy: 1e-9)
        XCTAssertEqual(SliderReset.middle(of: -45...45), 0, accuracy: 1e-9)
        XCTAssertEqual(SliderReset.middle(of: -0.5...1.5), 0.5, accuracy: 1e-9)
        XCTAssertTrue(SliderReset.resets(title: "Exposure"))
        XCTAssertFalse(SliderReset.resets(title: "Dehaze"))
        XCTAssertTrue(SliderReset.resets(title: "Straighten"))
        XCTAssertTrue(SliderReset.resets(title: "Top left X"))
        XCTAssertFalse(SliderReset.resets(title: "Temperature"))
        XCTAssertFalse(SliderReset.resets(title: "k1"))
        XCTAssertFalse(SliderReset.resets(title: "k2"))
    }
}