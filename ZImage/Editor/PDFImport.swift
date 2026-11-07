import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// The rendered PDF page is the edit base. Its long edge is at most 8192.
nonisolated struct EditBase: Equatable, Sendable {
    var pixelWidth: Int
    var pixelHeight: Int
    var pageIndex: Int

    var longEdge: Int { max(pixelWidth, pixelHeight) }
}

nonisolated struct PDFRenderedPage {
    var image: CGImage
    var editBase: EditBase
}

enum PDFImport {
    static let maxEditBaseLongEdge = 8192
    /// Page 1. The picker does not render a page until the user confirms.
    static let defaultPageIndex = 0

    static func load(url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw PDFImportError.cannotRead(url.lastPathComponent)
        }
        return document
    }

    /// Draws one page into a bitmap. A multi-page file stays multi-page.
    static func render(document: PDFDocument, pageIndex: Int, maxLongEdge: Int = maxEditBaseLongEdge) throws -> PDFRenderedPage {
        guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else {
            throw PDFImportError.cannotRead("page \(pageIndex + 1)")
        }
        let media = page.bounds(for: .mediaBox)
        guard media.width >= 1, media.height >= 1 else {
            throw PDFImportError.cannotRead("page \(pageIndex + 1)")
        }
        let long = max(media.width, media.height)
        let scale = min(1, CGFloat(maxLongEdge) / long)
        let pixelWidth = max(1, Int((media.width * scale).rounded(.down)))
        let pixelHeight = max(1, Int((media.height * scale).rounded(.down)))
        guard max(pixelWidth, pixelHeight) <= maxLongEdge else {
            throw PDFImportError.cannotRead("page \(pageIndex + 1)")
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw PDFImportError.cannotRead("page \(pageIndex + 1)")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else {
            throw PDFImportError.cannotRead("page \(pageIndex + 1)")
        }
        return PDFRenderedPage(
            image: image,
            editBase: EditBase(pixelWidth: image.width, pixelHeight: image.height, pageIndex: pageIndex)
        )
    }

    /// Interactive proxy. This does not call `CGImageSourceCreateImageAtIndex`.
    static func proxy(from image: CGImage, maxLongEdge: Int) throws -> ProxyImage {
        let fitted = try scale(image, longEdge: maxLongEdge)
        guard max(fitted.width, fitted.height) <= maxLongEdge else {
            throw PDFImportError.cannotRead("preview")
        }
        return ProxyImage(image: fitted, entryPoint: .imageIOThumbnail, appliedScaleFactor: nil, nativeLongEdge: nil)
    }

    static func scale(_ image: CGImage, longEdge: Int) throws -> CGImage {
        let width = image.width
        let height = image.height
        let edge = max(width, height)
        guard edge > longEdge, edge > 0 else { return image }
        let factor = Double(longEdge) / Double(edge)
        let fittedWidth = max(1, Int((Double(width) * factor).rounded(.down)))
        let fittedHeight = max(1, Int((Double(height) * factor).rounded(.down)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: fittedWidth,
                height: fittedHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw PDFImportError.cannotRead("preview")
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: fittedWidth, height: fittedHeight))
        guard let scaled = context.makeImage() else { throw PDFImportError.cannotRead("preview") }
        return scaled
    }
}

enum PDFImportError: Error, Equatable, LocalizedError {
    case cannotRead(String)

    var errorDescription: String? {
        switch self {
        case .cannotRead(let name):
            return "Could not read \(name)."
        }
    }
}
