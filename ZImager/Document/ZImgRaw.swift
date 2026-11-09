import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ZImgKind: String, Codable, Equatable, Sendable {
    case fileRef
    case catalogRef
    case embedded
}

nonisolated struct ZImgBase: Codable, Equatable, Sendable {
    var kind: ZImgKind
    var blake3: String
    var byteSize: Int
    var uti: String
    var pathHint: String?
    var bookmarkBase64: String?
    var assetUID: String?
    var relativePathHint: String?

    init(
        kind: ZImgKind,
        blake3: String,
        byteSize: Int,
        uti: String,
        pathHint: String?,
        bookmarkBase64: String?,
        assetUID: String?,
        relativePathHint: String?
    ) {
        self.kind = kind
        self.blake3 = blake3
        self.byteSize = byteSize
        self.uti = uti
        self.pathHint = pathHint
        self.bookmarkBase64 = bookmarkBase64
        self.assetUID = assetUID
        self.relativePathHint = relativePathHint
    }

    private enum CodingKeys: String, CodingKey {
        case kind, blake3, byteSize, uti, pathHint, bookmarkBase64, assetUID, relativePathHint
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(blake3, forKey: .blake3)
        try container.encode(byteSize, forKey: .byteSize)
        try container.encode(uti, forKey: .uti)
        try container.encodeIfPresent(pathHint, forKey: .pathHint)
        try container.encodeIfPresent(bookmarkBase64, forKey: .bookmarkBase64)
        try container.encodeIfPresent(assetUID, forKey: .assetUID)
        try container.encodeIfPresent(relativePathHint, forKey: .relativePathHint)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ZImgKind.self, forKey: .kind)
        blake3 = try container.decode(String.self, forKey: .blake3)
        byteSize = try container.decode(Int.self, forKey: .byteSize)
        uti = try container.decode(String.self, forKey: .uti)
        pathHint = try container.decodeIfPresent(String.self, forKey: .pathHint)
        bookmarkBase64 = try container.decodeIfPresent(String.self, forKey: .bookmarkBase64)
        assetUID = try container.decodeIfPresent(String.self, forKey: .assetUID)
        relativePathHint = try container.decodeIfPresent(String.self, forKey: .relativePathHint)
    }
}

nonisolated struct ZImgRawDocument: Equatable, Sendable {
    var schemaVersion: Int
    var appVersion: String
    var base: ZImgBase
    var history: HistoryLog
    var previewJPEG: Data
    var masks: [Data]
    var embeddedOriginal: Data?
    var sectionNames: [String]
}

nonisolated struct FileRefResolution: Equatable {
    var applyLog: Bool
    var needsLocate: Bool
}

/// `.zimg` envelope. Magic, uncompressed JSON header, then section bytes.
/// Save and Save As call `bytesForSavePanel`, which writes `fileRef` and does not embed the original.
nonisolated enum ZImgRaw {
    /// Exported by ZImage.app. Finder sends `.zimg` here.
    static let contentTypeIdentifier = "com.Win32Forth.zimg"
    static let magic = Data([0x5A, 0x49, 0x4D, 0x47, 0x52, 0x41, 0x57, 0x01])
    static let appVersion = "1.0.0"
    static let previewLongEdge = 2048

    static func minimalFixtureDocument() -> ZImgRawDocument {
        catalogRefDocument(
            log: HistoryLog(),
            blake3: Blake3.hex(Data()),
            byteSize: 0,
            uti: "public.jpeg",
            assetUID: "00000000-0000-0000-0000-000000000001",
            relativePathHint: "Photos/1999/1999-01-01/event/file.jpg",
            previewJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
    }

    /// The save panel's bytes. `fileRef` only. The original is not a section.
    static func bytesForSavePanel(
        log: HistoryLog,
        original: Data,
        pathHint: String,
        bookmark: Data?,
        uti: String,
        previewJPEG: Data
    ) throws -> Data {
        try encode(fileRefDocument(
            log: log,
            original: original,
            pathHint: pathHint,
            bookmark: bookmark,
            uti: uti,
            previewJPEG: previewJPEG
        ))
    }

    static func fileRefDocument(
        log: HistoryLog,
        original: Data,
        pathHint: String,
        bookmark: Data?,
        uti: String,
        previewJPEG: Data
    ) -> ZImgRawDocument {
        ZImgRawDocument(
            schemaVersion: VersionMigratorChain.currentSchema,
            appVersion: appVersion,
            base: ZImgBase(
                kind: .fileRef,
                blake3: Blake3.hex(original),
                byteSize: original.count,
                uti: uti,
                pathHint: pathHint,
                bookmarkBase64: bookmark.map { $0.base64EncodedString() },
                assetUID: nil,
                relativePathHint: nil
            ),
            history: log,
            previewJPEG: previewJPEG,
            masks: maskBlobs(in: log),
            embeddedOriginal: nil,
            sectionNames: ["history", "preview", "masks"]
        )
    }

    static func catalogRefDocument(
        log: HistoryLog,
        blake3: String,
        byteSize: Int,
        uti: String,
        assetUID: String,
        relativePathHint: String,
        previewJPEG: Data
    ) -> ZImgRawDocument {
        ZImgRawDocument(
            schemaVersion: VersionMigratorChain.currentSchema,
            appVersion: appVersion,
            base: ZImgBase(
                kind: .catalogRef,
                blake3: blake3,
                byteSize: byteSize,
                uti: uti,
                pathHint: nil,
                bookmarkBase64: nil,
                assetUID: assetUID,
                relativePathHint: relativePathHint
            ),
            history: log,
            previewJPEG: previewJPEG,
            masks: maskBlobs(in: log),
            embeddedOriginal: nil,
            sectionNames: ["history", "preview", "masks"]
        )
    }

    static func embeddedDocument(
        log: HistoryLog,
        original: Data,
        uti: String,
        previewJPEG: Data
    ) -> ZImgRawDocument {
        ZImgRawDocument(
            schemaVersion: VersionMigratorChain.currentSchema,
            appVersion: appVersion,
            base: ZImgBase(
                kind: .embedded,
                blake3: Blake3.hex(original),
                byteSize: original.count,
                uti: uti,
                pathHint: nil,
                bookmarkBase64: nil,
                assetUID: nil,
                relativePathHint: nil
            ),
            history: log,
            previewJPEG: previewJPEG,
            masks: maskBlobs(in: log),
            embeddedOriginal: original,
            sectionNames: ["history", "preview", "masks", "base-original"]
        )
    }

    static func encode(_ document: ZImgRawDocument) throws -> Data {
        var current = document
        current.schemaVersion = VersionMigratorChain.currentSchema
        return try encodeExact(current)
    }

    static func encodeExact(_ document: ZImgRawDocument) throws -> Data {
        let historyBytes = try jsonEncoder().encode(document.history)
        let maskBytes = encodeMasks(document.masks)
        var payload = Data()
        var sections: [ZImgSectionInfo] = []
        func append(_ name: String, _ bytes: Data) {
            sections.append(ZImgSectionInfo(name: name, offset: payload.count, length: bytes.count, codec: "none"))
            payload.append(bytes)
        }
        append("history", historyBytes)
        append("preview", document.previewJPEG)
        append("masks", maskBytes)
        if document.base.kind == .embedded, let original = document.embeddedOriginal {
            append("base-original", original)
        }
        let header = ZImgHeader(
            envelope: 1,
            schemaVersion: document.schemaVersion,
            appVersion: document.appVersion,
            base: document.base,
            history: ZImgHistoryInfo(section: "history", cursor: document.history.cursor, depthCap: HistoryLog.depthCap),
            preview: ZImgPreviewInfo(section: "preview", longEdge: previewLongEdge, uti: "public.jpeg"),
            sections: sections
        )
        let headerBytes = try jsonEncoder().encode(header)
        var file = Data()
        file.append(magic)
        var length = UInt32(headerBytes.count).littleEndian
        withUnsafeBytes(of: &length) { file.append(contentsOf: $0) }
        file.append(headerBytes)
        file.append(payload)
        return file
    }

    static func read(
        _ data: Data,
        schema: Int = VersionMigratorChain.currentSchema,
        migrators: [any VersionMigrator] = []
    ) throws -> ZImgRawDocument {
        guard data.count >= 12, data.prefix(8) == magic else { throw ZImgError.badMagic }
        let headerLength = Int(u32(data, at: 8))
        guard headerLength >= 2, data.count >= 12 + headerLength else { throw ZImgError.truncated }
        let headerBytes = data.subdata(in: 12..<(12 + headerLength))
        let header = try JSONDecoder().decode(ZImgHeader.self, from: headerBytes)
        let payload = data.suffix(from: 12 + headerLength)
        func section(_ name: String) throws -> Data {
            guard let info = header.sections.first(where: { $0.name == name }) else { return Data() }
            let start = info.offset
            let end = info.offset + info.length
            guard start >= 0, end >= start, end <= payload.count else { throw ZImgError.truncated }
            return Data(payload[payload.startIndex + start..<payload.startIndex + end])
        }
        let history = try JSONDecoder().decode(HistoryLog.self, from: section("history"))
        let preview = try section("preview")
        let masks = decodeMasks(try section("masks"))
        let embedded = header.base.kind == .embedded ? try section("base-original") : nil
        let parsed = ZImgRawDocument(
            schemaVersion: header.schemaVersion,
            appVersion: header.appVersion,
            base: header.base,
            history: history,
            previewJPEG: preview,
            masks: masks,
            embeddedOriginal: embedded,
            sectionNames: header.sections.map(\.name)
        )
        return try VersionMigratorChain.migrate(parsed, to: schema, migrators: migrators)
    }

    static func read(
        from url: URL,
        schema: Int = VersionMigratorChain.currentSchema,
        migrators: [any VersionMigrator] = []
    ) throws -> ZImgRawDocument {
        try read(Data(contentsOf: url), schema: schema, migrators: migrators)
    }

    static func resolveFileRef(_ document: ZImgRawDocument, bytes: Data?) -> FileRefResolution {
        guard document.base.kind == .fileRef else {
            return FileRefResolution(applyLog: false, needsLocate: false)
        }
        guard let bytes else {
            return FileRefResolution(applyLog: false, needsLocate: true)
        }
        let matches = Blake3.hex(bytes) == document.base.blake3 && bytes.count == document.base.byteSize
        return FileRefResolution(applyLog: matches, needsLocate: false)
    }

    static func jpegPreview(from image: CGImage, maxLongEdge: Int = previewLongEdge) -> Data? {
        let long = max(image.width, image.height)
        let scale = long > maxLongEdge && long > 0 ? Double(maxLongEdge) / Double(long) : 1
        let width = max(1, Int((Double(image.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(image.height) * scale).rounded(.down)))
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
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func maskBlobs(in log: HistoryLog) -> [Data] {
        log.commands.compactMap { command in
            if case .addInpaint(let operation) = command, !operation.maskPNG.isEmpty {
                return operation.maskPNG
            }
            return nil
        }
    }

    private static func encodeMasks(_ masks: [Data]) -> Data {
        var bytes = Data()
        var count = UInt32(masks.count).littleEndian
        withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
        for mask in masks {
            var length = UInt32(mask.count).littleEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(mask)
        }
        return bytes
    }

    private static func u32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start])
            | (UInt32(data[start + 1]) << 8)
            | (UInt32(data[start + 2]) << 16)
            | (UInt32(data[start + 3]) << 24)
    }

    private static func decodeMasks(_ data: Data) -> [Data] {
        guard data.count >= 4 else { return [] }
        let count = Int(u32(data, at: 0))
        var masks: [Data] = []
        var offset = 4
        for _ in 0..<count {
            guard offset + 4 <= data.count else { break }
            let length = Int(u32(data, at: offset))
            offset += 4
            guard length >= 0, offset + length <= data.count else { break }
            masks.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return masks
    }

    private static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private nonisolated struct ZImgSectionInfo: Codable {
    var name: String
    var offset: Int
    var length: Int
    var codec: String
}

private nonisolated struct ZImgHistoryInfo: Codable {
    var section: String
    var cursor: Int
    var depthCap: Int
}

private nonisolated struct ZImgPreviewInfo: Codable {
    var section: String
    var longEdge: Int
    var uti: String
}

private nonisolated struct ZImgHeader: Codable {
    var envelope: Int
    var schemaVersion: Int
    var appVersion: String
    var base: ZImgBase
    var history: ZImgHistoryInfo
    var preview: ZImgPreviewInfo
    var sections: [ZImgSectionInfo]
}
