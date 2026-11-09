internal import CImageCodecs
import Foundation

/// libjxl 0.12.0, linked with highway 1.4.0, brotli 1.2, and little-cms2 2.19. BSD-3-Clause.
/// Lossy distance is 1.0. Lossless uses `JxlEncoderSetFrameLossless`. Effort is 7 (squirrel).
nonisolated enum JPEGXLWriter {
    static let libraryVersion = "0.12.0"
    static let effort: Int64 = 7
    static let lossyDistance: Float = 1

    static func encodeRGB(_ rgb: Data, width: Int, height: Int, lossless: Bool) throws -> Data {
        guard width > 0, height > 0, rgb.count == width * height * 3 else {
            throw ExportError.cannotEncode("JPEG XL")
        }
        guard let encoder = JxlEncoderCreate(nil) else {
            throw ExportError.cannotEncode("JPEG XL")
        }
        defer { JxlEncoderDestroy(encoder) }

        var info = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&info)
        info.xsize = UInt32(width)
        info.ysize = UInt32(height)
        info.bits_per_sample = 8
        info.exponent_bits_per_sample = 0
        info.num_color_channels = 3
        info.alpha_bits = 0
        info.uses_original_profile = lossless ? 1 : 0
        guard ZImageEncoderSucceeded(JxlEncoderSetBasicInfo(encoder, &info)) != 0 else {
            throw ExportError.cannotEncode("JPEG XL")
        }

        var color = JxlColorEncoding()
        JxlColorEncodingSetToSRGB(&color, 0)
        guard ZImageEncoderSucceeded(JxlEncoderSetColorEncoding(encoder, &color)) != 0 else {
            throw ExportError.cannotEncode("JPEG XL")
        }

        guard let frame = JxlEncoderFrameSettingsCreate(encoder, nil) else {
            throw ExportError.cannotEncode("JPEG XL")
        }
        guard ZImageEncoderSucceeded(
            JxlEncoderFrameSettingsSetOption(frame, JXL_ENC_FRAME_SETTING_EFFORT, effort)
        ) != 0 else {
            throw ExportError.cannotEncode("JPEG XL")
        }
        if lossless {
            guard ZImageEncoderSucceeded(JxlEncoderSetFrameLossless(frame, 1)) != 0 else {
                throw ExportError.cannotEncode("JPEG XL")
            }
        } else {
            guard ZImageEncoderSucceeded(JxlEncoderSetFrameDistance(frame, lossyDistance)) != 0 else {
                throw ExportError.cannotEncode("JPEG XL")
            }
        }

        var format = JxlPixelFormat(
            num_channels: 3,
            data_type: JXL_TYPE_UINT8,
            endianness: JXL_NATIVE_ENDIAN,
            align: 0
        )
        let added = rgb.withUnsafeBytes { raw -> Int32 in
            let base = raw.baseAddress
            return ZImageEncoderSucceeded(
                JxlEncoderAddImageFrame(frame, &format, base, raw.count)
            )
        }
        guard added != 0 else {
            throw ExportError.cannotEncode("JPEG XL")
        }
        JxlEncoderCloseInput(encoder)

        var encoded = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let step = chunk.withUnsafeMutableBytes { raw -> Int32 in
                var written = 0
                let code = ZImageEncoderPump(
                    encoder,
                    raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    raw.count,
                    &written
                )
                if written > 0, let base = raw.baseAddress {
                    encoded.append(base.assumingMemoryBound(to: UInt8.self), count: written)
                }
                return code
            }
            if step == 0 { break }
            if step != 1 {
                throw ExportError.cannotEncode("JPEG XL")
            }
        }
        guard !encoded.isEmpty else {
            throw ExportError.cannotEncode("JPEG XL")
        }
        return encoded
    }

    static func decodeRGB(_ data: Data) throws -> (width: Int, height: Int, rgb: Data) {
        guard let decoder = JxlDecoderCreate(nil) else {
            throw ExportError.cannotEncode("JPEG XL")
        }
        defer { JxlDecoderDestroy(decoder) }
        guard ZImageDecoderSucceeded(JxlDecoderSubscribeEvents(decoder, ZImageDecoderEvents())) != 0 else {
            throw ExportError.cannotEncode("JPEG XL")
        }

        var width = 0
        var height = 0
        var storage: UnsafeMutablePointer<UInt8>?
        var storageCount = 0
        defer { storage?.deallocate() }

        let decoded: Data = try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw ExportError.cannotEncode("JPEG XL")
            }
            guard ZImageDecoderSucceeded(JxlDecoderSetInput(decoder, base, raw.count)) != 0 else {
                throw ExportError.cannotEncode("JPEG XL")
            }
            JxlDecoderCloseInput(decoder)

            var sawImage = false
            for _ in 0..<64 {
                let status = JxlDecoderProcessInput(decoder)
                if ZImageDecoderFailed(status) != 0 {
                    throw ExportError.cannotEncode("JPEG XL")
                }
                if ZImageDecoderHasBasicInfo(status) != 0 {
                    var info = JxlBasicInfo()
                    guard ZImageDecoderSucceeded(JxlDecoderGetBasicInfo(decoder, &info)) != 0 else {
                        throw ExportError.cannotEncode("JPEG XL")
                    }
                    width = Int(info.xsize)
                    height = Int(info.ysize)
                } else if ZImageDecoderNeedsImage(status) != 0 {
                    var format = JxlPixelFormat(
                        num_channels: 3,
                        data_type: JXL_TYPE_UINT8,
                        endianness: JXL_NATIVE_ENDIAN,
                        align: 0
                    )
                    var size: Int = 0
                    guard ZImageDecoderSucceeded(JxlDecoderImageOutBufferSize(decoder, &format, &size)) != 0,
                          size > 0 else {
                        throw ExportError.cannotEncode("JPEG XL")
                    }
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                    storage?.deallocate()
                    storage = buffer
                    storageCount = size
                    guard ZImageDecoderSucceeded(
                        JxlDecoderSetImageOutBuffer(decoder, &format, buffer, size)
                    ) != 0 else {
                        throw ExportError.cannotEncode("JPEG XL")
                    }
                } else if ZImageDecoderHasFullImage(status) != 0 {
                    sawImage = true
                } else if ZImageDecoderSucceeded(status) != 0 {
                    break
                }
            }
            guard sawImage, let storage, width > 0, height > 0 else {
                throw ExportError.cannotEncode("JPEG XL")
            }
            return Data(bytes: storage, count: min(storageCount, width * height * 3))
        }
        return (width, height, decoded)
    }
}
