import CoreGraphics
import Foundation
import ImageIO

/// How a file was decoded. The catalog stores the raw value.
nonisolated enum DecodeSupport: String, Equatable, Sendable {
    case full
    case previewOnly = "preview_only"
    case unsupported
    case unknown
}

/// Sigma X3F is preview-only. The largest embedded JPEG at most 8 MB is the image.
nonisolated enum X3FPreview {
    static let banner = "Sigma X3F preview only. Full Foveon decode is not available."
    static let readBudget = 64 * 1024 * 1024
    static let maxJPEGBytes = 8 * 1024 * 1024
    static let notX3FMessage = "Not an X3F file."

    static func open(url: URL) throws -> X3FOpened {
        let extracted = try extractJPEG(url: url)
        let image = try thumbnail(extracted.jpeg)
        return X3FOpened(
            proxy: ProxyImage(
                image: image,
                entryPoint: .imageIOThumbnail,
                appliedScaleFactor: nil,
                nativeLongEdge: nil
            ),
            decodeSupport: .previewOnly,
            banner: banner,
            jpegByteCount: extracted.jpeg.count,
            bytesRead: extracted.bytesRead
        )
    }

    /// Walks the directory pointer at the end of the file. Reads at most `readBudget` bytes.
    static func extractJPEG(url: URL) throws -> X3FExtract {
        let fileName = url.lastPathComponent
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var budget = readBudget

        func take(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count > 0, budget >= count, offset <= fileSize, offset + UInt64(count) <= fileSize else {
                throw X3FOpenError.noPreview(fileName)
            }
            budget -= count
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw X3FOpenError.noPreview(fileName)
            }
            return data
        }

        guard fileSize >= 4 else { throw X3FOpenError.notX3F }
        let magic = try take(0, 4)
        guard magic == Data("FOVb".utf8) else { throw X3FOpenError.notX3F }
        guard fileSize >= 8 else { throw X3FOpenError.noPreview(fileName) }

        let pointer = try take(fileSize - 4, 4)
        let directory = UInt64(uint32(pointer, 0))
        guard directory + 12 <= fileSize else { throw X3FOpenError.noPreview(fileName) }

        let header = try take(directory, 12)
        guard header.prefix(4) == Data("SECd".utf8) else { throw X3FOpenError.noPreview(fileName) }
        let count = Int(uint32(header, 8))
        guard count >= 0, count <= 4096 else { throw X3FOpenError.noPreview(fileName) }
        let tableBytes = count * 12
        guard tableBytes == 0 || directory + 12 + UInt64(tableBytes) <= fileSize else {
            throw X3FOpenError.noPreview(fileName)
        }
        let table = count == 0 ? Data() : try take(directory + 12, tableBytes)

        var best: (offset: UInt64, count: Int)?
        for index in 0..<count {
            let entry = table.subdata(in: index * 12..<(index + 1) * 12)
            let offset = UInt64(uint32(entry, 0))
            let length = UInt64(uint32(entry, 4))
            guard length > 0, offset < fileSize, offset + length <= fileSize else { continue }
            if let payload = try jpegPayload(at: offset, length: length, take: take) {
                if best == nil || payload.count > best!.count {
                    best = payload
                }
            }
        }

        guard let best else { throw X3FOpenError.noPreview(fileName) }
        let jpeg = try take(best.offset, best.count)
        guard jpeg.starts(with: [0xFF, 0xD8]) else { throw X3FOpenError.noPreview(fileName) }
        return X3FExtract(jpeg: jpeg, bytesRead: readBudget - budget)
    }

    private static func jpegPayload(
        at offset: UInt64,
        length: UInt64,
        take: (UInt64, Int) throws -> Data
    ) throws -> (offset: UInt64, count: Int)? {
        let peekCount = Int(min(length, 28))
        let peek = try take(offset, peekCount)
        if peek.starts(with: [0xFF, 0xD8]) {
            guard length <= UInt64(maxJPEGBytes) else { return nil }
            return (offset, Int(length))
        }
        guard peek.count >= 28, peek.prefix(4) == Data("SECi".utf8) else { return nil }
        let format = uint32(peek, 12)
        guard format == 18 else { return nil }
        let payload = length - 28
        guard payload > 2, payload <= UInt64(maxJPEGBytes) else { return nil }
        let soi = try take(offset + 28, 2)
        guard soi == Data([0xFF, 0xD8]) else { return nil }
        return (offset + 28, Int(payload))
    }

    private static func thumbnail(_ data: Data) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw X3FOpenError.noPreview("preview")
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: ProxyRenderer.maxLongEdge,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              max(image.width, image.height) <= ProxyRenderer.maxLongEdge else {
            throw X3FOpenError.noPreview("preview")
        }
        return image
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let bytes = [UInt8](data[offset..<(offset + 4)])
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }
}

nonisolated struct X3FExtract: Sendable {
    var jpeg: Data
    var bytesRead: Int
}

nonisolated struct X3FOpened: Sendable {
    var proxy: ProxyImage
    var decodeSupport: DecodeSupport
    var banner: String
    var jpegByteCount: Int
    var bytesRead: Int
}

nonisolated enum X3FOpenError: Error, Equatable, LocalizedError {
    case notX3F
    case noPreview(String)

    var errorDescription: String? {
        switch self {
        case .notX3F:
            return X3FPreview.notX3FMessage
        case .noPreview(let name):
            return "Could not read a JPEG preview from \(name)."
        }
    }
}
