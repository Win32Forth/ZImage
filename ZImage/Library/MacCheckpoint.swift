import CoreGraphics
import CoreImage
import Foundation
import ImageIO

enum MacCheckpointError: Error {
    case unreadable
}

/// One still at a time. ImageIO stops at 1024 px. Lanczos then reaches a long edge of 512.
enum MacCheckpoint {
    static func payloads(for url: URL) throws -> (facts: Data, detail: Data) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MacCheckpointError.unreadable
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MacCheckpointError.unreadable
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = integer(props?[kCGImagePropertyPixelWidth]) ?? thumb.width
        let height = integer(props?[kCGImagePropertyPixelHeight]) ?? thumb.height
        let facts = factsBody(
            dhash: differenceHash(thumb),
            width: width,
            height: height,
            thumbnail: jpegData(fitted(thumb)),
            captureTime: captureTime(props)
        )
        let detail = detailBody(
            score: detailScore(thumb),
            nativePixels: width * height,
            width: width,
            height: height,
            source: "mac"
        )
        return (facts, detail)
    }

    static func factsBody(dhash: UInt64, width: Int, height: Int, thumbnail: Data?, captureTime: String?) -> Data {
        struct Body: Encodable {
            var dhash: String
            var width: Int
            var height: Int
            var thumbnail: String?
            var captureTime: String?
        }
        let body = Body(
            dhash: String(format: "%016llx", dhash),
            width: width,
            height: height,
            thumbnail: thumbnail?.base64EncodedString(),
            captureTime: captureTime
        )
        return (try? JSONEncoder().encode(body)) ?? Data()
    }

    static func detailBody(score: Double, nativePixels: Int, width: Int, height: Int, source: String) -> Data {
        struct Body: Encodable {
            var detailScore: Double
            var nativePixels: Int
            var width: Int
            var height: Int
            var detailSource: String
        }
        let body = Body(
            detailScore: score,
            nativePixels: nativePixels,
            width: width,
            height: height,
            detailSource: source
        )
        return (try? JSONEncoder().encode(body)) ?? Data()
    }

    /// 64-bit difference hash. Bit 0 is the first comparison on the top row.
    static func differenceHash(_ image: CGImage) -> UInt64 {
        let sw = image.width
        let sh = image.height
        guard sw > 0, sh > 0, let bytes = bitmap(image) else { return 0 }
        let dw = 9
        let dh = 8
        var px = [Double](repeating: 0, count: dw * dh)
        for y in 0..<dh {
            var sy = (y * sh) / dh
            if sy >= sh { sy = sh - 1 }
            for x in 0..<dw {
                var sx = (x * sw) / dw
                if sx >= sw { sx = sw - 1 }
                let i = (sy * sw + sx) * 4
                guard i + 2 < bytes.count else { continue }
                px[y * dw + x] = 0.299 * Double(bytes[i]) + 0.587 * Double(bytes[i + 1]) + 0.114 * Double(bytes[i + 2])
            }
        }
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                if px[y * dw + x] > px[y * dw + x + 1] {
                    hash |= 1 << bit
                }
                bit += 1
            }
        }
        return hash
    }

    /// Laplacian population variance on a long edge of 512. A 4 px border is ignored.
    static func detailScore(_ image: CGImage) -> Double {
        let scaled = fitted(image)
        guard let bytes = bitmap(scaled) else { return 0 }
        let width = scaled.width
        let height = scaled.height
        guard width > 0, height > 0, bytes.count >= width * height * 4 else { return 0 }
        var gray = [Double](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            gray[index] = 0.299 * Double(bytes[offset]) + 0.587 * Double(bytes[offset + 1]) + 0.114 * Double(bytes[offset + 2])
        }
        return laplacianVariance(gray, width: width, height: height, border: 4)
    }

    static func image(width: Int, height: Int, sample: (Int, Int) -> UInt8) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = sample(x, y)
                let index = (y * width + x) * 4
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func fitted(_ image: CGImage) -> CGImage {
        var current = image
        if max(current.width, current.height) > 1024 {
            current = scaled(current, toLongEdge: 1024) ?? current
        }
        if max(current.width, current.height) == 512 { return current }
        return scaled(current, toLongEdge: 512) ?? current
    }

    private static func scaled(_ image: CGImage, toLongEdge edge: Int) -> CGImage? {
        let long = max(image.width, image.height)
        guard long > 0, edge > 0 else { return nil }
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(Double(edge) / Double(long), forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        return context.createCGImage(output, from: output.extent.integral)
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), data.length > 0, data.length <= 2_000_000 else { return nil }
        return data as Data
    }

    private static func captureTime(_ props: [CFString: Any]?) -> String? {
        guard let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let pieces = raw.split(separator: " ")
        guard pieces.count == 2, pieces[0].count == 10 else { return nil }
        let day = pieces[0].replacingOccurrences(of: ":", with: "-")
        let clock = String(pieces[1])
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String,
           let first = offset.first, first == "+" || first == "-" {
            return "\(day)T\(clock)\(offset)"
        }
        return "\(day)T\(clock)Z"
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func bitmap(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        return drew ? bytes : nil
    }

    private static func laplacianVariance(_ gray: [Double], width: Int, height: Int, border: Int) -> Double {
        if width <= border * 2 || height <= border * 2 { return 0 }
        var sum = 0.0
        var count = 0
        for y in border..<(height - border) {
            for x in border..<(width - border) {
                sum += laplacian(gray, width: width, x: x, y: y)
                count += 1
            }
        }
        if count == 0 { return 0 }
        let mean = sum / Double(count)
        var acc = 0.0
        for y in border..<(height - border) {
            for x in border..<(width - border) {
                let delta = laplacian(gray, width: width, x: x, y: y) - mean
                acc += delta * delta
            }
        }
        return acc / Double(count)
    }

    private static func laplacian(_ gray: [Double], width: Int, x: Int, y: Int) -> Double {
        let index = y * width + x
        return gray[index - width] + gray[index - 1] - 4 * gray[index] + gray[index + 1] + gray[index + width]
    }
}
