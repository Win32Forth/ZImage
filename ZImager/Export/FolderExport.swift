import CoreGraphics
import CoreImage
import Foundation

/// `CGImage` is not `Sendable`. A detached print render hands the page back this way.
nonisolated struct PrintRaster: @unchecked Sendable {
    let image: CGImage
}

/// Writes each selected still into a folder. The original file is never the destination.
nonisolated enum FolderExportWorker {
    static func toned(
        base: CIImage,
        state: EditState,
        tokenPath: String,
        context: CIContext? = nil,
        progress: Touchup.ProgressHandler? = nil
    ) -> CIImage {
        let shaped = CropRect.apply(GeometryPipeline.apply(base: base, geometry: state.geometry), crop: state.crop)
        let filled = InpaintPipeline.applyInteractive(
            base: shaped,
            operations: state.inpaints,
            imageToken: Touchup.imageToken(path: tokenPath, geometry: state.geometry, crop: state.crop),
            displayTurns: state.geometry.quarterTurns,
            context: context,
            progress: progress
        )
        let longEdge = max(filled.extent.width, filled.extent.height)
        return TonePipeline.apply(base: filled, tone: state.tone, longEdge: max(longEdge, 1))
    }

    /// The flattened TIFF, then edits made after that flatten.
    static func tonedFlattened(
        tiff: URL,
        state: EditState,
        tokenPath: String,
        context: CIContext,
        progress: Touchup.ProgressHandler? = nil
    ) throws -> CIImage {
        let base = try FlattenWriter.masterImage(tiff)
        return toned(base: base, state: state, tokenPath: tokenPath, context: context, progress: progress)
    }

    static func write(
        image: CIImage,
        state: EditState,
        request: ExportRequest,
        to url: URL,
        context: CIContext
    ) -> Bool {
        do {
            try StillExporter.write(image: image, state: state, request: request, to: url, context: context)
            return true
        } catch {
            return false
        }
    }

    /// Writes the flattened TIFF into `folder`. A TIFF that will not load fails this file.
    static func write(
        flattened tiff: URL,
        file: URL,
        folder: URL,
        request: ExportRequest,
        state: EditState
    ) -> Bool {
        guard let destination = destination(for: file, folder: folder, ext: request.fileExtension) else {
            return false
        }
        return write(flattened: tiff, state: state, tokenPath: file.path, request: request, to: destination)
    }

    static func write(
        flattened tiff: URL,
        state: EditState,
        tokenPath: String,
        request: ExportRequest,
        to destination: URL,
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        repairProgress: Touchup.ProgressHandler? = nil
    ) -> Bool {
        if destination.standardizedFileURL.resolvingSymlinksInPath()
            == tiff.standardizedFileURL.resolvingSymlinksInPath() {
            return false
        }
        let context = TonePipeline.makeContext()
        do {
            let image = try tonedFlattened(
                tiff: tiff,
                state: state,
                tokenPath: tokenPath,
                context: context,
                progress: repairProgress
            )
            try StillExporter.write(
                image: image,
                state: state,
                request: request,
                to: destination,
                context: context,
                progress: progress
            )
            return true
        } catch {
            return false
        }
    }

    /// Opens the still, applies its saved settings, and writes `stem.extension` into `folder`.
    /// A flattened `.zflat` is the source when that file is present. A session log wins over the stored `.zimg`.
    static func write(
        file: URL,
        folder: URL,
        request: ExportRequest,
        session: HistoryLog?,
        sidecars: FlattenSidecarIndex = FlattenSidecarIndex()
    ) -> Bool {
        let started = file.startAccessingSecurityScopedResource()
        defer {
            if started {
                file.stopAccessingSecurityScopedResource()
            }
        }
        let state: EditState
        if let session {
            state = session.state
        } else if let bytes = try? Data(contentsOf: file), !bytes.isEmpty {
            let digest = Blake3.hex(bytes)
            state = storedLog(digest: digest, count: bytes.count)?.state ?? .identity
        } else {
            return false
        }
        guard let destination = destination(for: file, folder: folder, ext: request.fileExtension) else {
            return false
        }
        if let tiff = sidecars.tiff(for: file) {
            return write(flattened: tiff, state: state, tokenPath: file.path, request: request, to: destination)
        }
        guard let proxy = try? ProxyRenderer.open(url: file) else { return false }
        let image = toned(base: CIImage(cgImage: proxy.image), state: state, tokenPath: file.path)
        let context = TonePipeline.makeContext()
        return write(image: image, state: state, request: request, to: destination, context: context)
    }

    /// The edited still, at the proxy size. A session log wins. Otherwise the stored `.zimg`. An unedited photo stays as opened.
    static func rendered(file: URL, session: HistoryLog?) -> PrintRaster? {
        let started = file.startAccessingSecurityScopedResource()
        defer {
            if started {
                file.stopAccessingSecurityScopedResource()
            }
        }
        let state: EditState
        if let session {
            state = session.state
        } else if let bytes = try? Data(contentsOf: file), !bytes.isEmpty {
            let digest = Blake3.hex(bytes)
            state = storedLog(digest: digest, count: bytes.count)?.state ?? .identity
        } else {
            return nil
        }
        guard let proxy = try? ProxyRenderer.open(url: file) else { return nil }
        let image = toned(base: CIImage(cgImage: proxy.image), state: state, tokenPath: file.path)
        let context = TonePipeline.makeContext()
        guard let page = raster(image, context: context) else { return nil }
        return PrintRaster(image: page)
    }

    static func raster(_ image: CIImage, context: CIContext) -> CGImage? {
        let extent = image.extent.integral
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: space)
    }

    /// `stem.ext`, or `stem-2.ext` when that path is the original or already exists.
    static func destination(for file: URL, folder: URL, ext: String) -> URL? {
        let stem = file.deletingPathExtension().lastPathComponent
        let name = stem.isEmpty ? "Export" : stem
        let source = file.standardizedFileURL
        var candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var suffix = 2
        while candidate.standardizedFileURL == source || FileManager.default.fileExists(atPath: candidate.path) {
            if suffix > 9999 { return nil }
            candidate = folder.appendingPathComponent("\(name)-\(suffix)").appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }

    private static func storedLog(digest: String, count: Int) -> HistoryLog? {
        guard let url = try? LocalEditStore.fileURL(digest: digest),
              let document = try? ZImgRaw.read(from: url),
              document.base.kind == .fileRef,
              document.base.blake3 == digest,
              document.base.byteSize == count else {
            return nil
        }
        return document.history
    }
}
