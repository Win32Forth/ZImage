internal import CImageCodecs
import Foundation

/// libwebp 1.6.0 (encoder ABI 0x0210), static `libwebp` plus `libsharpyuv`. BSD-3-Clause.
/// Lossy default quality is 80 on the 0...100 scale. Lossless uses the simple RGBA encoder.
/// Opaque pixels stay exact. `WebPConfig.exact` is only required to keep RGB under transparent pixels.
nonisolated enum WebPWriter {
    static let libraryVersion = "1.6.0"
    static let defaultQuality: Float = 80

    static func encodeRGBA(_ rgba: Data, width: Int, height: Int, quality: Float) throws -> Data {
        let bytes = try checked(rgba, width: width, height: height, channels: 4)
        var output: UnsafeMutablePointer<UInt8>?
        let clamped = min(100, max(0, quality))
        let size = bytes.withUnsafeBytes { raw -> Int in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            return WebPEncodeRGBA(base, Int32(width), Int32(height), Int32(width * 4), clamped, &output)
        }
        defer { WebPFree(output) }
        guard size > 0, let output else {
            throw ExportError.cannotEncode("WebP")
        }
        return Data(bytes: output, count: size)
    }

    static func encodeLosslessRGBA(_ rgba: Data, width: Int, height: Int) throws -> Data {
        let bytes = try checked(rgba, width: width, height: height, channels: 4)
        var output: UnsafeMutablePointer<UInt8>?
        let size = bytes.withUnsafeBytes { raw -> Int in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            return WebPEncodeLosslessRGBA(base, Int32(width), Int32(height), Int32(width * 4), &output)
        }
        defer { WebPFree(output) }
        guard size > 0, let output else {
            throw ExportError.cannotEncode("WebP")
        }
        return Data(bytes: output, count: size)
    }

    static func decodeRGBA(_ data: Data) throws -> (width: Int, height: Int, rgba: Data) {
        var width: Int32 = 0
        var height: Int32 = 0
        let pointer = data.withUnsafeBytes { raw -> UnsafeMutablePointer<UInt8>? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return WebPDecodeRGBA(base, raw.count, &width, &height)
        }
        guard let pointer, width > 0, height > 0 else {
            throw ExportError.cannotEncode("WebP")
        }
        defer { WebPFree(pointer) }
        let count = Int(width) * Int(height) * 4
        return (Int(width), Int(height), Data(bytes: pointer, count: count))
    }

    private static func checked(_ data: Data, width: Int, height: Int, channels: Int) throws -> Data {
        guard width > 0, height > 0, data.count == width * height * channels else {
            throw ExportError.cannotEncode("WebP")
        }
        return data
    }
}
