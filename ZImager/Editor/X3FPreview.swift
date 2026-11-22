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

/// Sigma X3F embedded preview. The sensor image is opened by `X3FSensor`.
/// Type 2 previews are format 3 (plain RGB), 11 (Huffman DPCM), or 18 (JPEG).
nonisolated enum X3FPreview {
    static let banner = "Sigma X3F preview only. Full Foveon decode is not available."
    /// One preview image. A corrupt directory entry cannot allocate past this.
    static let readBudget = 128 * 1024 * 1024
    static let notX3FMessage = "Not an X3F file."
    private static let maxEdge = 20_000
    private static let maxPixels = 48_000_000

    static func open(url: URL) throws -> X3FOpened {
        let fitted = try fittedImage(url: url, maxLongEdge: ProxyRenderer.maxLongEdge)
        return X3FOpened(
            proxy: ProxyImage(
                image: fitted.image,
                entryPoint: .imageIOThumbnail,
                appliedScaleFactor: nil,
                nativeLongEdge: nil
            ),
            decodeSupport: .previewOnly,
            banner: banner,
            jpegByteCount: fitted.byteCount,
            bytesRead: fitted.bytesRead
        )
    }

    /// The preview scaled so its long edge is at most `maxLongEdge`.
    static func fittedImage(url: URL, maxLongEdge: Int) throws -> X3FFitted {
        let fileName = url.lastPathComponent
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let reader = Reader(handle: handle, fileSize: fileSize, fileName: fileName)
        guard fileSize >= 4 else { throw X3FOpenError.notX3F }
        guard let magic = try reader.bytes(at: 0, count: 4), magic == Data("FOVb".utf8) else {
            throw X3FOpenError.notX3F
        }
        let choices = try candidates(reader)
        guard !choices.isEmpty else { throw X3FOpenError.noPreview(fileName) }
        for choice in choices {
            if let image = try decode(choice, reader: reader, maxLongEdge: maxLongEdge) {
                return X3FFitted(image: image, byteCount: choice.payloadCount, bytesRead: reader.bytesRead)
            }
        }
        throw X3FOpenError.noPreview(fileName)
    }

    private static func candidates(_ reader: Reader) throws -> [Choice] {
        guard reader.fileSize >= 8,
              let pointer = try reader.bytes(at: reader.fileSize - 4, count: 4) else {
            return []
        }
        let directory = UInt64(uint32(pointer, 0))
        guard let header = try reader.bytes(at: directory, count: 12),
              header.prefix(4) == Data("SECd".utf8) else {
            return []
        }
        let count = Int(uint32(header, 8))
        guard (0...4096).contains(count) else { return [] }
        let tableBytes = count * 12
        guard tableBytes == 0 || directory + 12 + UInt64(tableBytes) <= reader.fileSize else { return [] }
        let table: Data
        if count == 0 {
            table = Data()
        } else if let loaded = try reader.bytes(at: directory + 12, count: tableBytes) {
            table = loaded
        } else {
            return []
        }

        var choices: [Choice] = []
        for index in 0..<count {
            let entry = table.subdata(in: index * 12..<(index + 1) * 12)
            let offset = UInt64(uint32(entry, 0))
            let length = UInt64(uint32(entry, 4))
            guard length >= 4, length <= UInt64(readBudget),
                  offset <= reader.fileSize, length <= reader.fileSize - offset else {
                continue
            }
            let peekCount = Int(min(length, 28))
            guard let peek = try reader.bytes(at: offset, count: peekCount) else { continue }
            if peek.starts(with: [0xFF, 0xD8]) {
                let pixels = try jpegPixels(reader, at: offset, count: Int(length))
                choices.append(Choice(
                    offset: offset,
                    length: Int(length),
                    pixels: pixels,
                    format: 18,
                    columns: 0,
                    rows: 0,
                    rowSize: 0,
                    seci: false
                ))
                continue
            }
            guard peek.count >= 28, peek.prefix(4) == Data("SECi".utf8) else { continue }
            let imageType = uint32(peek, 8)
            let format = uint32(peek, 12)
            guard imageType == 2, format == 3 || format == 11 || format == 18 else { continue }
            let columns = Int(uint32(peek, 16))
            let rows = Int(uint32(peek, 20))
            var pixels = 0
            if columns > 0, rows > 0, columns <= maxEdge, rows <= maxEdge, rows <= maxPixels / columns {
                pixels = columns * rows
            }
            if format == 18, pixels == 0 {
                pixels = try jpegPixels(reader, at: offset + 28, count: Int(length - 28))
            }
            choices.append(Choice(
                offset: offset,
                length: Int(length),
                pixels: pixels,
                format: Int(format),
                columns: columns,
                rows: rows,
                rowSize: uint32(peek, 24),
                seci: true
            ))
        }
        choices.sort { lhs, rhs in
            if lhs.pixels != rhs.pixels {
                return lhs.pixels > rhs.pixels
            }
            return lhs.payloadCount > rhs.payloadCount
        }
        return choices
    }

    private static func decode(_ choice: Choice, reader: Reader, maxLongEdge: Int) throws -> CGImage? {
        switch choice.format {
        case 3:
            return try pixmap(choice, reader: reader, maxLongEdge: maxLongEdge)
        case 11:
            return try huffman(choice, reader: reader, maxLongEdge: maxLongEdge)
        case 18:
            return try jpeg(choice, reader: reader, maxLongEdge: maxLongEdge)
        default:
            return nil
        }
    }

    private static func jpeg(_ choice: Choice, reader: Reader, maxLongEdge: Int) throws -> CGImage? {
        guard choice.payloadCount > 2,
              let data = try reader.bytes(at: choice.payloadOffset, count: choice.payloadCount),
              data.starts(with: [0xFF, 0xD8]) else {
            return nil
        }
        return thumbnail(data, maxLongEdge: maxLongEdge)
    }

    private static func pixmap(_ choice: Choice, reader: Reader, maxLongEdge: Int) throws -> CGImage? {
        guard legal(columns: choice.columns, rows: choice.rows),
              let payload = try reader.bytes(at: choice.payloadOffset, count: choice.payloadCount),
              let rgb = plainRGB(payload, columns: choice.columns, rows: choice.rows, rowSize: choice.rowSize),
              let image = raster(rgb, columns: choice.columns, rows: choice.rows) else {
            return nil
        }
        return scale(image, longEdge: maxLongEdge)
    }

    private static func huffman(_ choice: Choice, reader: Reader, maxLongEdge: Int) throws -> CGImage? {
        guard legal(columns: choice.columns, rows: choice.rows),
              let payload = try reader.bytes(at: choice.payloadOffset, count: choice.payloadCount),
              let rgb = huffmanRGB(payload, columns: choice.columns, rows: choice.rows),
              let image = raster(rgb, columns: choice.columns, rows: choice.rows) else {
            return nil
        }
        return scale(image, longEdge: maxLongEdge)
    }

    /// Format 3. Rows are RGB triples padded to the header stride, or to 4 bytes.
    private static func plainRGB(_ payload: Data, columns: Int, rows: Int, rowSize: UInt32) -> [UInt8]? {
        let packed = columns * 3
        var stride = Int(rowSize)
        if stride == 0 {
            stride = (packed + 3) & ~3
        }
        guard stride >= packed, rows <= Int.max / stride, stride * rows <= payload.count else { return nil }
        var rgb = [UInt8](repeating: 0, count: packed * rows)
        for row in 0..<rows {
            let source = payload.startIndex + row * stride
            for index in 0..<packed {
                rgb[row * packed + index] = payload[source + index]
            }
        }
        return rgb
    }

    /// Format 11. A 256-entry code table, then the bitstream, then one offset per row.
    private static func huffmanRGB(_ payload: Data, columns: Int, rows: Int) -> [UInt8]? {
        let tableBytes = 256 * 4
        let offsetBytes = rows * 4
        guard payload.count > tableBytes + offsetBytes else { return nil }
        var nodes = [HuffNode()]
        for symbol in 0..<256 {
            let entry = uint32(payload, symbol * 4)
            if entry == 0 { continue }
            let length = Int(entry >> 27)
            let code = entry & 0x07ff_ffff
            guard (1...27).contains(length) else { continue }
            var node = 0
            for step in 0..<length {
                if nodes[node].symbol >= 0 { return nil }
                let bit = Int((code >> (length - 1 - step)) & 1)
                var next = bit == 0 ? nodes[node].zero : nodes[node].one
                if next < 0 {
                    nodes.append(HuffNode())
                    next = nodes.count - 1
                    if bit == 0 {
                        nodes[node].zero = next
                    } else {
                        nodes[node].one = next
                    }
                }
                node = next
            }
            if nodes[node].symbol >= 0 || nodes[node].zero >= 0 || nodes[node].one >= 0 {
                return nil
            }
            nodes[node].symbol = symbol
        }
        let encodedEnd = payload.count - offsetBytes
        let encoded = payload.subdata(in: tableBytes..<encodedEnd)
        let offsets = payload.subdata(in: encodedEnd..<payload.count)
        var rgb = [UInt8](repeating: 0, count: columns * rows * 3)
        for row in 0..<rows {
            let rowOffset = Int(uint32(offsets, row * 4))
            guard rowOffset >= 0, rowOffset <= encoded.count else { return nil }
            var cursor = BitCursor(data: encoded, byte: rowOffset)
            var predictor = [UInt8](repeating: 0, count: 3)
            for column in 0..<columns {
                for channel in 0..<3 {
                    guard let symbol = cursor.symbol(nodes) else { return nil }
                    predictor[channel] = predictor[channel] &+ UInt8(truncatingIfNeeded: symbol)
                    rgb[(row * columns + column) * 3 + channel] = predictor[channel]
                }
            }
        }
        return rgb
    }

    private static func jpegPixels(_ reader: Reader, at offset: UInt64, count: Int) throws -> Int {
        guard count > 4 else { return 0 }
        let prefix = min(count, 256 * 1024)
        guard let data = try reader.bytes(at: offset, count: prefix), data.starts(with: [0xFF, 0xD8]) else {
            return 0
        }
        var index = 2
        while index + 3 < data.count {
            guard data[index] == 0xFF else { return 0 }
            index += 1
            while index < data.count, data[index] == 0xFF { index += 1 }
            guard index < data.count else { return 0 }
            let marker = data[index]
            index += 1
            if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { continue }
            if marker == 0xD9 || marker == 0xDA { return 0 }
            guard index + 1 < data.count else { return 0 }
            let length = (Int(data[index]) << 8) | Int(data[index + 1])
            guard length >= 2 else { return 0 }
            let isSOF = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isSOF {
                guard index + 6 < data.count else { return 0 }
                let height = (Int(data[index + 3]) << 8) | Int(data[index + 4])
                let width = (Int(data[index + 5]) << 8) | Int(data[index + 6])
                guard width > 0, height > 0, width <= maxEdge, height <= maxEdge else { return 0 }
                return width * height
            }
            guard index + length <= data.count else { return 0 }
            index += length
        }
        return 0
    }

    private static func thumbnail(_ data: Data, maxLongEdge: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxLongEdge),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              max(image.width, image.height) <= max(1, maxLongEdge) else {
            return nil
        }
        return image
    }

    private static func raster(_ rgb: [UInt8], columns: Int, rows: Int) -> CGImage? {
        let bytesPerRow = columns * 4
        var pixels = [UInt8](repeating: 255, count: rows * bytesPerRow)
        for index in 0..<(columns * rows) {
            pixels[index * 4] = rgb[index * 3]
            pixels[index * 4 + 1] = rgb[index * 3 + 1]
            pixels[index * 4 + 2] = rgb[index * 3 + 2]
        }
        let data = Data(pixels) as CFData
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: data) else {
            return nil
        }
        return CGImage(
            width: columns,
            height: rows,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func scale(_ image: CGImage, longEdge: Int) -> CGImage? {
        let edge = max(image.width, image.height)
        guard edge > longEdge, edge > 0, longEdge > 0 else { return image }
        let factor = Double(longEdge) / Double(edge)
        let width = max(1, Int((Double(image.width) * factor).rounded(.down)))
        let height = max(1, Int((Double(image.height) * factor).rounded(.down)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let fitted = context.makeImage(), max(fitted.width, fitted.height) <= longEdge else {
            return nil
        }
        return fitted
    }

    private static func legal(columns: Int, rows: Int) -> Bool {
        columns > 0 && rows > 0 && columns <= maxEdge && rows <= maxEdge && rows <= maxPixels / columns
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        let bytes = data[start..<(start + 4)]
        var value: UInt32 = 0
        for (shift, byte) in bytes.enumerated() {
            value |= UInt32(byte) << (8 * shift)
        }
        return value
    }
}

private nonisolated struct Choice {
    var offset: UInt64
    var length: Int
    var pixels: Int
    var format: Int
    var columns: Int
    var rows: Int
    var rowSize: UInt32
    var seci: Bool

    var payloadOffset: UInt64 { seci ? offset + 28 : offset }
    var payloadCount: Int { seci ? length - 28 : length }
}

private nonisolated struct HuffNode {
    var zero = -1
    var one = -1
    var symbol = -1
}

private nonisolated struct BitCursor {
    var data: Data
    var byte: Int
    var bit = 8
    var current: UInt8 = 0

    mutating func symbol(_ nodes: [HuffNode]) -> Int? {
        var node = 0
        for _ in 0..<32 {
            if nodes[node].symbol >= 0 {
                return nodes[node].symbol
            }
            guard let bit = nextBit() else { return nil }
            let next = bit == 0 ? nodes[node].zero : nodes[node].one
            guard next >= 0 else { return nil }
            node = next
        }
        return nil
    }

    private mutating func nextBit() -> Int? {
        if bit == 8 {
            guard byte >= 0, byte < data.count else { return nil }
            current = data[data.startIndex + byte]
            byte += 1
            bit = 0
        }
        let value = Int((current >> (7 - bit)) & 1)
        bit += 1
        return value
    }
}

private nonisolated final class Reader {
    let handle: FileHandle
    let fileSize: UInt64
    let fileName: String
    var bytesRead = 0

    init(handle: FileHandle, fileSize: UInt64, fileName: String) {
        self.handle = handle
        self.fileSize = fileSize
        self.fileName = fileName
    }

    func bytes(at offset: UInt64, count: Int) throws -> Data? {
        guard count > 0, count <= X3FPreview.readBudget else { return nil }
        guard offset <= fileSize, UInt64(count) <= fileSize - offset else { return nil }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
            bytesRead += count
            return data
        } catch {
            throw X3FOpenError.noPreview(fileName)
        }
    }
}

nonisolated struct X3FFitted: @unchecked Sendable {
    var image: CGImage
    var byteCount: Int
    var bytesRead: Int
}

nonisolated struct X3FOpened: Sendable {
    var proxy: ProxyImage
    var decodeSupport: DecodeSupport
    /// Nil when the opened picture is the developed sensor image.
    var banner: String?
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
            return "Could not read a preview from \(name)."
        }
    }
}
