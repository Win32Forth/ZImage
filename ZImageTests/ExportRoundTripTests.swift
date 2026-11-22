import CoreGraphics
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import ZImager

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

    func testZflatMasterKeepsSixteenBitPixels() throws {
        let image = try linearImage(width: 12, height: 8, fill: (0.2, 0.4, 0.6, 1))
        let folder = try makeTempFolder("zflat-depth")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tiff = folder.appendingPathComponent("source.tiff")
        var request = ExportRequest.standard(.tiff)
        request.bitDepth = 16
        try StillExporter.write(image: image, request: request, to: tiff, context: context)
        let zflat = folder.appendingPathComponent("photo.zflat")
        try FileManager.default.copyItem(at: tiff, to: zflat)
        let loaded = try FlattenWriter.masterCGImage(zflat)
        XCTAssertGreaterThanOrEqual(loaded.image.bitsPerComponent, 16)
        XCTAssertEqual(loaded.image.width, 12)
        XCTAssertEqual(loaded.image.height, 8)
        let master = try FlattenWriter.masterImage(zflat)
        XCTAssertEqual(Int(master.extent.width.rounded()), 12)
        XCTAssertEqual(Int(master.extent.height.rounded()), 8)
    }

    func testZflatAppliesExifOrientation() throws {
        let cg = try solidCGImage(width: 32, height: 16)
        let folder = try makeTempFolder("zflat-orient")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tiff = folder.appendingPathComponent("source.tiff")
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(tiff as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, cg, [
            kCGImagePropertyOrientation: 6,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let zflat = folder.appendingPathComponent("photo.zflat")
        try FileManager.default.copyItem(at: tiff, to: zflat)
        let loaded = try FlattenWriter.masterCGImage(zflat)
        XCTAssertEqual(loaded.image.width, 32)
        XCTAssertEqual(loaded.image.height, 16)
        XCTAssertEqual(loaded.orientation, 6)
        let master = try FlattenWriter.masterImage(zflat)
        XCTAssertEqual(Int(master.extent.width.rounded()), 16)
        XCTAssertEqual(Int(master.extent.height.rounded()), 32)
    }

    func testSidecarIndexReturnsTheReadableFlattenedTIFF() throws {
        let root = try makeTempFolder("zflat-index")
        defer { try? FileManager.default.removeItem(at: root) }
        let edits = root.appendingPathComponent(".zimage/edits", isDirectory: true)
        let day = root.appendingPathComponent("Photos/day", isDirectory: true)
        try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try writeCatalog(uid: "shortuid", relative: "Photos/scan.jpg", edits: edits)
        try writeCatalog(uid: "longuid", relative: "Photos/day/scan.jpg", edits: edits)
        let longTIFF = edits.appendingPathComponent("longuid.zflat")
        try Data([0x49, 0x49, 0x2A, 0x00]).write(to: edits.appendingPathComponent("shortuid.zflat"))
        try Data([0x49, 0x49, 0x2A, 0x00]).write(to: longTIFF)
        let index = FlattenSidecarIndex()
        let dayFile = day.appendingPathComponent("scan.jpg")
        try Data([0xFF, 0xD8]).write(to: dayFile)
        XCTAssertEqual(index.tiff(for: dayFile)?.lastPathComponent, "longuid.zflat")
        let shortFile = root.appendingPathComponent("Photos/scan.jpg")
        try Data([0xFF, 0xD8]).write(to: shortFile)
        XCTAssertEqual(index.tiff(for: shortFile)?.lastPathComponent, "shortuid.zflat")
        try FileManager.default.removeItem(at: longTIFF)
        XCTAssertNil(index.tiff(for: dayFile))
    }

    func testFlattenDuplicateBumpsTheFileName() {
        XCTAssertEqual(FlattenDuplicate.fileName(sourceName: "Day.jpg") { _ in false }, "Day-2.tiff")
        XCTAssertEqual(FlattenDuplicate.fileName(sourceName: "Day.tiff") { _ in false }, "Day-2.tiff")
        XCTAssertEqual(
            FlattenDuplicate.fileName(sourceName: "Day.jpg") { $0 == "Day-2.tiff" || $0 == "Day-3.tiff" },
            "Day-4.tiff"
        )
        XCTAssertEqual(FlattenDuplicate.fileName(sourceName: "") { _ in false }, "Photo-2.tiff")
        XCTAssertEqual(FlattenDuplicate.fileName(sourceName: ".") { _ in false }, "Photo-2.tiff")
        let blocked = FlattenDuplicate.fileName(sourceName: "Day.jpg") { _ in true }
        XCTAssertNil(blocked)
    }

    func testRevertRemovesTheFlattenedTIFFAndClearsTheEditList() throws {
        let edits = try makeTempFolder("zflat-revert")
        defer { try? FileManager.default.removeItem(at: edits) }
        let uid = "revertuid"
        try writeCatalog(uid: uid, relative: "Photos/old.jpg", edits: edits)
        let zflat = edits.appendingPathComponent(uid + ".zflat")
        let zjpg = edits.appendingPathComponent(uid + ".zjpg")
        let original = edits.appendingPathComponent("original.jpg")
        try Data([0x49, 0x49, 0x2A, 0x00]).write(to: zflat)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: zjpg)
        try Data([0xFF, 0xD8]).write(to: original)
        let preview = Data([0xFF, 0xD8, 0xFF, 0xDB])
        try FlattenedMaster.revertToOriginal(
            uid: uid,
            editsFolder: edits,
            previewJPEG: preview,
            blake3: "new-digest",
            byteSize: 42,
            uti: "public.jpeg",
            relativePath: "Photos/scan.jpg"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: zflat.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: zjpg.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let document = try ZImgRaw.read(from: edits.appendingPathComponent(uid + ".zimg"))
        XCTAssertEqual(document.history, HistoryLog())
        XCTAssertEqual(document.history.commands.count, 0)
        XCTAssertEqual(document.history.cursor, 0)
        XCTAssertEqual(document.base.assetUID, uid)
        XCTAssertEqual(document.base.blake3, "new-digest")
        XCTAssertEqual(document.base.byteSize, 42)
        XCTAssertEqual(document.base.relativePathHint, "Photos/scan.jpg")
        XCTAssertEqual(document.previewJPEG, preview)
        XCTAssertThrowsError(try FlattenedMaster.revertToOriginal(
            uid: "",
            editsFolder: edits,
            previewJPEG: preview,
            blake3: "new-digest",
            byteSize: 42,
            uti: "public.jpeg",
            relativePath: "Photos/scan.jpg"
        ))
    }

    private func makeTempFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func solidCGImage(width: Int, height: Int) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func writeCatalog(uid: String, relative: String, edits: URL) throws {
        let document = ZImgRaw.catalogRefDocument(
            log: HistoryLog(),
            blake3: "abc",
            byteSize: 4,
            uti: "public.jpeg",
            assetUID: uid,
            relativePathHint: relative,
            previewJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
        let bytes = try ZImgRaw.encode(document)
        try bytes.write(to: edits.appendingPathComponent(uid + ".zimg"))
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
