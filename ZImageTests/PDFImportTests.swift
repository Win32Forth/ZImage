import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import ZImager

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

    func testOpenUsesThePageNumberThatWasClicked() throws {
        let url = temporaryFile("six-color.pdf")
        let colors = [
            CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
            CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
            CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1),
            CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 1),
            CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1),
        ]
        try writePDF(pages: colors.map { (CGFloat(220), CGFloat(140), $0) }, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try PDFImport.load(url: url)
        for index in 0..<document.pageCount {
            _ = document.page(at: index)?.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
        }
        let rendered = try PDFImport.render(document: document, pageIndex: 4)
        let chosen = sample(rendered.image)
        XCTAssertLessThan(chosen.red, 80)
        XCTAssertGreaterThan(chosen.green, 180)
        XCTAssertGreaterThan(chosen.blue, 180)
        XCTAssertEqual(rendered.editBase.pageIndex, 4)

        let model = EditorModel()
        model.openSecurityScopedFile(at: url)
        XCTAssertEqual(model.pdfPageIndex, 0)
        model.openSelectedPDFPage(at: 4)
        let opened = sample(try XCTUnwrap(model.preview))
        XCTAssertLessThan(opened.red, 80)
        XCTAssertGreaterThan(opened.green, 180)
        XCTAssertGreaterThan(opened.blue, 180)
        XCTAssertEqual(model.editBase?.pageIndex, 4)
        XCTAssertEqual(model.openedFileName?.hasSuffix("page 5"), true)

        model.openSecurityScopedFile(at: url)
        model.pdfPageIndex = 4
        model.openSelectedPDFPage(at: 0)
        let first = sample(try XCTUnwrap(model.preview))
        XCTAssertGreaterThan(first.red, 180)
        XCTAssertLessThan(first.green, 80)
        XCTAssertLessThan(first.blue, 80)
        XCTAssertEqual(model.editBase?.pageIndex, 0)
    }

    private func sample(_ image: CGImage) -> (red: Int, green: Int, blue: Int) {
        guard let data = image.dataProvider?.data as Data? else { return (0, 0, 0) }
        let x = image.width / 2
        let y = image.height / 2
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        guard offset + 2 < data.count else { return (0, 0, 0) }
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zimage-\(UUID().uuidString)-\(name)")
    }

    private func writePDF(pages: [(CGFloat, CGFloat)], to url: URL) throws {
        let color = CGColor(srgbRed: 0.85, green: 0.4, blue: 0.15, alpha: 1)
        try writePDF(pages: pages.map { ($0.0, $0.1, color) }, to: url)
    }

    private func writePDF(pages: [(CGFloat, CGFloat, CGColor)], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            XCTFail("Could not open a PDF consumer")
            return
        }
        var first = CGRect(x: 0, y: 0, width: pages[0].0, height: pages[0].1)
        guard let context = CGContext(consumer: consumer, mediaBox: &first, nil) else {
            XCTFail("Could not open a PDF context")
            return
        }
        for (width, height, color) in pages {
            var box = CGRect(x: 0, y: 0, width: width, height: height)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            context.setFillColor(color)
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
