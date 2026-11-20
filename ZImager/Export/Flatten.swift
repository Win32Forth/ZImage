import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Full-size flatten. ZImager renders the finished pixels and writes them.
/// The helper never sees this frame.
nonisolated enum FlattenError: Error, LocalizedError {
    case cannotRead(String)
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .cannotRead(let name):
            return "Could not read \(name)."
        case .cannotWrite(let name):
            return "Could not write \(name)."
        }
    }
}

/// The flattened TIFF and its working JPEG live in `.zimage/edits` on the library.
nonisolated enum FlattenedMaster {
    struct Identity: Sendable, Equatable {
        var uid: String
        var relativePath: String
        var editsFolder: URL
    }

    /// The grid passes `hint` when it already knows the catalog row. Otherwise the edits folder is searched.
    static func find(file: URL, hint: CatalogEditTarget?) -> Identity? {
        let file = file.standardizedFileURL.resolvingSymlinksInPath()
        if let hint, let folder = editsFolder(file: file, relativePath: hint.relativePath) {
            return Identity(uid: hint.uid, relativePath: hint.relativePath, editsFolder: folder)
        }
        return findByScanningEdits(of: file)
    }

    static func editsFolder(file: URL, relativePath: String) -> URL? {
        let relative = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        guard !relative.isEmpty else { return nil }
        let sourcePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        let suffix = "/" + relative
        guard sourcePath.hasSuffix(suffix) else { return nil }
        let root = String(sourcePath.dropLast(suffix.count))
        let edits = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".zimage/edits", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: edits.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return edits
    }

    /// Working JPEG for later edits. Both flatten files have to be present.
    static func workingJPEG(for identity: Identity) -> Data? {
        let tiff = identity.editsFolder.appendingPathComponent(identity.uid + ".zflat")
        let jpeg = identity.editsFolder.appendingPathComponent(identity.uid + ".zjpg")
        guard FileManager.default.isReadableFile(atPath: tiff.path),
              FileManager.default.isReadableFile(atPath: jpeg.path) else { return nil }
        return try? Data(contentsOf: jpeg)
    }

    /// The readable `<uid>.zflat` beside this photo's edits.
    static func tiffURL(uid: String, editsFolder: URL) -> URL? {
        guard !uid.isEmpty else { return nil }
        let url = editsFolder.appendingPathComponent(uid + ".zflat")
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    static func tiffURL(for identity: Identity) -> URL? {
        tiffURL(uid: identity.uid, editsFolder: identity.editsFolder)
    }

    /// Writes an empty edit list, then removes the flattened TIFF and its working JPEG.
    /// The original photograph is left in place.
    static func revertToOriginal(
        uid: String,
        editsFolder: URL,
        previewJPEG: Data,
        blake3: String,
        byteSize: Int,
        uti: String,
        relativePath: String
    ) throws {
        guard !uid.isEmpty else { throw FlattenError.cannotWrite("edits") }
        let zimg = editsFolder.appendingPathComponent(uid + ".zimg")
        let bytes = try SaveEdits.catalogBytes(
            log: HistoryLog(),
            blake3: blake3,
            byteSize: byteSize,
            uti: uti,
            assetUID: uid,
            relativePathHint: relativePath,
            previewJPEG: previewJPEG
        )
        try bytes.write(to: zimg, options: .atomic)
        for name in [uid + ".zjpg", uid + ".zflat"] {
            let url = editsFolder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// `.zimage/edits` above this file, when the library folder is within a few parents.
    static func editsFolder(near file: URL) -> URL? {
        editsFolderByWalking(from: file)
    }

    /// One pass over the edit sidecars. Each row is the catalog path and its `.zflat`.
    static func flattenedMatches(in folder: URL) -> [(relative: String, tiff: URL)] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var matches: [(relative: String, tiff: URL)] = []
        for url in names where url.pathExtension.lowercased() == "zimg" {
            guard let base = ZImgRaw.peekCatalogBase(at: url),
                  let uid = base.assetUID, !uid.isEmpty,
                  let relative = base.relativePathHint, !relative.isEmpty else { continue }
            matches.append((relative, folder.appendingPathComponent(uid + ".zflat")))
        }
        return matches
    }

    private static func findByScanningEdits(of file: URL) -> Identity? {
        let file = file.standardizedFileURL.resolvingSymlinksInPath()
        guard let folder = editsFolderByWalking(from: file) else { return nil }
        let root = folder
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let filePath = file.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var best: (Identity, Int)?
        for url in names where url.pathExtension.lowercased() == "zimg" {
            guard let base = ZImgRaw.peekCatalogBase(at: url),
                  let uid = base.assetUID, !uid.isEmpty,
                  let relative = base.relativePathHint, !relative.isEmpty else { continue }
            let suffix = relative.hasPrefix("/") ? relative : "/" + relative
            guard filePath.hasSuffix(suffix), relative.count > (best?.1 ?? -1) else { continue }
            best = (Identity(uid: uid, relativePath: relative, editsFolder: folder), relative.count)
        }
        return best?.0
    }

    private static func editsFolderByWalking(from file: URL) -> URL? {
        var directory = file.deletingLastPathComponent()
        for _ in 0..<8 {
            let edits = directory.appendingPathComponent(".zimage/edits", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: edits.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return edits
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }
}

/// One look through each edits folder. Folder export asks here for a `.zflat`.
nonisolated final class FlattenSidecarIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var byFolder: [String: [(relative: String, tiff: URL)]] = [:]

    func tiff(for file: URL) -> URL? {
        let file = file.standardizedFileURL.resolvingSymlinksInPath()
        guard let folder = FlattenedMaster.editsFolder(near: file) else { return nil }
        let key = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.path
        var best: (count: Int, url: URL)?
        for match in cachedMatches(folder: folder, key: key) {
            let suffix = match.relative.hasPrefix("/") ? match.relative : "/" + match.relative
            guard path.hasSuffix(suffix), match.relative.count > (best?.count ?? -1) else { continue }
            best = (match.relative.count, match.tiff)
        }
        guard let url = best?.url, FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    private func cachedMatches(folder: URL, key: String) -> [(relative: String, tiff: URL)] {
        lock.lock()
        if let cached = byFolder[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let loaded = FlattenedMaster.flattenedMatches(in: folder)
        lock.lock()
        if byFolder[key] == nil {
            byFolder[key] = loaded
        }
        let matches = byFolder[key] ?? loaded
        lock.unlock()
        return matches
    }
}

nonisolated enum FlattenWriter {
    struct Product: Sendable {
        var previewJPEG: Data
        var workingJPEG: Data
        var bitDepth: Int
        var pixelWidth: Int
        var pixelHeight: Int
    }

    /// 16 when the file can hold more than 8 bits per channel. JPEG and other 8-bit files stay 8.
    static func bitDepth(of url: URL) -> Int {
        let ext = url.pathExtension.lowercased()
        let uti = UTType(filenameExtension: ext)?.identifier ?? "public.data"
        if ProxyRenderer.isCameraRAW(fileExtension: ext, uti: uti) {
            return 16
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return 8
        }
        if let depth = props[kCGImagePropertyDepth] as? Int, depth > 8 {
            return 16
        }
        return 8
    }

    /// Renders `state` onto `pixels` at full size, writes an LZW TIFF to `tiff`, and returns the two JPEGs.
    /// `depthFrom` chooses 8-bit or 16-bit. A second flatten passes the existing `.zflat` as `pixels`.
    static func produce(
        pixels: URL,
        depthFrom: URL,
        state: EditState,
        tiff: URL,
        progress: @escaping @Sendable (String, Int, Int, Double?) -> Void
    ) throws -> Product {
        try InpaintPipeline.validateForExport(state)
        progress("Flattening the photograph", 0, 0, nil)
        let image = try fullImage(pixels)
        let depth = bitDepth(of: depthFrom)
        var request = ExportRequest.standard(.tiff)
        request.bitDepth = depth
        request.tiffCompression = .lzw
        let context = TonePipeline.makeContext()
        let shaped = CropRect.apply(GeometryPipeline.apply(base: image, geometry: state.geometry), crop: state.crop)
        let filled = InpaintPipeline.applyInteractive(
            base: shaped,
            operations: state.inpaints,
            displayTurns: state.geometry.quarterTurns,
            context: context
        ) { fraction, done, total in
            let shown = total > 0 ? min(1, max(0, fraction)) : nil
            progress("Flattening", done, total, shown)
        }
        let longEdge = max(filled.extent.width, filled.extent.height)
        let toned = TonePipeline.apply(base: filled, tone: state.tone, longEdge: max(longEdge, 1))
        let rendered = try StillExporter.rendered(image: toned, request: request, context: context) { done, total in
            let fraction = total > 0 ? Double(done) / Double(total) : nil
            progress("Writing the flattened TIFF", done, total, fraction)
        }
        let temp = tiff.appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try StillExporter.write(rendered, request: request, to: temp)
            try replace(temp, with: tiff)
        } catch {
            try? FileManager.default.removeItem(at: tiff.appendingPathExtension("partial"))
            throw error
        }
        guard let previewJPEG = ZImgRaw.jpegPreview(from: rendered),
              let workingJPEG = ZImgRaw.jpegPreview(from: rendered, maxLongEdge: ProxyRenderer.maxLongEdge) else {
            throw FlattenError.cannotWrite(tiff.lastPathComponent)
        }
        return Product(
            previewJPEG: previewJPEG,
            workingJPEG: workingJPEG,
            bitDepth: depth,
            pixelWidth: rendered.width,
            pixelHeight: rendered.height
        )
    }

    /// Full-size pixels at the depth stored in the file. A `.zflat` is a TIFF under that extension.
    /// A full-size thumbnail can reduce a 16-bit TIFF to 8-bit, so this reads the image itself.
    static func masterImage(_ url: URL) throws -> CIImage {
        let loaded = try masterCGImage(url)
        var image = CIImage(cgImage: loaded.image)
        if loaded.orientation > 1 {
            image = image.oriented(forExifOrientation: loaded.orientation)
        }
        let origin = image.extent.origin
        if origin.x != 0 || origin.y != 0 {
            image = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        }
        return image
    }

    static func masterCGImage(_ url: URL) throws -> (image: CGImage, orientation: Int32) {
        let name = url.lastPathComponent
        var sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true,
        ]
        if url.pathExtension.lowercased() == "zflat" {
            sourceOptions[kCGImageSourceTypeIdentifierHint] = UTType.tiff.identifier as CFString
            if #available(macOS 27.0, *) {
                sourceOptions[kCGImageSourceAllowableTypes] = [UTType.tiff.identifier as CFString]
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            throw FlattenError.cannotRead(name)
        }
        let imageOptions = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, imageOptions) else {
            throw FlattenError.cannotRead(name)
        }
        let orientation: Int32
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            orientation = storedOrientation(props)
        } else {
            orientation = 1
        }
        return (image, orientation)
    }

    private static func storedOrientation(_ props: [CFString: Any]) -> Int32 {
        if let value = orientationNumber(props[kCGImagePropertyOrientation]), value > 0 {
            return value
        }
        let tiff = props[kCGImagePropertyTIFFDictionary]
        if let typed = tiff as? [CFString: Any],
           let value = orientationNumber(typed[kCGImagePropertyTIFFOrientation]), value > 0 {
            return value
        }
        if let dictionary = tiff as? NSDictionary,
           let value = orientationNumber(dictionary[kCGImagePropertyTIFFOrientation]), value > 0 {
            return value
        }
        return 1
    }

    private static func orientationNumber(_ value: Any?) -> Int32? {
        switch value {
        case let number as Int:
            return Int32(number)
        case let number as NSNumber:
            return number.int32Value
        default:
            return nil
        }
    }

    /// Oriented full-size image. RAW is scaled at 1. A still uses a thumbnail the size of the file so orientation is applied.
    private static func fullImage(_ url: URL) throws -> CIImage {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let uti = UTType(filenameExtension: ext)?.identifier ?? "public.data"
        if ProxyRenderer.isCameraRAW(fileExtension: ext, uti: uti) {
            guard let filter = CIRAWFilter(imageURL: url) else {
                throw FlattenError.cannotRead(name)
            }
            filter.scaleFactor = 1
            guard let output = filter.outputImage else {
                throw FlattenError.cannotRead(name)
            }
            return output
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw FlattenError.cannotRead(name)
        }
        var maxPixel = 1
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            maxPixel = max(width, height, 1)
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FlattenError.cannotRead(name)
        }
        return CIImage(cgImage: image)
    }

    private static func replace(_ temp: URL, with destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
    }
}
