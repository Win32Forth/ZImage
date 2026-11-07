import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ZImage

final class ZoomControllerTests: XCTestCase {
    func testClampHoldsTheSliderRange() {
        var zoom = ZoomController()
        zoom.magnification = 9
        zoom.clampToRange()
        XCTAssertEqual(zoom.magnification, ZoomController.maximumMagnification, accuracy: 1e-12)
        XCTAssertEqual(zoom.factorLabel, "4.00×")

        zoom.magnification = 0.01
        zoom.clampToRange()
        XCTAssertEqual(zoom.magnification, ZoomController.standardMinimum, accuracy: 1e-12)
        XCTAssertEqual(zoom.factorLabel, "0.10×")
    }

    func testHandCommandClickZoomsAndCommandOptionClickZoomsOut() {
        XCTAssertEqual(CanvasTool.hand.clickZoom(command: true, option: false), .zoomIn)
        XCTAssertEqual(CanvasTool.hand.clickZoom(command: true, option: true), .zoomOut)
        XCTAssertNil(CanvasTool.hand.clickZoom(command: false, option: false))
        XCTAssertNil(CanvasTool.hand.clickZoom(command: false, option: true))
        XCTAssertEqual(CanvasTool.zoom.clickZoom(command: false, option: false), .zoomIn)
        XCTAssertEqual(CanvasTool.zoom.clickZoom(command: false, option: true), .zoomOut)
        XCTAssertNil(CanvasTool.eyedropper.clickZoom(command: true, option: false))
    }

    func testClickAndOptionClickStepBySquareRootOfTwo() {
        var zoom = ZoomController()
        let view = CGSize(width: 800, height: 600)
        let anchor = CGPoint(x: 100, y: 80)
        zoom.zoomIn(about: anchor, viewSize: view)
        XCTAssertEqual(zoom.magnification, ZoomController.sqrtTwo, accuracy: 1e-12)
        zoom.zoomOut(about: anchor, viewSize: view)
        XCTAssertEqual(zoom.magnification, 1, accuracy: 1e-9)
    }

    func testFitOfATwentyThousandPixelImageDropsToTheFloor() {
        var zoom = ZoomController()
        zoom.fit(imageLongEdge: 20_000, viewLongEdge: 500)
        XCTAssertEqual(zoom.sliderMinimum, 0.05, accuracy: 1e-12)
        XCTAssertEqual(zoom.magnification, 0.05, accuracy: 1e-12)
        XCTAssertEqual(zoom.offset, .zero)
    }

    func testFitInsideTheRangeRestoresTheStandardMinimum() {
        var zoom = ZoomController()
        zoom.fit(imageLongEdge: 20_000, viewLongEdge: 500)
        zoom.fit(imageLongEdge: 1000, viewLongEdge: 500)
        XCTAssertEqual(zoom.sliderMinimum, 0.1, accuracy: 1e-12)
        XCTAssertEqual(zoom.magnification, 0.5, accuracy: 1e-12)
    }

    @MainActor
    func testTwentyZoomChangesLeaveTheProxyRenderCountUnchanged() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-zoom-\(UUID().uuidString).jpg")
        try writeJPEG(width: 64, height: 40, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = EditorModel()
        model.openSecurityScopedFile(at: url)
        let deadline = Date().addingTimeInterval(5)
        while model.proxy == nil, model.canvasMessage == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(model.proxy)
        let renders = model.proxyRenderCount
        XCTAssertGreaterThan(renders, 0)
        let tone = model.draftTone
        for _ in 0..<20 {
            model.zoomIn(about: CGPoint(x: 40, y: 30), in: CGSize(width: 800, height: 600))
        }
        XCTAssertEqual(model.draftTone, tone)
        XCTAssertEqual(model.proxyRenderCount, renders)
        XCTAssertEqual(model.zoom.magnification, 4, accuracy: 1e-9)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(model.proxyRenderCount, renders)
        XCTAssertEqual(model.tileRequestCount, 1)
    }

    private func writeJPEG(width: Int, height: Int, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = {
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }() else {
            XCTFail("Could not write a JPEG")
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            XCTFail("Could not write a JPEG")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            XCTFail("Could not write a JPEG")
        }
    }
}
