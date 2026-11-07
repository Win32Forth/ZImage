import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import ZImage

@MainActor
final class PDFImportTests: XCTestCase {
    func testTwoPagePDFDoesNotFlattenOnOpen() throws {
        let url = temporaryFile("two-page.pdf")
        try writePDF(pages: [(200, 100), (300, 120)], to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try PDFImport.load(url: url)
        XCTAssertEqual(document.pageCount, 2)

        let model = EditorModel()
        model.openSecurityScopedFile(at: url)
        XCTAssertTrue(model.showsPDFPicker)
        XCTAssertEqual(model.pdfPageIndex, 0)
        XCTAssertEqual(model.pdfDocument?.pageCount, 2)
        XCTAssertNil(model.proxy)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.editBase)

        model.openSelectedPDFPage()
        let base = try XCTUnwrap(model.editBase)
        XCTAssertEqual(base.pageIndex, 0)
        XCTAssertEqual(base.pixelWidth, 200)
        XCTAssertEqual(base.pixelHeight, 100)
        XCTAssertLessThanOrEqual(base.longEdge, PDFImport.maxEditBaseLongEdge)
        XCTAssertEqual(model.pdfDocument?.pageCount, 2)
        XCTAssertEqual(model.decodeSupport, .full)
        XCTAssertFalse(model.showsPDFPicker)
        XCTAssertNotNil(model.proxy)
        XCTAssertLessThanOrEqual(model.proxy?.longEdge ?? 0, 2560)
    }

    func testOversizedMediaBoxRendersAtMost8192() throws {
        let url = temporaryFile("wide-page.pdf")
        try writePDF(pages: [(12_000, 3_000)], to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try PDFImport.load(url: url)
        XCTAssertEqual(document.pageCount, 1)
        let rendered = try PDFImport.render(document: document, pageIndex: 0)
        XCTAssertLessThanOrEqual(rendered.editBase.longEdge, 8192)
        XCTAssertGreaterThan(rendered.editBase.longEdge, 8000)
        XCTAssertEqual(rendered.editBase.pageIndex, 0)
        XCTAssertEqual(rendered.image.width, rendered.editBase.pixelWidth)
        XCTAssertEqual(rendered.image.height, rendered.editBase.pixelHeight)
        XCTAssertEqual(document.pageCount, 1)
    }

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zimage-\(UUID().uuidString)-\(name)")
    }

    private func writePDF(pages: [(CGFloat, CGFloat)], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            XCTFail("Could not open a PDF consumer")
            return
        }
        var first = CGRect(x: 0, y: 0, width: pages[0].0, height: pages[0].1)
        guard let context = CGContext(consumer: consumer, mediaBox: &first, nil) else {
            XCTFail("Could not open a PDF context")
            return
        }
        for (width, height) in pages {
            var box = CGRect(x: 0, y: 0, width: width, height: height)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            context.setFillColor(CGColor(red: 0.85, green: 0.4, blue: 0.15, alpha: 1))
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
