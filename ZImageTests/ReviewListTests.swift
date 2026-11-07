import ImageIO
import XCTest
@testable import ZImage

@MainActor
final class ReviewListTests: XCTestCase {
    func testNilConfidenceStaysOutOfThePark() {
        let missing = LibraryAsset(uid: "bare", relPath: "Photos/_Review/Undated/ab/a.jpg", captureConfidence: nil)
        let low = LibraryAsset(uid: "low", relPath: "Photos/old/a.jpg", captureConfidence: 0.4)
        let kept = LibraryAsset(uid: "kept", relPath: "Photos/2020/a.jpg", captureConfidence: 0.95)
        let parked = LibraryAsset(uid: "parked", relPath: "Photos/_Review/Undated/ab/b.jpg", captureConfidence: 0.95)
        XCTAssertFalse(ReviewPark.contains(missing))
        XCTAssertTrue(ReviewPark.contains(low))
        XCTAssertFalse(ReviewPark.contains(kept))
        XCTAssertTrue(ReviewPark.contains(parked))
        XCTAssertEqual(LibrarySidebar.items, ["Photos", "Videos", "Review", "Duplicates"])
        XCTAssertFalse(LibrarySidebar.items.contains("_Duplicates"))
    }

    func testReviewFactsNameTheCatalogAndAClickLoadsThePreview() async throws {
        let asset = LibraryAsset(
            uid: "park",
            relPath: "Photos/_Review/Undated/e0/IMG_6462.HEIC",
            ext: "heic",
            mediaClass: "image",
            phase: "parked",
            thumbRel: ".zimage/cache/thumbs/e0/park.jpg",
            captureConfidence: 0,
            captureTime: nil,
            captureSource: nil
        )
        XCTAssertEqual(ReviewCatalogFacts.lines(for: asset), [
            "Photos/_Review/Undated/e0/IMG_6462.HEIC",
            "No date is stored in the catalog.",
            "No capture source is stored.",
            "Catalog confidence 0.00",
            "image heic",
            "Phase parked",
        ])
        XCTAssertEqual(ReviewCatalogFacts.editableDate("2025-01-01T09:50:17Z"), "2025-01-01")
        XCTAssertEqual(ReviewCatalogFacts.editableDate("1964"), "1964")
        XCTAssertEqual(ReviewCatalogFacts.editableDate(nil), "")

        let page = Data("""
        {"rows":[{"uid":"park","relPath":"Photos/_Review/Undated/e0/IMG_6462.HEIC","ext":"heic","mediaClass":"image","thumbRel":".zimage/cache/thumbs/e0/park.jpg","phase":"parked","captureConfidence":0}],"nextCursor":""}
        """.utf8)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let recorder = RequestRecorder()
        recorder.enqueue(HelperResponse(status: 200, body: page))
        recorder.enqueue(HelperResponse(status: 200, body: jpeg))
        let browser = LibraryBrowser(
            client: helper(recorder),
            libraryRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            openFile: { _, _ in }
        )
        await browser.loadReview()
        XCTAssertEqual(browser.thumbnailRequestCount, 0)
        await browser.ensurePreview(for: "park")
        let cell = try XCTUnwrap(browser.cells["park"])
        XCTAssertEqual(cell.imageData, jpeg)
        XCTAssertEqual(cell.thumbnailURL?.path, "/v1/assets/park/thumbnail")
        XCTAssertEqual(browser.thumbnailRequestCount, 0)
        XCTAssertEqual(recorder.requests.map(\.url?.path), ["/v1/assets", "/v1/assets/park/thumbnail"])
    }

    func testMovieHeaderReadsCreationDurationSizeAndCodec() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-movie-\(UUID().uuidString).mp4")
        try movieFixture().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = MovieHeaderFacts.read(url)
        XCTAssertEqual(facts.lines, [
            "Container created 2010-07-17 14:21:17 UTC",
            "Duration 5.6 s",
            "1280 × 720",
            "Video codec avc1",
            "Audio codec mp4a",
        ])
    }

    /// Seconds from 1904-01-01 UTC to 2010-07-17 14:21:17 UTC, timescale 90000, duration 5.6 s.
    private func movieFixture() -> Data {
        let created = Data([0xC8, 0x67, 0x6C, 0xDD])
        var mvhd = Data(count: 4)
        mvhd.append(created)
        mvhd.append(created)
        mvhd.append(contentsOf: [0x00, 0x01, 0x5F, 0x90])
        mvhd.append(contentsOf: [0x00, 0x07, 0xB0, 0xC0])
        var tkhd = Data(count: 76)
        tkhd.append(contentsOf: [0x05, 0x00, 0x00, 0x00])
        tkhd.append(contentsOf: [0x02, 0xD0, 0x00, 0x00])
        let vide = Data("vide".utf8)
        var hdlrVideo = Data(count: 8)
        hdlrVideo.append(vide)
        hdlrVideo.append(Data(count: 12))
        var stsdVideo = Data(count: 4)
        stsdVideo.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x10])
        stsdVideo.append(Data("avc1".utf8))
        let sound = Data("soun".utf8)
        var hdlrAudio = Data(count: 8)
        hdlrAudio.append(sound)
        hdlrAudio.append(Data(count: 12))
        var stsdAudio = Data(count: 4)
        stsdAudio.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x10])
        stsdAudio.append(Data("mp4a".utf8))
        let videoTrack = box("trak", box("tkhd", tkhd) + box("mdia", box("hdlr", hdlrVideo) + box("minf", box("stbl", box("stsd", stsdVideo)))))
        let audioTrack = box("trak", box("mdia", box("hdlr", hdlrAudio) + box("minf", box("stbl", box("stsd", stsdAudio)))))
        return box("moov", box("mvhd", mvhd) + videoTrack + audioTrack)
    }

    private func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        var size = UInt32(8 + payload.count).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    func testReviewLoadLeavesThePhotoRows() async throws {
        let photos = Data("""
        {"rows":[{"uid":"photo","relPath":"Photos/a.jpg","ext":"jpg","mediaClass":"image","captureConfidence":0.95}],"nextCursor":""}
        """.utf8)
        let review = Data("""
        {"rows":[{"uid":"park","relPath":"Photos/old/b.jpg","ext":"jpg","mediaClass":"image","captureConfidence":0.4}],"nextCursor":""}
        """.utf8)
        let recorder = RequestRecorder()
        recorder.enqueue(HelperResponse(status: 200, body: photos))
        recorder.enqueue(HelperResponse(status: 200, body: review))
        let browser = LibraryBrowser(
            client: helper(recorder),
            libraryRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            openFile: { _, _ in }
        )
        await browser.reload()
        await browser.loadReview()
        XCTAssertEqual(browser.rows.map(\.uid), ["photo"])
        XCTAssertEqual(browser.reviewRows.map(\.uid), ["park"])
        XCTAssertEqual(recorder.requests.map(\.url?.path), ["/v1/assets", "/v1/assets"])
        XCTAssertTrue(recorder.requests[1].url?.query?.contains("review=1") == true)
    }

    func testTypedDatePostsJSONAndShowsConfidenceOne() async throws {
        let page = Data("""
        {"rows":[{"uid":"park","relPath":"Photos/old/b.jpg","ext":"jpg","mediaClass":"image","captureConfidence":0.4}],"nextCursor":""}
        """.utf8)
        let saved = Data("""
        {"uid":"park","relPath":"Photos/old/b.jpg","ext":"jpg","mediaClass":"image","captureConfidence":1,"captureSource":"user","captureTime":"1964","isKeeper":false,"pinned":false}
        """.utf8)
        let recorder = RequestRecorder()
        recorder.enqueue(HelperResponse(status: 200, body: page))
        recorder.enqueue(HelperResponse(status: 200, body: saved))
        let browser = LibraryBrowser(
            client: helper(recorder),
            libraryRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            openFile: { _, _ in }
        )
        await browser.loadReview()
        browser.selectedUID = "park"
        await browser.setCaptureDate("1964")
        let request = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/assets/park/date")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"captureTime\":\"1964\""))
        XCTAssertFalse(text.contains("isKeeper"))
        XCTAssertEqual(LibraryItemMenu.captureRequest("2010-07-17"), "2010-07-17T00:00:00Z")
        XCTAssertEqual(LibraryItemMenu.captureRequest("1964"), "1964")
        XCTAssertNil(LibraryItemMenu.captureRequest("2010-02-31"))
        XCTAssertEqual(browser.notice, "Confidence 1.0")
        XCTAssertEqual(browser.reviewRows.first?.captureSource, "user")
        XCTAssertEqual(browser.rows.count, 0)

        recorder.enqueue(HelperResponse(status: 204, body: Data()))
        try await browserClient(recorder).claim(pairingToken: "pair-token")
        let claim = try XCTUnwrap(recorder.requests.last)
        XCTAssertNil(claim.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(String(decoding: claim.httpBody ?? Data(), as: UTF8.self), "pair-token")
    }

    func testDifferenceHashAndDetailBodies() throws {
        let brightLeft = try XCTUnwrap(MacCheckpoint.image(width: 9, height: 8) { x, _ in
            UInt8(255 - x * 20)
        })
        XCTAssertEqual(MacCheckpoint.differenceHash(brightLeft), UInt64.max)

        let sharp = try XCTUnwrap(MacCheckpoint.image(width: 400, height: 400) { x, y in
            ((x / 2) + (y / 2)) % 2 == 0 ? 255 : 0
        })
        let softPixels = boxBlur(checker: 400, radius: 8)
        let soft = try XCTUnwrap(MacCheckpoint.image(width: 2000, height: 2000) { x, y in
            softPixels[(y * 400 / 2000) * 400 + (x * 400 / 2000)]
        })
        let sharpScore = MacCheckpoint.detailScore(sharp)
        let softScore = MacCheckpoint.detailScore(soft)
        XCTAssertGreaterThan(sharpScore, softScore)

        let facts = MacCheckpoint.factsBody(
            dhash: UInt64.max,
            width: 9,
            height: 8,
            thumbnail: Data([1, 2, 3, 4]),
            captureTime: "2020-05-01T12:00:00Z"
        )
        let factsText = String(decoding: facts, as: UTF8.self)
        XCTAssertTrue(factsText.contains("\"dhash\":\"ffffffffffffffff\""))
        XCTAssertFalse(factsText.contains("isKeeper"))
        XCTAssertFalse(factsText.contains("captureConfidence"))
        let detail = MacCheckpoint.detailBody(score: sharpScore, nativePixels: 400 * 400, width: 400, height: 400, source: "mac")
        let detailText = String(decoding: detail, as: UTF8.self)
        XCTAssertTrue(detailText.contains("\"detailSource\":\"mac\""))
        XCTAssertFalse(detailText.contains("isKeeper"))
        XCTAssertFalse(detailText.contains("captureConfidence"))
        XCTAssertFalse(detailText.contains("\"captureConfidence\":1"))
    }

    func testCheckpointIgnoresAMissingRoute() async throws {
        let page = Data("""
        {"rows":[
          {"uid":"big","relPath":"Photos/big.jpg","ext":"jpg","mediaClass":"image","detailSource":"needs_mac","decodeSupport":"needs_mac"},
          {"uid":"ok","relPath":"Photos/ok.jpg","ext":"jpg","mediaClass":"image","phase":"thumbed"}
        ],"nextCursor":""}
        """.utf8)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("Photos/big.jpg")
        try writeTinyJPEG(to: photo)
        let recorder = RequestRecorder()
        recorder.enqueue(HelperResponse(status: 200, body: page))
        recorder.enqueue(HelperResponse(status: 404, body: Data(#"{"error":"not_found"}"#.utf8)))
        let browser = LibraryBrowser(
            client: helper(recorder),
            libraryRoot: root,
            openFile: { _, _ in }
        )
        await browser.reload()
        let consumed = await browser.checkpointOne()
        XCTAssertTrue(consumed)
        XCTAssertEqual(browser.rows.map(\.uid), ["big", "ok"])
        let facts = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(facts.httpMethod, "PUT")
        XCTAssertEqual(facts.url?.path, "/v1/assets/big/facts")
        XCTAssertEqual(facts.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let encoded = String(decoding: facts.httpBody ?? Data(), as: UTF8.self)
        XCTAssertFalse(encoded.contains("isKeeper"))
        XCTAssertFalse(encoded.contains("captureConfidence"))
        let again = await browser.checkpointOne()
        XCTAssertFalse(again)
        XCTAssertEqual(recorder.requests.filter { $0.url?.path.hasSuffix("/facts") == true }.count, 1)
    }

    private func helper(_ recorder: RequestRecorder) -> HelperClient {
        HelperClient(credentials: HelperCredentials(host: "192.168.1.20", pin: Data([1]), token: "t")) { request in
            try await recorder.send(request)
        }
    }

    private func browserClient(_ recorder: RequestRecorder) -> HelperClient {
        helper(recorder)
    }

    private func boxBlur(checker n: Int, radius: Int) -> [UInt8] {
        var src = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n where ((x / 2) + (y / 2)) % 2 == 0 {
                src[y * n + x] = 255
            }
        }
        var dst = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                var sum = 0
                var count = 0
                for yy in (y - radius)...(y + radius) where yy >= 0 && yy < n {
                    for xx in (x - radius)...(x + radius) where xx >= 0 && xx < n {
                        sum += Int(src[yy * n + xx])
                        count += 1
                    }
                }
                dst[y * n + x] = UInt8(sum / max(count, 1))
            }
        }
        return dst
    }

    private func writeTinyJPEG(to url: URL) throws {
        let image = try XCTUnwrap(MacCheckpoint.image(width: 16, height: 16) { x, y in
            ((x / 2) + (y / 2)) % 2 == 0 ? 255 : 0
        })
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            XCTFail("jpeg destination")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [HelperResponse] = []
    private var seen: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func enqueue(_ response: HelperResponse) {
        lock.lock()
        script.append(response)
        lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> HelperResponse {
        lock.lock()
        defer { lock.unlock() }
        seen.append(request)
        guard !script.isEmpty else { throw HelperError.offline }
        return script.removeFirst()
    }
}
