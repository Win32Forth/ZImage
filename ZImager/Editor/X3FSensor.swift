import CoreGraphics
import Foundation
import ImageIO

/// Opens an X3F for editing. The sensor decode wins. The embedded preview remains when it cannot.
nonisolated enum X3FFiles {
    static func open(url: URL) -> Result<X3FOpened, X3FOpenError> {
        if let sensor = X3FSensor.open(url: url) {
            return .success(sensor)
        }
        do {
            return .success(try X3FPreview.open(url: url))
        } catch let error as X3FOpenError {
            return .failure(error)
        } catch {
            return .failure(.noPreview(url.lastPathComponent))
        }
    }
}

/// Developed Foveon image from the bundled x3fuse-core converter.
/// The converter writes a 16-bit sRGB TIFF. ImageIO scales it to the editor proxy.
/// A missing converter, a small file, a rejected file, or a timeout returns nil.
nonisolated enum X3FSensor {
    static let binaryName = "zimager-x3f"
    /// Camera files are many megabytes. Smaller files are previews and test fixtures.
    static let minimumBytes: UInt64 = 64 * 1024
    static let timeoutSeconds: TimeInterval = 180

    static func open(url: URL) -> X3FOpened? {
        guard let tool = converterURL() else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard UInt64(values?.fileSize ?? 0) >= minimumBytes else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimager-x3f-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: output) }
        guard convert(tool: tool, input: url, output: output) else { return nil }
        guard let image = thumbnail(at: output) else { return nil }
        guard image.width >= 1, image.height >= 1 else { return nil }
        guard max(image.width, image.height) <= ProxyRenderer.maxLongEdge else { return nil }
        return X3FOpened(
            proxy: ProxyImage(
                image: image,
                entryPoint: .imageIOThumbnail,
                appliedScaleFactor: nil,
                nativeLongEdge: nil
            ),
            decodeSupport: .full,
            banner: nil,
            jpegByteCount: 0,
            bytesRead: 0
        )
    }

    /// `ZIMAGER_X3F` selects the converter. An empty or missing path disables sensor decode.
    static func converterURL() -> URL? {
        if getenv("ZIMAGER_X3F") != nil {
            guard let raw = getenv("ZIMAGER_X3F") else { return nil }
            let path = String(cString: raw)
            guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        guard let folder = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let bundled = folder.appendingPathComponent(binaryName)
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else { return nil }
        return bundled
    }

    private static func convert(tool: URL, input: URL, output: URL) -> Bool {
        let process = Process()
        process.executableURL = tool
        process.arguments = [input.path, output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }
        do {
            try process.run()
        } catch {
            return false
        }
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            return false
        }
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path)
    }

    private static func thumbnail(at url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: ProxyRenderer.maxLongEdge,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
