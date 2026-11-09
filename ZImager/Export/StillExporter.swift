import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Export containers this build can write.
nonisolated enum ExportContainer: String, CaseIterable, Identifiable, Sendable {
    case jpeg
    case heic
    case tiff
    case png
    case webp
    case avif
    case jpegxl
    case jpeg2000
    case psd
    case openexr
    case bmp
    case gif
    case tga
    case pdf
    case dng

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .png: return "PNG"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        case .jpegxl: return "JPEG XL"
        case .jpeg2000: return "JPEG 2000"
        case .psd: return "PSD"
        case .openexr: return "OpenEXR"
        case .bmp: return "BMP"
        case .gif: return "GIF"
        case .tga: return "TGA"
        case .pdf: return "PDF"
        case .dng: return "DNG"
        }
    }

    var defaultExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .png: return "png"
        case .webp: return "webp"
        case .avif: return "avif"
        case .jpegxl: return "jxl"
        case .jpeg2000: return "jp2"
        case .psd: return "psd"
        case .openexr: return "exr"
        case .bmp: return "bmp"
        case .gif: return "gif"
        case .tga: return "tga"
        case .pdf: return "pdf"
        case .dng: return "dng"
        }
    }

    var defaultQuality: Double {
        switch self {
        case .jpeg: return 0.90
        case .heic: return 0.80
        case .webp: return 80
        case .avif: return 0.70
        case .jpeg2000: return 0.80
        default: return 1
        }
    }

    var defaultBitDepth: Int {
        switch self {
        case .tiff, .png: return 16
        default: return 8
        }
    }

    var allowsBitDepthChoice: Bool {
        self == .tiff || self == .png || self == .psd
    }

    var usesQualitySlider: Bool {
        self == .jpeg || self == .heic || self == .avif || self == .jpeg2000 || self == .webp
    }

    var offersLosslessToggle: Bool {
        self == .webp || self == .jpegxl
    }

    /// JPEG is 0.50...0.95. JPEG 2000 reaches 1.0 so the lossless check has a value to record.
    var qualityRange: ClosedRange<Double> {
        switch self {
        case .jpeg, .heic, .avif: return 0.50...0.95
        case .jpeg2000: return 0.50...1.0
        case .webp: return 0...100
        default: return 0.50...0.95
        }
    }

    /// ImageIO destination UTI. PDF is not in this list.
    var imageIOType: String? {
        switch self {
        case .jpeg: return UTType.jpeg.identifier
        case .heic: return UTType.heic.identifier
        case .tiff: return UTType.tiff.identifier
        case .png: return UTType.png.identifier
        case .webp, .jpegxl, .dng: return nil
        case .avif: return "public.avif"
        case .jpeg2000: return "public.jpeg-2000"
        case .psd: return "com.adobe.photoshop-image"
        case .openexr: return "com.ilm.openexr-image"
        case .bmp: return "com.microsoft.bmp"
        case .gif: return "com.compuserve.gif"
        case .tga: return "com.truevision.tga-image"
        case .pdf: return nil
        }
    }

    static let imageIODestinationUTIs: [String] = [
        "public.jpeg",
        "public.png",
        "com.compuserve.gif",
        "public.tiff",
        "public.jpeg-2000",
        "public.heic",
        "public.avif",
        "com.microsoft.bmp",
        "com.adobe.photoshop-image",
        "com.truevision.tga-image",
        "com.ilm.openexr-image",
    ]
}

nonisolated enum TIFFCompression: String, CaseIterable, Identifiable, Sendable {
    case lzw
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lzw: return "LZW"
        case .none: return "Uncompressed"
        }
    }

    var tiffValue: Int { self == .lzw ? 5 : 1 }
}

nonisolated struct ExportRequest: Sendable {
    var container: ExportContainer
    var quality: Double
    var bitDepth: Int
    var tiffCompression: TIFFCompression
    var fileExtension: String
    var lossless: Bool = false

    static func standard(_ container: ExportContainer, fileExtension: String? = nil) -> ExportRequest {
        ExportRequest(
            container: container,
            quality: container.defaultQuality,
            bitDepth: container.defaultBitDepth,
            tiffCompression: .lzw,
            fileExtension: fileExtension ?? container.defaultExtension,
            lossless: false
        )
    }

    /// Panel sentence. Names the bit depth and whether the file is lossy or lossless.
    var panelCopy: String {
        switch container {
        case .jpeg:
            return "8-bit sRGB. Lossy. Quality slider 0.50 to 0.95, default 0.90."
        case .heic:
            return "8-bit. Lossy. Quality default 0.80."
        case .tiff:
            let depth = bitDepth >= 16 ? "16-bit Display P3" : "8-bit sRGB"
            let compression = tiffCompression == .lzw ? "Lossless LZW." : "Uncompressed."
            return "\(depth). \(compression)"
        case .png:
            return bitDepth >= 16 ? "16-bit Display P3. Lossless." : "8-bit sRGB. Lossless."
        case .webp:
            return "8-bit sRGB. Lossy, quality 80. Lossless is available."
        case .jpegxl:
            return "8-bit sRGB. Lossy distance 1.0, or lossless. Effort 7."
        case .avif:
            return "8-bit. Lossy. Quality default 0.70."
        case .jpeg2000:
            return "8-bit sRGB. Lossy. Quality 1.0 is lossless at 8-bit."
        case .psd:
            let depth = bitDepth >= 16 ? "16-bit Display P3" : "8-bit sRGB"
            return "\(depth). Flat file, no layers. A long edge over 30,000 is refused. Use TIFF or OpenEXR."
        case .openexr:
            return "Half-float linear Display P3."
        case .bmp:
            return "8-bit sRGB. Uncompressed."
        case .gif:
            return "256-color palette, dithered. Not a master."
        case .tga:
            return "8-bit sRGB."
        case .pdf:
            return "8-bit sRGB. One page, 1 point per pixel."
        case .dng:
            return "16-bit uncompressed linear Display P3. A 100 megapixel file is about 600 MB."
        }
    }
}

nonisolated enum ExportError: Error, Equatable, LocalizedError {
    case cannotEncode(String)
    case edgeTooLong

    var errorDescription: String? {
        switch self {
        case .cannotEncode(let format):
            return "Could not write \(format)."
        case .edgeTooLong:
            return "This image is larger than 30,000 pixels on the long edge. Export TIFF or OpenEXR instead."
        }
    }
}

/// ImageIO and PDFKit export. Tiles stay in extended linear Display P3 until the gather.
/// An inpaint command with no LaMa model throws before any file is created. The interactive stub is not used.
nonisolated enum StillExporter {
    static let tileEdge = 2048
    static let psdMaxLongEdge: CGFloat = 30_000

    static func write(
        image: CIImage,
        state: EditState = .identity,
        request: ExportRequest,
        to url: URL,
        context: CIContext
    ) throws {
        try InpaintPipeline.validateForExport(state)
        let extent = image.extent.integral
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else {
            throw ExportError.cannotEncode(request.container.title)
        }
        if request.container == .psd {
            let longEdge = max(extent.width, extent.height)
            if longEdge > psdMaxLongEdge {
                throw ExportError.edgeTooLong
            }
        }
        do {
            if request.container == .dng {
                try LinearDNGWriter.write(image: image, to: url, context: context)
            } else {
                let rendered = try rasterize(image, request: request, context: context)
                if request.container == .pdf {
                    try writePDF(rendered, to: url)
                } else if request.container == .webp {
                    try writeWebP(rendered, request: request, to: url)
                } else if request.container == .jpegxl {
                    try writeJPEGXL(rendered, request: request, to: url)
                } else {
                    try writeImageIO(rendered, request: request, to: url)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func writeWebP(_ image: CGImage, request: ExportRequest, to url: URL) throws {
        let (rgba, width, height) = try rgba8(from: image)
        let encoded: Data
        if request.lossless {
            encoded = try WebPWriter.encodeLosslessRGBA(rgba, width: width, height: height)
        } else {
            encoded = try WebPWriter.encodeRGBA(rgba, width: width, height: height, quality: Float(request.quality))
        }
        try encoded.write(to: url, options: .atomic)
    }

    private static func writeJPEGXL(_ image: CGImage, request: ExportRequest, to url: URL) throws {
        let (rgba, width, height) = try rgba8(from: image)
        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { destination in
            rgba.withUnsafeBytes { source in
                let src = source.bindMemory(to: UInt8.self)
                let dst = destination.bindMemory(to: UInt8.self)
                for pixel in 0..<(width * height) {
                    dst[pixel * 3] = src[pixel * 4]
                    dst[pixel * 3 + 1] = src[pixel * 4 + 1]
                    dst[pixel * 3 + 2] = src[pixel * 4 + 2]
                }
            }
        }
        let encoded = try JPEGXLWriter.encodeRGB(rgb, width: width, height: height, lossless: request.lossless)
        try encoded.write(to: url, options: .atomic)
    }

    private static func rgba8(from image: CGImage) throws -> (Data, Int, Int) {
        let width = image.width
        let height = image.height
        let rowBytes = width * 4
        var data = Data(count: height * rowBytes)
        let drew = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw ExportError.cannotEncode("WebP")
        }
        return (data, width, height)
    }

    private static func rasterize(_ image: CIImage, request: ExportRequest, context: CIContext) throws -> CGImage {
        let spec = colorSpec(for: request)
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        if width <= tileEdge && height <= tileEdge {
            guard let rendered = context.createCGImage(
                image,
                from: extent,
                format: spec.format,
                colorSpace: spec.colorSpace
            ) else {
                throw ExportError.cannotEncode(request.container.title)
            }
            return rendered
        }
        guard let canvas = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: spec.bits,
            bytesPerRow: 0,
            space: spec.colorSpace,
            bitmapInfo: spec.bitmapInfo
        ) else {
            throw ExportError.cannotEncode(request.container.title)
        }
        canvas.interpolationQuality = .none
        var y = extent.minY
        while y < extent.maxY {
            let tileHeight = min(CGFloat(tileEdge), extent.maxY - y)
            var x = extent.minX
            while x < extent.maxX {
                let tileWidth = min(CGFloat(tileEdge), extent.maxX - x)
                let rect = CGRect(x: x, y: y, width: tileWidth, height: tileHeight)
                guard let tile = context.createCGImage(
                    image,
                    from: rect,
                    format: spec.format,
                    colorSpace: spec.colorSpace
                ) else {
                    throw ExportError.cannotEncode(request.container.title)
                }
                canvas.draw(tile, in: CGRect(
                    x: x - extent.minX,
                    y: y - extent.minY,
                    width: tileWidth,
                    height: tileHeight
                ))
                x += tileWidth
            }
            y += tileHeight
        }
        guard let gathered = canvas.makeImage() else {
            throw ExportError.cannotEncode(request.container.title)
        }
        return gathered
    }

    private static func colorSpec(for request: ExportRequest) -> (format: CIFormat, colorSpace: CGColorSpace, bits: Int, bitmapInfo: UInt32) {
        let eight = CGImageAlphaInfo.premultipliedLast.rawValue
        let sixteen = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        if request.container == .openexr {
            let info = CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
            return (.RGBAh, TonePipeline.workingColorSpace, 16, info)
        }
        let deep = (request.container == .png || request.container == .tiff || request.container == .psd)
            && request.bitDepth >= 16
        if deep {
            return (.RGBA16, CGColorSpace(name: CGColorSpace.displayP3)!, 16, sixteen)
        }
        return (.RGBA8, CGColorSpace(name: CGColorSpace.sRGB)!, 8, eight)
    }

    private static func writeImageIO(_ image: CGImage, request: ExportRequest, to url: URL) throws {
        guard let type = request.container.imageIOType,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw ExportError.cannotEncode(request.container.title)
        }
        CGImageDestinationAddImage(destination, image, properties(for: request))
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.cannotEncode(request.container.title)
        }
    }

    /// One page. The media box is one point per pixel. This is not ImageIO's `com.adobe.pdf` writer.
    private static func writePDF(_ image: CGImage, to url: URL) throws {
        let size = NSSize(width: image.width, height: image.height)
        let nsImage = NSImage(cgImage: image, size: size)
        guard let page = PDFPage(image: nsImage) else {
            throw ExportError.cannotEncode("PDF")
        }
        let box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        page.setBounds(box, for: .mediaBox)
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: url) else {
            throw ExportError.cannotEncode("PDF")
        }
    }

    private static func properties(for request: ExportRequest) -> CFDictionary {
        var properties: [CFString: Any] = [:]
        switch request.container {
        case .jpeg, .heic, .avif, .jpeg2000:
            let range = request.container.qualityRange
            let quality = min(range.upperBound, max(range.lowerBound, request.quality))
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        case .tiff:
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFCompression: request.tiffCompression.tiffValue,
            ]
            properties[kCGImagePropertyDepth] = request.bitDepth
        case .png, .psd:
            properties[kCGImagePropertyDepth] = request.bitDepth
        case .gif:
            properties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: 0]
        default:
            break
        }
        return properties as CFDictionary
    }
}
