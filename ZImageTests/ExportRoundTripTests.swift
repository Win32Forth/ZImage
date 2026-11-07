import CoreGraphics
import CoreImage
import ImageIO
import PDFKit
import XCTest
@testable import ZImage

final class ExportRoundTripTests: XCTestCase {
    private let context = TonePipeline.makeContext()

    func testImageIODestinationsStillExist() {
        let present = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        for uti in ExportContainer.imageIODestinationUTIs {
            XCTAssertTrue(present.contains(uti), uti)
        }
        XCTAssertNil(ExportContainer.allCases.first { $0.imageIOType == "org.webmproject.webp" })
        XCTAssertNil(ExportContainer.allCases.first { $0.imageIOType == "public.jpeg-xl" })
    }

    func testEachExporterRoundTripsAGradient() throws {
        let image = try linearImage(width: 32, height: 32, fill: nil)
        for container in ExportContainer.allCases {
            let request = ExportRequest.standard(container)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("zimage-gradient-\(container.rawValue).\(request.fileExtension)")
            try? FileManager.default.removeItem(at: url)
            try StillExporter.write(image: image, request: request, to: url, context: context)
            if container == .pdf {
                let document = PDFDocument(url: url)
                XCTAssertEqual(document?.pageCount, 1, container.rawValue)
            } else if container == .webp {
                let decoded = try WebPWriter.decodeRGBA(Data(contentsOf: url))
                XCTAssertEqual(decoded.width, 32, container.rawValue)
                XCTAssertEqual(decoded.height, 32, container.rawValue)
            } else if container == .jpegxl {
                let decoded = try JPEGXLWriter.decodeRGB(Data(contentsOf: url))
                XCTAssertEqual(decoded.width, 32, container.rawValue)
                XCTAssertEqual(decoded.height, 32, container.rawValue)
            } else {
                let size = try pixelSize(url)
                XCTAssertEqual(size.width, 32, container.rawValue)
                XCTAssertEqual(size.height, 32, container.rawValue)
            }
        }
    }

    func testTiffAndTifBothOpenAsPublicTiff() throws {
        let image = try linearImage(width: 32, height: 32, fill: nil)
        for ext in ["tif", "tiff"] {
            let request = ExportRequest.standard(.tiff, fileExtension: ext)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-tiff.\(ext)")
            try? FileManager.default.removeItem(at: url)
            try StillExporter.write(image: image, request: request, to: url, context: context)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.tiff", ext)
            let size = try pixelSize(url)
            XCTAssertEqual(size.width, 32)
            XCTAssertEqual(size.height, 32)
        }
    }

    func testLinearDisplayP3RedRoundTripsThroughJPEGAsSRGB() throws {
        let image = try linearImage(width: 16, height: 16, fill: (0.5, 0, 0, 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-red.jpg")
        try? FileManager.default.removeItem(at: url)
        try StillExporter.write(
            image: image,
            request: .standard(.jpeg),
            to: url,
            context: context
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let red = try srgbRed(cg, x: 8, y: 8)
        XCTAssertGreaterThan(red, 0.65)
        XCTAssertLessThan(red, 0.85)
    }

    func testTiledJPEGKeepsTheWideDimension() throws {
        let image = try linearImage(width: 2050, height: 2, fill: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-tiled.jpg")
        try? FileManager.default.removeItem(at: url)
        try StillExporter.write(image: image, request: .standard(.jpeg), to: url, context: context)
        let size = try pixelSize(url)
        XCTAssertEqual(size.width, 2050)
        XCTAssertEqual(size.height, 2)
    }

    func testPSDRefusesALongEdgeOver30000() throws {
        let image = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 30_001, height: 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-too-wide.psd")
        try? FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try StillExporter.write(image: image, request: .standard(.psd), to: url, context: context)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("TIFF"))
            XCTAssertTrue(message.contains("OpenEXR"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testExportRefusesInpaintWhenTheModelIsMissing() throws {
        XCTAssertNil(InpaintPipeline.modelURL())
        var state = EditState.identity
        state.inpaints = [InpaintOp.empty()]
        let image = try linearImage(width: 8, height: 8, fill: (0.2, 0.2, 0.2, 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-inpaint-export.jpg")
        try? FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try StillExporter.write(image: image, state: state, request: .standard(.jpeg), to: url, context: context)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Records the macOS 27.3 encoder facts from the export section.
    /// JPEG 2000 quality 1.0 matches an 8-bit PNG byte for byte on a flat patch, so it is lossless at 8-bit.
    /// OpenEXR comes back with the bit depth ImageIO actually wrote. TGA is 8-bit.
    func testRecordedEncoderFacts() throws {
        let image = try linearImage(width: 16, height: 16, fill: (0.2, 0.4, 0.6, 1))
        var pngRequest = ExportRequest.standard(.png)
        pngRequest.bitDepth = 8
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-fact.png")
        var jp2Request = ExportRequest.standard(.jpeg2000)
        jp2Request.quality = 1
        let jp2URL = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-fact.jp2")
        try? FileManager.default.removeItem(at: pngURL)
        try? FileManager.default.removeItem(at: jp2URL)
        try StillExporter.write(image: image, request: pngRequest, to: pngURL, context: context)
        try StillExporter.write(image: image, request: jp2Request, to: jp2URL, context: context)
        let png = try decoded(pngURL)
        let jp2 = try decoded(jp2URL)
        XCTAssertEqual(srgbByte(png, x: 8, y: 8), srgbByte(jp2, x: 8, y: 8))

        let exrURL = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-fact.exr")
        let tgaURL = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-fact.tga")
        try? FileManager.default.removeItem(at: exrURL)
        try? FileManager.default.removeItem(at: tgaURL)
        try StillExporter.write(image: image, request: .standard(.openexr), to: exrURL, context: context)
        try StillExporter.write(image: image, request: .standard(.tga), to: tgaURL, context: context)
        let exr = try decoded(exrURL)
        let tga = try decoded(tgaURL)
        XCTAssertEqual(exr.bitsPerComponent, 16, "OpenEXR bitsPerComponent \(exr.bitsPerComponent) bitsPerPixel \(exr.bitsPerPixel)")
        XCTAssertTrue(exr.bitmapInfo.contains(.floatComponents), "OpenEXR bitmapInfo \(exr.bitmapInfo)")
        XCTAssertEqual(tga.bitsPerComponent, 8, "TGA bitsPerComponent \(tga.bitsPerComponent) bitsPerPixel \(tga.bitsPerPixel)")

        for container in [ExportContainer.tiff, ExportContainer.png] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-depth.\(container.defaultExtension)")
            try? FileManager.default.removeItem(at: url)
            try StillExporter.write(image: image, request: .standard(container), to: url, context: context)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let depth = (props?[kCGImagePropertyDepth] as? NSNumber)?.intValue
            XCTAssertEqual(depth, 16, container.rawValue)
        }
    }

    func testPanelCopyNamesDepthAndLoss() {
        XCTAssertTrue(ExportRequest.standard(.jpeg).panelCopy.contains("8-bit"))
        XCTAssertTrue(ExportRequest.standard(.jpeg).panelCopy.contains("Lossy"))
        XCTAssertTrue(ExportRequest.standard(.heic).panelCopy.contains("8-bit"))
        XCTAssertTrue(ExportRequest.standard(.png).panelCopy.contains("16-bit"))
        XCTAssertTrue(ExportRequest.standard(.png).panelCopy.contains("Lossless"))
        XCTAssertTrue(ExportRequest.standard(.tiff).panelCopy.contains("16-bit"))
        XCTAssertTrue(ExportRequest.standard(.tiff).panelCopy.contains("LZW"))
        XCTAssertTrue(ExportRequest.standard(.gif).panelCopy.contains("Not a master"))
        XCTAssertTrue(ExportRequest.standard(.pdf).panelCopy.contains("One page"))
        XCTAssertTrue(ExportRequest.standard(.webp).panelCopy.contains("quality 80"))
        XCTAssertTrue(ExportRequest.standard(.webp).panelCopy.contains("Lossless"))
        XCTAssertTrue(ExportRequest.standard(.jpegxl).panelCopy.contains("distance 1.0"))
        XCTAssertTrue(ExportRequest.standard(.jpegxl).panelCopy.contains("Effort 7"))
        XCTAssertTrue(ExportRequest.standard(.dng).panelCopy.contains("600 MB"))
        XCTAssertTrue(ExportRequest.standard(.dng).panelCopy.contains("16-bit"))
        XCTAssertNil(ExportContainer.webp.imageIOType)
        XCTAssertNil(ExportContainer.jpegxl.imageIOType)
    }

    private func linearImage(width: Int, height: Int, fill: (Float, Float, Float, Float)?) throws -> CIImage {
        let bytesPerRow = width * 8
        var data = Data(count: height * bytesPerRow)
        data.withUnsafeMutableBytes { raw in
            let pixels = raw.bindMemory(to: Float16.self)
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    if let fill {
                        pixels[index] = Float16(fill.0)
                        pixels[index + 1] = Float16(fill.1)
                        pixels[index + 2] = Float16(fill.2)
                        pixels[index + 3] = Float16(fill.3)
                    } else {
                        let t = Float(x + y) / Float(max(width + height - 2, 1))
                        pixels[index] = Float16(t)
                        pixels[index + 1] = Float16(t * 0.2)
                        pixels[index + 2] = Float16(1 - t)
                        pixels[index + 3] = 1
                    }
                }
            }
        }
        return CIImage(
            bitmapData: data,
            bytesPerRow: bytesPerRow,
            size: CGSize(width: width, height: height),
            format: .RGBAh,
            colorSpace: TonePipeline.workingColorSpace
        )
    }

    private func decoded(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func srgbByte(_ image: CGImage, x: Int, y: Int) -> Int {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let base = ctx.data else {
            return -1
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixel = base.advanced(by: y * ctx.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return Int(pixel[0])
    }

    private func pixelSize(_ url: URL) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        return (try XCTUnwrap(width), try XCTUnwrap(height))
    }

    private func srgbRed(_ image: CGImage, x: Int, y: Int) throws -> Double {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let base = ctx.data else {
            XCTFail("No sRGB context")
            return 0
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytesPerRow = ctx.bytesPerRow
        let pixel = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return Double(pixel[0]) / 255
    }
}
