import XCTest
@testable import ZImage

@MainActor
final class SaveEditsTests: XCTestCase {
    func testSaveAsWritesFileRefWhileSaveEditsIsOff() throws {
        let original = Data("original-bytes".utf8)
        let bytes = try SaveEdits.fileRefBytes(
            log: HistoryLog(),
            original: original,
            pathHint: "/tmp/photo.jpg",
            bookmark: nil,
            uti: "public.jpeg",
            previewJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
        let document = try ZImgRaw.read(bytes)
        XCTAssertEqual(document.base.kind, .fileRef)
        XCTAssertNil(document.base.assetUID)
        XCTAssertFalse(document.sectionNames.contains("base-original"))
        XCTAssertFalse(SaveEdits.showsCommand(helperUp: false))
        XCTAssertFalse(SaveEdits.isEnabled(helperUp: false, assetUID: "keepuid"))
        XCTAssertFalse(SaveEdits.isEnabled(helperUp: true, assetUID: nil))
        XCTAssertFalse(EditorModel().helperUp)
    }

    func testSaveEditsRoundTripsTheCatalogRef() async throws {
        let log = HistoryLog()
        let bytes = try SaveEdits.catalogBytes(
            log: log,
            blake3: "abc",
            byteSize: 4,
            uti: "public.jpeg",
            assetUID: "keepuid",
            relativePathHint: "Photos/2020/2020-05-01/one.jpg",
            previewJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
        let document = try ZImgRaw.read(bytes)
        XCTAssertEqual(document.base.kind, .catalogRef)
        XCTAssertEqual(document.base.assetUID, "keepuid")
        XCTAssertFalse(document.sectionNames.contains("base-original"))
        XCTAssertTrue(SaveEdits.isEnabled(helperUp: true, assetUID: "keepuid"))

        let fake = EditStore()
        let client = HelperClient(credentials: HelperCredentials(host: "127.0.0.1", token: "token-value")) { request in
            fake.send(request)
        }
        try await client.putEdits(uid: "keepuid", body: bytes)
        let again = try await client.edits(uid: "keepuid")
        XCTAssertEqual(again, bytes)
        let stopped = HelperClient(credentials: HelperCredentials(host: "127.0.0.1")) { _ in
            throw HelperError.offline
        }
        do {
            try await stopped.putEdits(uid: "keepuid", body: bytes)
            XCTFail("saved while the helper was down")
        } catch HelperError.offline {
        }
    }

    func testCatalogMatchUsesTheLongestRelativePath() {
        let rows = [
            LibraryAsset(uid: "short", relPath: "one.jpg"),
            LibraryAsset(uid: "keepuid", relPath: "Photos/2020/2020-05-01/one.jpg"),
        ]
        let match = SaveEdits.matchingAsset(
            filePath: "/Volumes/BackupData/PhotoVideoAudio/Photos/2020/2020-05-01/one.jpg",
            rows: rows
        )
        XCTAssertEqual(match?.uid, "keepuid")
        XCTAssertNil(SaveEdits.matchingAsset(filePath: "/tmp/other.jpg", rows: rows))
    }
}

private final class EditStore: @unchecked Sendable {
    var edits: [String: Data] = [:]

    func send(_ request: URLRequest) -> HelperResponse {
        let path = request.url?.path ?? ""
        if request.httpMethod == "PUT", path == "/v1/edits/keepuid" {
            edits[path] = request.httpBody ?? Data()
            return HelperResponse(status: 204, body: Data())
        }
        if request.httpMethod == "GET", path == "/v1/edits/keepuid" {
            guard let body = edits[path] else {
                return HelperResponse(status: 404, body: Data())
            }
            return HelperResponse(status: 200, body: body)
        }
        return HelperResponse(status: 404, body: Data())
    }
}
