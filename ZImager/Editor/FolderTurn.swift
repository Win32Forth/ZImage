import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shift-click selects the range from the anchor through the clicked item.
/// Control-click or Command-click toggles that one item and leaves the others selected.
enum GridSelection {
    static func choose(
        order: [String],
        anchor: String?,
        clicked: String,
        shift: Bool,
        extend: Bool = false,
        existing: Set<String> = []
    ) -> (keys: Set<String>, anchor: String?, primary: String?) {
        if extend {
            var keys = existing
            if keys.contains(clicked) {
                keys.remove(clicked)
            } else {
                keys.insert(clicked)
                return (keys, clicked, clicked)
            }
            guard !keys.isEmpty else { return ([], nil, nil) }
            if let anchor, keys.contains(anchor) {
                return (keys, anchor, anchor)
            }
            let fallback = order.first { keys.contains($0) } ?? keys.first
            return (keys, fallback, fallback)
        }
        if shift,
           let anchor,
           let start = order.firstIndex(of: anchor),
           let end = order.firstIndex(of: clicked) {
            let slice = order[min(start, end)...max(start, end)]
            return (Set(slice), anchor, clicked)
        }
        return ([clicked], clicked, clicked)
    }
}

struct CatalogEditTarget: Sendable, Equatable {
    var uid: String
    var relativePath: String
}

/// One folder-grid rotation. The original file is not modified.
nonisolated enum FolderTurnWorker {
    struct Outcome: Sendable {
        var log: HistoryLog
        var previewJPEG: Data
        var digest: String
        var byteCount: Int
        var uti: String
        var documentBookmark: Data?
    }

    enum Failure: Error {
        case unreadable
        case noPreview
    }

    /// Reads the photo, adds one quarter-turn to its saved settings, and writes the `.zimg`.
    /// The preview is tone, geometry, and crop. Dust and scratch masks stay in the log and
    /// are drawn when that photo is open, because those masks belong to the full-size image.
    static func rotate(file: URL, clockwise: Bool, session: HistoryLog?) -> Result<Outcome, Failure> {
        updating(file: file, session: session) { log in
            var geometry = log.state.geometry
            geometry.quarterTurns = GeometryPipeline.wrap(geometry.quarterTurns + (clockwise ? 1 : -1))
            log.commit(.setGeometry(geometry, label: clockwise ? "Rotate clockwise" : "Rotate counterclockwise"))
        }
    }

    /// Tone and Geometry saved for a still that is not on the canvas. An unedited photo is identity.
    static func adjustments(file: URL) -> (tone: ToneState, geometry: GeometryState)? {
        let started = file.startAccessingSecurityScopedResource()
        defer {
            if started {
                file.stopAccessingSecurityScopedResource()
            }
        }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: file)
        } catch {
            return nil
        }
        guard !bytes.isEmpty else { return nil }
        let digest = Blake3.hex(bytes)
        let state = storedLog(digest: digest, count: bytes.count)?.state ?? .identity
        return (state.tone, state.geometry)
    }

    /// Replaces Tone and Geometry with the copied settings. Crop and object removal stay.
    static func paste(
        file: URL,
        tone: ToneState,
        geometry: GeometryState,
        session: HistoryLog?
    ) -> Result<Outcome, Failure> {
        updating(file: file, session: session) { log in
            guard log.state.tone != tone || log.state.geometry != geometry else { return }
            log.commit(.pasteSettings(tone: tone, geometry: geometry))
        }
    }

    private static func updating(
        file: URL,
        session: HistoryLog?,
        change: (inout HistoryLog) -> Void
    ) -> Result<Outcome, Failure> {
        let bytes: Data
        do {
            bytes = try Data(contentsOf: file)
        } catch {
            return .failure(.unreadable)
        }
        guard !bytes.isEmpty else { return .failure(.unreadable) }
        let digest = Blake3.hex(bytes)
        var log = session ?? storedLog(digest: digest, count: bytes.count) ?? HistoryLog()
        change(&log)
        guard let rendered = render(file: file, state: log.state) else { return .failure(.noPreview) }
        guard let previewJPEG = ZImgRaw.jpegPreview(from: rendered, maxLongEdge: 1600) else {
            return .failure(.noPreview)
        }
        let uti = (try? file.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier)
            ?? UTType(filenameExtension: file.pathExtension)?.identifier
            ?? "public.data"
        let sourceBookmark = try? file.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        do {
            let document = try ZImgRaw.bytesForSavePanel(
                log: log,
                original: bytes,
                pathHint: file.path,
                bookmark: sourceBookmark,
                uti: uti,
                previewJPEG: previewJPEG
            )
            let destination = try LocalEditStore.fileURL(digest: digest)
            try document.write(to: destination, options: .atomic)
            let stored = try? destination.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return .success(Outcome(
                log: log,
                previewJPEG: previewJPEG,
                digest: digest,
                byteCount: bytes.count,
                uti: uti,
                documentBookmark: stored
            ))
        } catch {
            return .failure(.unreadable)
        }
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

    private static func render(file: URL, state: EditState) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let base = CIImage(cgImage: thumb)
        let shaped = CropRect.apply(GeometryPipeline.apply(base: base, geometry: state.geometry), crop: state.crop)
        let edge = max(shaped.extent.width, shaped.extent.height)
        let toned = TonePipeline.apply(base: shaped, tone: state.tone, longEdge: max(edge, 1))
        let extent = toned.extent.integral
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let context = TonePipeline.makeContext()
        return context.createCGImage(
            toned,
            from: extent,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        )
    }
}
