import XCTest
@testable import ZImager

@MainActor
final class DuplicatesBrowserTests: XCTestCase {
    func testOneThumbnailPerFileAndSliderDoesNotRefetch() async throws {
        let page = Data("""
        {"groups":[{
          "uid":"g1",
          "keeper":{"uid":"keep","relPath":"Photos/2020/event/a.jpg","ext":"jpg","mediaClass":"image","detailScore":10,"nativePixels":1000000,"isKeeper":true,"placement":"active","pinned":false,"phase":"placed"},
          "members":[
            {"uid":"copy-1","relPath":"Photos/_Duplicates/g1/b.jpg","ext":"jpg","mediaClass":"image","detailScore":10,"nativePixels":16000000,"isKeeper":false,"placement":"duplicates","pinned":false,"phase":"placed","thumbRel":".zimage/cache/thumbs/ab/copy-1.jpg"},
            {"uid":"copy-2","relPath":"Photos/_Duplicates/g1/c.jpg","ext":"jpg","mediaClass":"image","detailScore":4.5,"nativePixels":2000000,"isKeeper":false,"placement":"duplicates","pinned":true,"phase":"placed","thumbRel":".zimage/cache/thumbs/ab/copy-2.jpg"},
            {"uid":"copy-3","relPath":"Photos/_Duplicates/g1/d.jpg","ext":"jpg","mediaClass":"image","detailScore":1,"nativePixels":500000,"isKeeper":false,"placement":"duplicates","pinned":false,"phase":"placed"}
          ]
        }],"nextCursor":""}
        """.utf8)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let fake = DuplicateFakeListener()
        fake.enqueue(.success(HelperResponse(status: 200, body: page)))
        fake.enqueue(.success(HelperResponse(status: 200, body: jpeg)))
        fake.enqueue(.success(HelperResponse(status: 200, body: jpeg)))
        let browser = browser(fake)
        await browser.loadDuplicates()
        XCTAssertEqual(browser.duplicateGroups.map(\.uid), ["g1"])
        XCTAssertEqual(browser.duplicateGroups[0].keeper?.uid, "keep")
        XCTAssertEqual(DuplicateCopy.keeper, "Keeper")
        let copy = try XCTUnwrap(browser.duplicateGroups[0].members.first { $0.uid == "copy-1" })
        XCTAssertEqual(DuplicateCopy.captions(score: copy.detailScore, pixels: copy.nativePixels), ["Score 10.0", "16.0 MP"])
        XCTAssertEqual(browser.duplicateThumbCount, 2)
        XCTAssertEqual(browser.thumbnailRequestCount, 0)
        XCTAssertTrue(browser.rows.isEmpty)
        XCTAssertEqual(fake.paths, [
            "/v1/duplicates",
            "/v1/assets/copy-1/thumbnail",
            "/v1/assets/copy-2/thumbnail",
        ])
        let requests = browser.duplicateThumbCount
        browser.setPreviewPoints(80)
        browser.setPreviewPoints(480)
        XCTAssertEqual(browser.duplicateThumbCount, requests)
        XCTAssertEqual(fake.paths.count, 3)
        browser.deleteKey()
        XCTAssertEqual(fake.paths.count, 3)
        XCTAssertEqual(browser.duplicateGroups[0].members.map(\.uid), ["copy-1", "copy-2", "copy-3"])
        _ = DuplicatesBrowser(browser: browser, model: EditorModel())
    }

    func testWrongDeletePhraseDoesNotCallPurgeAll() async throws {
        let page = Data(#"{"groups":[],"nextCursor":""}"#.utf8)
        let fake = DuplicateFakeListener()
        fake.enqueue(.success(HelperResponse(status: 200, body: page)))
        let browser = browser(fake)
        await browser.loadDuplicates()
        await browser.purgeAllDuplicates(confirm: "delete")
        XCTAssertEqual(browser.duplicateNotice, "Type DELETE to delete every duplicate.")
        XCTAssertEqual(fake.paths, ["/v1/duplicates"])
        fake.enqueue(.success(HelperResponse(status: 400, body: Data(#"{"error":"confirm"}"#.utf8))))
        await browser.purgeAllDuplicates(confirm: "DELETE")
        XCTAssertEqual(fake.paths, ["/v1/duplicates", "/v1/duplicates/purge-all"])
        XCTAssertEqual(fake.methods.last, "POST")
    }

    func testRestoreAndPinUseTheirOwnRoutes() async throws {
        let listed = Data("""
        {"groups":[{"uid":"g1","keeper":null,"members":[
          {"uid":"copy-1","relPath":"Photos/_Duplicates/g1/b.jpg","ext":"jpg","mediaClass":"image","isKeeper":false,"placement":"duplicates","pinned":false,"phase":"placed"}
        ]}],"nextCursor":""}
        """.utf8)
        let restored = Data(#"{"uid":"copy-1","relPath":"Photos/2020/event/b.jpg","ext":"jpg","mediaClass":"image","isKeeper":false,"placement":"active","pinned":true,"phase":"placed"}"#.utf8)
        let empty = Data(#"{"groups":[],"nextCursor":""}"#.utf8)
        let fake = DuplicateFakeListener()
        fake.enqueue(.success(HelperResponse(status: 200, body: listed)))
        fake.enqueue(.success(HelperResponse(status: 200, body: restored)))
        fake.enqueue(.success(HelperResponse(status: 200, body: empty)))
        let browser = browser(fake)
        await browser.loadDuplicates()
        let asset = try XCTUnwrap(browser.duplicateGroups.first?.members.first)
        await browser.restoreDuplicate(asset)
        XCTAssertEqual(browser.duplicateNotice, "Restored and pinned.")
        XCTAssertEqual(fake.paths, ["/v1/duplicates", "/v1/assets/copy-1/restore", "/v1/duplicates"])
        XCTAssertEqual(fake.methods[1], "POST")
        XCTAssertEqual(LibrarySidebar.items, ["Photos", "Review", "Duplicates"])
        XCTAssertFalse(LibrarySidebar.items.contains("_Duplicates"))
    }

    func testFindReportsReadyGroupsWhenTheListIsEmpty() async throws {
        let status = Data(#"{"safeToReboot":true,"runState":"idle","pauseRequested":false,"eligible":4,"moved":0,"waiting":2}"#.utf8)
        let empty = Data(#"{"groups":[],"nextCursor":""}"#.utf8)
        let fake = DuplicateFakeListener()
        fake.enqueue(.success(HelperResponse(status: 200, body: status)))
        fake.enqueue(.success(HelperResponse(status: 200, body: empty)))
        let browser = browser(fake)
        await browser.findDuplicates()
        XCTAssertEqual(browser.duplicateNotice, DuplicateCopy.findResult(groups: 0, eligible: 4, waiting: 2))
        XCTAssertEqual(browser.duplicateGroups.count, 0)
        XCTAssertEqual(fake.paths, ["/v1/trim/status", "/v1/duplicates"])
        XCTAssertTrue(fake.queries.contains { $0.contains("found=1") })
        XCTAssertEqual(DuplicateCopy.emptyList.contains("Find duplicates"), true)
        XCTAssertEqual(DuplicateCopy.activity("running"), "Gathering copies.")
        XCTAssertEqual(DuplicateCopy.placeLine("Photos/2020/event/a.jpg"), "Photos/2020/event")
        XCTAssertNil(DuplicateCopy.placeLine("Photos/_Duplicates/g1/b.jpg"))
        XCTAssertFalse(DuplicateCopy.inStore("Photos/2020/event/a.jpg"))
    }

    private func browser(_ fake: DuplicateFakeListener) -> LibraryBrowser {
        LibraryBrowser(
            client: HelperClient(credentials: HelperCredentials(host: "192.168.1.20", pin: Data([1]), token: "t")) { request in
                try await fake.send(request)
            },
            libraryRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            openFile: { _, _ in }
        )
    }
}

private final class DuplicateFakeListener: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<HelperResponse, Error>] = []
    private var seen: [URLRequest] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen.compactMap { $0.url?.path }
    }

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen.compactMap(\.httpMethod)
    }

    var queries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen.compactMap { $0.url?.query }
    }

    func enqueue(_ result: Result<HelperResponse, Error>) {
        lock.lock()
        script.append(result)
        lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> HelperResponse {
        let next = take(request)
        guard let next else { throw URLError(.cannotConnectToHost) }
        return try next.get()
    }

    private func take(_ request: URLRequest) -> Result<HelperResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        seen.append(request)
        return script.isEmpty ? nil : script.removeFirst()
    }
}
