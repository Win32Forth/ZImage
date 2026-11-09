import XCTest
@testable import ZImager

private struct StepToV2: VersionMigrator {
    var fromSchema: Int { 1 }
    var toSchema: Int { 2 }
    func migrate(_ document: ZImgRawDocument) throws -> ZImgRawDocument {
        var copy = document
        copy.schemaVersion = 2
        copy.appVersion = "migrated"
        return copy
    }
}

final class ZImgRawTests: XCTestCase {
    func testBlake3MatchesTheEmptyAndABCVectors() {
        XCTAssertEqual(
            Blake3.hex(Data()),
            "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
        )
        XCTAssertEqual(
            Blake3.hex(Data("abc".utf8)),
            "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
        )
        let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(
            Blake3.hex(million),
            "616f575a1b58d4c9797d4217b9730ae5e6eb319d76edef6549b46f4efe31ff8b"
        )
    }

    func testFileRefRoundTripUndoesSixAndRedoesTwo() throws {
        var log = HistoryLog()
        for index in 1...8 {
            var tone = ToneState.identity
            tone.exposureEV = Double(index) / 10
            log.commit(.setTone(tone, label: "Exposure"))
        }
        XCTAssertEqual(log.cursor, 8)
        let marker = Data("ZIMG-ORIGINAL-MARKER-9f3a7c1e".utf8)
        let preview = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let bytes = try ZImgRaw.bytesForSavePanel(
            log: log,
            original: marker,
            pathHint: "/tmp/photo.jpg",
            bookmark: Data("bookmark".utf8),
            uti: "public.jpeg",
            previewJPEG: preview
        )
        XCTAssertNil(bytes.range(of: marker))
        let loaded = try ZImgRaw.read(bytes)
        XCTAssertEqual(loaded.base.kind, .fileRef)
        XCTAssertEqual(loaded.base.blake3, Blake3.hex(marker))
        XCTAssertEqual(loaded.base.byteSize, marker.count)
        XCTAssertEqual(loaded.history.cursor, 8)
        XCTAssertFalse(loaded.sectionNames.contains("base-original"))
        XCTAssertEqual(ZImgRaw.resolveFileRef(loaded, bytes: marker).applyLog, true)
        XCTAssertEqual(ZImgRaw.resolveFileRef(loaded, bytes: Data("other".utf8)).applyLog, false)
        XCTAssertEqual(ZImgRaw.resolveFileRef(loaded, bytes: nil).needsLocate, true)

        var replay = loaded.history
        for _ in 0..<6 { replay.undo() }
        for _ in 0..<2 { replay.redo() }
        var expected = log
        for _ in 0..<6 { expected.undo() }
        for _ in 0..<2 { expected.redo() }
        XCTAssertEqual(replay.state, expected.state)
        XCTAssertEqual(replay.state.tone.exposureEV, 0.4, accuracy: 0.0001)
        XCTAssertEqual(VersionMigratorChain.currentSchema, 1)
    }

    func testCatalogRefOmitsTheOriginalAndEmbeddedKeepsIt() throws {
        let preview = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let catalog = ZImgRaw.catalogRefDocument(
            log: HistoryLog(),
            blake3: Blake3.hex(Data()),
            byteSize: 0,
            uti: "public.jpeg",
            assetUID: "asset",
            relativePathHint: "Photos/1999/file.jpg",
            previewJPEG: preview
        )
        let catalogBytes = try ZImgRaw.encode(catalog)
        let catalogLoaded = try ZImgRaw.read(catalogBytes)
        XCTAssertEqual(catalogLoaded.base.kind, .catalogRef)
        XCTAssertFalse(catalogLoaded.sectionNames.contains("base-original"))

        let original = Data("embedded-original-bytes".utf8)
        let embedded = ZImgRaw.embeddedDocument(log: HistoryLog(), original: original, uti: "public.jpeg", previewJPEG: preview)
        let embeddedBytes = try ZImgRaw.encode(embedded)
        let embeddedLoaded = try ZImgRaw.read(embeddedBytes)
        XCTAssertEqual(embeddedLoaded.sectionNames, ["history", "preview", "masks", "base-original"])
        XCTAssertEqual(embeddedLoaded.embeddedOriginal, original)
    }

    func testV1FixtureMigratesAndSchema999LeavesTheBytes() throws {
        let fixture = try fixtureURL()
        let fixtureBytes = try Data(contentsOf: fixture)
        let loaded = try ZImgRaw.read(fixtureBytes, schema: 2, migrators: [StepToV2()])
        XCTAssertEqual(loaded.schemaVersion, 2)
        XCTAssertEqual(loaded.appVersion, "migrated")
        XCTAssertEqual(VersionMigratorChain.currentSchema, 1)
        let unchanged = try ZImgRaw.read(fixtureBytes)
        XCTAssertEqual(unchanged.schemaVersion, 1)

        var newer = ZImgRaw.minimalFixtureDocument()
        newer.schemaVersion = 999
        let planted = try ZImgRaw.encodeExact(newer)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schema-999.zimg")
        try planted.write(to: url)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try ZImgRaw.read(from: url)) { error in
            XCTAssertEqual(error as? ZImgError, .schemaTooNew(999))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: ZImgRawTests.self)
        if let url = bundle.url(forResource: "schema-v1-minimal", withExtension: "zimg", subdirectory: "Fixtures") {
            return url
        }
        if let url = bundle.url(forResource: "schema-v1-minimal", withExtension: "zimg") {
            return url
        }
        XCTFail("Missing schema-v1-minimal.zimg")
        throw ZImgError.truncated
    }
}
