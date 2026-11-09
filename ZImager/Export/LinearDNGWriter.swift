import CoreGraphics
import CoreImage
import Foundation

/// Uncompressed 16-bit linear RGB DNG. PhotometricInterpretation 34892.
/// ImageIO on this Mac does not decode 34892, so IFD 0 is a 16-bit RGB view of the same strip
/// and the LinearRaw directory is the SubIFD. Both directories share one pixel buffer.
/// This product includes DNG technology under license by Adobe.
nonisolated enum LinearDNGWriter {
    static let adobeNotice = "This product includes DNG technology under license by Adobe."

    /// Linear Display P3 to XYZ D65, row major. Same coefficients as `LinearDisplayP3.xyz`.
    static let colorMatrix: [[Double]] = [
        [0.4865709486482162, 0.26566769316909306, 0.1982172852343625],
        [0.2289745640697488, 0.6917385218365064, 0.079286914093745],
        [0, 0.04511338185890264, 1.043944368900976],
    ]

    static func write(image: CIImage, to url: URL, context: CIContext) throws {
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width >= 1, height >= 1, extent.width.isFinite, extent.height.isFinite else {
            throw ExportError.cannotEncode("DNG")
        }
        let samples = try linearSamples(image, extent: extent, width: width, height: height, context: context)
        let file = try tiff(width: width, height: height, samples: samples)
        try file.write(to: url, options: .atomic)
    }

    /// TIFF row 0 is the top. `CIContext.render` stores the lower-left pixel first, so each tile is flipped.
    private static func linearSamples(
        _ image: CIImage,
        extent: CGRect,
        width: Int,
        height: Int,
        context: CIContext
    ) throws -> Data {
        let tile = 512
        var output = Data(count: width * height * 6)
        var floats = [Float](repeating: 0, count: tile * tile * 4)
        var y = 0
        while y < height {
            let rows = min(tile, height - y)
            var x = 0
            while x < width {
                let cols = min(tile, width - x)
                let ciY = extent.minY + CGFloat(height - (y + rows))
                let rect = CGRect(x: extent.minX + CGFloat(x), y: ciY, width: CGFloat(cols), height: CGFloat(rows))
                floats.withUnsafeMutableBytes { raw in
                    context.render(
                        image,
                        toBitmap: raw.baseAddress!,
                        rowBytes: cols * MemoryLayout<Float>.size * 4,
                        bounds: rect,
                        format: .RGBAf,
                        colorSpace: TonePipeline.workingColorSpace
                    )
                }
                for row in 0..<rows {
                    let sourceRow = rows - 1 - row
                    let destRow = y + row
                    for col in 0..<cols {
                        let source = (sourceRow * cols + col) * 4
                        let alpha = floats[source + 3]
                        let scale: Float = alpha > 0.0001 ? (1 / alpha) : 0
                        let dest = (destRow * width + (x + col)) * 6
                        writeU16(u16(floats[source] * scale), into: &output, at: dest)
                        writeU16(u16(floats[source + 1] * scale), into: &output, at: dest + 2)
                        writeU16(u16(floats[source + 2] * scale), into: &output, at: dest + 4)
                    }
                }
                x += cols
            }
            y += rows
        }
        return output
    }

    private static func u16(_ value: Float) -> UInt16 {
        guard value.isFinite else { return 0 }
        let clamped = min(1, max(0, value))
        return UInt16(min(65535, max(0, (Double(clamped) * 65535).rounded())))
    }

    private static func writeU16(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private static func tiff(width: Int, height: Int, samples: Data) throws -> Data {
        let model = Array("ZImage".utf8) + [0]
        let ifd0Count = 19
        let subCount = 14
        let ifd0Bytes = 2 + ifd0Count * 12 + 4
        let subBytes = 2 + subCount * 12 + 4
        let extraStart = 8 + ifd0Bytes + subBytes
        let subAt = 8 + ifd0Bytes
        var extra = Data()

        func align2() {
            if extra.count % 2 != 0 { extra.append(0) }
        }

        let bitsAt = extraStart + extra.count
        extra.append(contentsOf: le16(16) + le16(16) + le16(16))
        align2()
        let xResAt = extraStart + extra.count
        extra.append(contentsOf: le32(72) + le32(1))
        let yResAt = extraStart + extra.count
        extra.append(contentsOf: le32(72) + le32(1))
        let modelAt = extraStart + extra.count
        extra.append(contentsOf: model)
        align2()
        let matrixAt = extraStart + extra.count
        for row in colorMatrix {
            for value in row {
                let (numerator, denominator) = srational(value)
                extra.append(contentsOf: lei32(numerator) + lei32(denominator))
            }
        }
        let neutralAt = extraStart + extra.count
        for _ in 0..<3 {
            extra.append(contentsOf: le32(1) + le32(1))
        }
        align2()
        let pixelsAt = extraStart + extra.count
        guard samples.count == width * height * 6 else {
            throw ExportError.cannotEncode("DNG")
        }

        var file = Data()
        file.append(contentsOf: [0x49, 0x49])
        file.append(contentsOf: le16(42))
        file.append(contentsOf: le32(UInt32(8)))
        file.append(contentsOf: le16(UInt16(ifd0Count)))

        func entry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) {
            file.append(contentsOf: le16(tag) + le16(type) + le32(count) + le32(value))
        }

        // IFD 0 is the view ImageIO can open. NewSubfileType 1 marks it as the preview.
        entry(tag: 254, type: 4, count: 1, value: 1)
        entry(tag: 256, type: 4, count: 1, value: UInt32(width))
        entry(tag: 257, type: 4, count: 1, value: UInt32(height))
        entry(tag: 258, type: 3, count: 3, value: UInt32(bitsAt))
        entry(tag: 259, type: 3, count: 1, value: 1)
        entry(tag: 262, type: 3, count: 1, value: 2)
        entry(tag: 273, type: 4, count: 1, value: UInt32(pixelsAt))
        entry(tag: 274, type: 3, count: 1, value: 1)
        entry(tag: 277, type: 3, count: 1, value: 3)
        entry(tag: 278, type: 4, count: 1, value: UInt32(height))
        entry(tag: 279, type: 4, count: 1, value: UInt32(samples.count))
        entry(tag: 282, type: 5, count: 1, value: UInt32(xResAt))
        entry(tag: 283, type: 5, count: 1, value: UInt32(yResAt))
        entry(tag: 284, type: 3, count: 1, value: 1)
        entry(tag: 296, type: 3, count: 1, value: 2)
        entry(tag: 330, type: 4, count: 1, value: UInt32(subAt))
        entry(tag: 50706, type: 1, count: 4, value: 1 | (4 << 8))
        entry(tag: 50707, type: 1, count: 4, value: 1 | (1 << 8))
        entry(tag: 50708, type: 2, count: UInt32(model.count), value: UInt32(modelAt))
        file.append(contentsOf: le32(0))

        file.append(contentsOf: le16(UInt16(subCount)))
        entry(tag: 254, type: 4, count: 1, value: 0)
        entry(tag: 256, type: 4, count: 1, value: UInt32(width))
        entry(tag: 257, type: 4, count: 1, value: UInt32(height))
        entry(tag: 258, type: 3, count: 3, value: UInt32(bitsAt))
        entry(tag: 259, type: 3, count: 1, value: 1)
        entry(tag: 262, type: 3, count: 1, value: 34892)
        entry(tag: 273, type: 4, count: 1, value: UInt32(pixelsAt))
        entry(tag: 277, type: 3, count: 1, value: 3)
        entry(tag: 278, type: 4, count: 1, value: UInt32(height))
        entry(tag: 279, type: 4, count: 1, value: UInt32(samples.count))
        entry(tag: 50708, type: 2, count: UInt32(model.count), value: UInt32(modelAt))
        entry(tag: 50721, type: 10, count: 9, value: UInt32(matrixAt))
        entry(tag: 50728, type: 5, count: 3, value: UInt32(neutralAt))
        entry(tag: 50778, type: 3, count: 1, value: 21)
        file.append(contentsOf: le32(0))
        file.append(extra)
        file.append(samples)
        return file
    }

    private static func srational(_ value: Double) -> (Int32, Int32) {
        let denominator: Int32 = 1_000_000_000
        let numerator = Int32(clamping: Int((value * Double(denominator)).rounded()))
        return (numerator, denominator)
    }

    private static func le16(_ value: UInt16) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 2)
    }

    private static func le32(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 4)
    }

    private static func lei32(_ value: Int32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 4)
    }
}
