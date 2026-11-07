import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Which decoder produced a proxy. The full-frame `CGImageSourceCreateImageAtIndex`
/// path is not an entry point. Stills use an ImageIO thumbnail. Camera RAW uses
/// `CIRAWFilter.scaleFactor`.
nonisolated enum ProxyEntryPoint: String, Equatable, Sendable {
    case imageIOThumbnail
    case cirawScaleFactor
}

nonisolated struct ProxyImage: @unchecked Sendable {
    var image: CGImage
    var entryPoint: ProxyEntryPoint
    /// Set only for the RAW path. It is `min(1, maxLongEdge / nativeLongEdge)`.
    var appliedScaleFactor: Float?
    var nativeLongEdge: Int?

    var width: Int { image.width }
    var height: Int { image.height }
    var longEdge: Int { max(width, height) }
}

nonisolated enum ProxyOpenError: Error, Equatable, Sendable, LocalizedError {
    case cannotRead(String)
    case unsupported(fileName: String, uti: String)
    case thumbnailFailed(fileName: String, uti: String)
    case rawFailed(fileName: String, uti: String)

    var errorDescription: String? {
        switch self {
        case .cannotRead(let name):
            return "Could not read \(name)."
        case .unsupported(let name, let uti):
            return "\(name) is not an openable still image (\(uti))."
        case .thumbnailFailed(let name, let uti):
            return "Could not build a preview of \(name) (\(uti))."
        case .rawFailed(let name, let uti):
            return "Could not decode RAW file \(name) (\(uti))."
        }
    }
}

/// Builds the interactive proxy. The long edge is at most 2560. Pixel data for a
/// still comes from `CGImageSourceCreateThumbnailAtIndex`. Pixel data for RAW
/// comes from `CIRAWFilter` after `scaleFactor` is set. This type does not call
/// `CGImageSourceCreateImageAtIndex`.
nonisolated enum ProxyRenderer {
    static let maxLongEdge = 2560

    /// Extensions that take the RAW scale path. Sigma X3F is not here.
    static let rawExtensions: Set<String> = [
        "raf", "arw", "dng", "cr2", "cr3", "nef", "nrw", "orf", "rw2",
        "pef", "srw", "erf", "raw", "rwl", "3fr", "fff", "iiq", "mos", "sr2",
    ]

    static var openableContentTypes: [UTType] {
        var types: [UTType] = [.jpeg, .png, .heic, .tiff]
        if let heif = UTType("public.heif"), !types.contains(heif) {
            types.append(heif)
        }
        if let raw = UTType("public.camera-raw-image"), !types.contains(raw) {
            types.append(raw)
        }
        for ext in rawExtensions.sorted() {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    static func open(url: URL) throws -> ProxyImage {
        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        if ext == "x3f" || ext == "pdf" {
            throw ProxyOpenError.unsupported(fileName: fileName, uti: ext == "pdf" ? "com.adobe.pdf" : "unknown")
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw ProxyOpenError.cannotRead(fileName)
        }
        let uti = (CGImageSourceGetType(source) as String?) ?? "public.data"
        if let type = UTType(uti), type.conforms(to: .pdf) {
            throw ProxyOpenError.unsupported(fileName: fileName, uti: uti)
        }
        if isCameraRAW(fileExtension: ext, uti: uti) {
            return try openWithCIRAWScaleFactor(url: url, fileName: fileName, uti: uti)
        }
        return try openWithImageIOThumbnail(source: source, fileName: fileName, uti: uti)
    }

    static func isCameraRAW(fileExtension: String, uti: String) -> Bool {
        if rawExtensions.contains(fileExtension) {
            return true
        }
        guard let raw = UTType("public.camera-raw-image"), let type = UTType(uti) else {
            return false
        }
        return type.conforms(to: raw)
    }

    /// ImageIO thumbnail. `kCGImageSourceThumbnailMaxPixelSize` is 2560.
    /// `kCGImageSourceCreateThumbnailFromImageAlways` is true.
    /// `kCGImageSourceShouldCache` is false. Orientation is applied.
    private static func openWithImageIOThumbnail(
        source: CGImageSource,
        fileName: String,
        uti: String
    ) throws -> ProxyImage {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ProxyOpenError.thumbnailFailed(fileName: fileName, uti: uti)
        }
        guard max(image.width, image.height) <= maxLongEdge else {
            throw ProxyOpenError.thumbnailFailed(fileName: fileName, uti: uti)
        }
        return ProxyImage(image: image, entryPoint: .imageIOThumbnail, appliedScaleFactor: nil, nativeLongEdge: nil)
    }

    /// Decodes RAW so the long edge is about 2560. The scale is applied before
    /// the output image is read, so the full native frame is not rendered.
    private static func openWithCIRAWScaleFactor(url: URL, fileName: String, uti: String) throws -> ProxyImage {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw ProxyOpenError.rawFailed(fileName: fileName, uti: uti)
        }
        let native = filter.nativeSize
        guard native.width >= 1, native.height >= 1 else {
            throw ProxyOpenError.rawFailed(fileName: fileName, uti: uti)
        }
        let nativeLong = max(native.width, native.height)
        var scale = min(Float(1), Float(maxLongEdge) / Float(nativeLong))
        filter.scaleFactor = scale
        guard let output = filter.outputImage else {
            throw ProxyOpenError.rawFailed(fileName: fileName, uti: uti)
        }
        var rendered = try render(output, fileName: fileName, uti: uti)
        if max(rendered.width, rendered.height) > maxLongEdge {
            let over = CGFloat(max(rendered.width, rendered.height))
            scale *= Float(maxLongEdge) / Float(over)
            filter.scaleFactor = scale
            guard let retry = filter.outputImage else {
                throw ProxyOpenError.rawFailed(fileName: fileName, uti: uti)
            }
            rendered = try render(retry, fileName: fileName, uti: uti)
        }
        guard max(rendered.width, rendered.height) <= maxLongEdge else {
            throw ProxyOpenError.rawFailed(fileName: fileName, uti: uti)
        }
        return ProxyImage(
            image: rendered,
            entryPoint: .cirawScaleFactor,
            appliedScaleFactor: scale,
            nativeLongEdge: Int(nativeLong.rounded())
        )
    }

    private static func render(_ image: CIImage, fileName: String, uti: String) throws -> CGImage {
        let extent = image.extent.integral
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else {
            throw ProxyOpenError.rawFailed(fileName: fileName, uti: uti)
        }
        let context = CIContext(options: [CIContextOption.cacheIntermediates: false])
        guard let rendered = context.createCGImage(image, from: extent) else {
            throw ProxyOpenError.rawFailed(fileName: fileName, uti: uti)
        }
        return rendered
    }
}
