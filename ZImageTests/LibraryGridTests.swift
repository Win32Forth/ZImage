import AppKit
import PDFKit
import XCTest
@testable import ZImage

@MainActor
final class LibraryGridTests: XCTestCase {
    func testGridCellsComeFromThumbnailURLAndSliderDoesNotRefetch() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let page = Data("""
        {"rows":[
          {"uid":"still-1","relPath":"Photos/img1.jpg","ext":"jpg","mediaClass":"image","thumbRel":".zimage/cache/thumbs/ab/still-1.jpg","phase":"thumbed","isKeeper":false,"pinned":false},
          {"uid":"pdf-1","relPath":"Photos/doc.pdf","ext":"pdf","mediaClass":"pdf","phase":"discovered","isKeeper":false,"pinned":false},
          {"uid":"mov-1","relPath":"Photos/clip.mov","ext":"mov","mediaClass":"video","phase":"discovered","isKeeper":false,"pinned":false}
        ],"nextCursor":""}
        """.utf8)
        let fake = GridFakeListener()
        fake.enqueue(.success(HelperResponse(status: 200, body: page)))
        fake.enqueue(.success(HelperResponse(status: 200, body: jpeg)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-grid-\(UUID().uuidString)", isDirectory: true)
        var opened: [(URL, String)] = []
        let browser = LibraryBrowser(
            client: HelperClient(credentials: HelperCredentials(host: "192.168.1.20", pin: Data([1]), token: "t")) { request in
                try await fake.send(request)
            },
            libraryRoot: root,
            openFile: { url, bundleID in
                opened.append((url, bundleID))
            }
        )
        await browser.reload()
        XCTAssertEqual(browser.rows.map(\.uid), ["still-1", "pdf-1", "mov-1"])
        let still = try XCTUnwrap(browser.cells["still-1"])
        let thumb = try XCTUnwrap(still.thumbnailURL)
        XCTAssertEqual(thumb.scheme, "https")
        XCTAssertFalse(thumb.isFileURL)
        XCTAssertEqual(thumb.path, "/v1/assets/still-1/thumbnail")
        XCTAssertEqual(still.imageData, jpeg)
        XCTAssertFalse(still.placeholder)
        XCTAssertEqual(fake.paths, ["/v1/assets", "/v1/assets/still-1/thumbnail"])
        XCTAssertFalse(fake.urls.contains { $0.isFileURL })

        let pdfCell = try XCTUnwrap(browser.cells["pdf-1"])
        XCTAssertTrue(pdfCell.placeholder)
        XCTAssertNil(pdfCell.thumbnailURL)
        let movCell = try XCTUnwrap(browser.cells["mov-1"])
        XCTAssertEqual(movCell.badge, "Video")
        XCTAssertTrue(movCell.placeholder)

        let requests = browser.thumbnailRequestCount
        browser.setPreviewPoints(80)
        browser.setPreviewPoints(480)
        browser.setPreviewPoints(10)
        XCTAssertEqual(browser.previewPoints, PreviewSize.minimumPoints)
        browser.setPreviewPoints(900)
        XCTAssertEqual(browser.previewPoints, PreviewSize.maximumPoints)
        XCTAssertEqual(browser.thumbnailRequestCount, requests)
        XCTAssertEqual(fake.paths, ["/v1/assets", "/v1/assets/still-1/thumbnail"])

        browser.openInEditor(try XCTUnwrap(browser.rows.first { $0.uid == "mov-1" }))
        XCTAssertTrue(opened.isEmpty)
        browser.selectedUID = "pdf-1"
        browser.openSelected()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].1, "com.Win32Forth.ZImage")
        XCTAssertEqual(opened[0].0.lastPathComponent, "doc.pdf")
        XCTAssertTrue(opened[0].0.isFileURL)
    }

    func testPDFGridItemOpensPagePickerAndMovieDoesNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("Photos/page.pdf")
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.white.set()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        let page = try XCTUnwrap(PDFPage(image: image))
        document.insert(page, at: 0)
        XCTAssertTrue(document.write(to: pdfURL))

        var opened: [URL] = []
        let browser = LibraryBrowser(
            client: LibraryAppClient.offline(),
            libraryRoot: root,
            openFile: { url, _ in opened.append(url) }
        )
        let pdf = LibraryAsset(uid: "pdf-1", relPath: "Photos/page.pdf", ext: "pdf", mediaClass: "pdf")
        let mov = LibraryAsset(uid: "mov-1", relPath: "Photos/clip.mov", ext: "mov", mediaClass: "video")
        browser.openInEditor(mov)
        XCTAssertTrue(opened.isEmpty)
        browser.openInEditor(pdf)
        XCTAssertEqual(opened, [pdfURL])

        let editor = EditorModel()
        editor.openSecurityScopedFile(at: pdfURL)
        XCTAssertTrue(editor.showsPDFPicker)
        XCTAssertNotNil(editor.pdfDocument)

        let movURL = root.appendingPathComponent("Photos/clip.mov")
        try Data().write(to: movURL)
        let movieEditor = EditorModel()
        movieEditor.openSecurityScopedFile(at: movURL)
        XCTAssertFalse(movieEditor.showsPDFPicker)
    }

    func testSandboxPreferencesRestoreTheHelperHostAndFolder() throws {
        let suite = "com.Win32Forth.ZImageLibrary.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-container-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plist = folder.appendingPathComponent("com.Win32Forth.ZImageLibrary.plist")
        let bookmark = Data("bookmark".utf8)
        let stored: [String: Any] = [
            LibraryAppClient.hostDefaultsKey: "192.168.1.147",
            LibraryFolderBookmark.defaultsKey: bookmark,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: stored, format: .binary, options: 0)
        try data.write(to: plist)
        SandboxPreferenceImport.adopt(into: defaults, containerPlist: plist)
        XCTAssertEqual(defaults.string(forKey: LibraryAppClient.hostDefaultsKey), "192.168.1.147")
        XCTAssertEqual(defaults.data(forKey: LibraryFolderBookmark.defaultsKey), bookmark)
        defaults.set("10.0.0.8", forKey: LibraryAppClient.hostDefaultsKey)
        SandboxPreferenceImport.adopt(into: defaults, containerPlist: plist)
        XCTAssertEqual(defaults.string(forKey: LibraryAppClient.hostDefaultsKey), "10.0.0.8")
    }

    func testShareBookmarkRoundTripAndSidebarOmitsDuplicates() throws {
        XCTAssertEqual(LibrarySidebar.items, ["Photos", "Videos", "Review", "Duplicates"])
        XCTAssertFalse(LibrarySidebar.items.contains("_Duplicates"))
        let suite = "com.Win32Forth.ZImageLibrary.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(LibraryFolderBookmark.resolve(defaults: defaults))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try LibraryFolderBookmark.store(folder, defaults: defaults)
        let resolved = try XCTUnwrap(LibraryFolderBookmark.resolve(defaults: defaults))
        XCTAssertEqual(resolved.standardizedFileURL.path, folder.standardizedFileURL.path)
    }

    func testSmbMountResolvesThroughTheLocalHostname() throws {
        XCTAssertEqual(
            LibraryPairing.mountHost(fromMountSource: "//win32forth@DS423._smb._tcp.local/BackupData"),
            "DS423._smb._tcp.local"
        )
        XCTAssertEqual(
            LibraryPairing.mountHost(fromMountSource: "smb://win32forth@DS423._smb._tcp.local/BackupData"),
            "DS423._smb._tcp.local"
        )
        var asked: [String] = []
        let address = try LibraryPairing.firstIPv4(mountHost: "DS423._smb._tcp.local") { name in
            asked.append(name)
            if name == "DS423.local" { return "192.168.1.147" }
            throw HelperError.notIPv4
        }
        XCTAssertEqual(address, "192.168.1.147")
        XCTAssertEqual(asked, ["DS423._smb._tcp.local", "DS423.local"])
        XCTAssertThrowsError(try LibraryPairing.firstIPv4(mountHost: "DS423._smb._tcp.local") { _ in
            throw HelperError.notIPv4
        }) { error in
            XCTAssertEqual(error as? HelperError, .notIPv4)
        }
    }

    func testPairingFileIsClaimedBeforeTheStoredToken() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-pair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".zimage"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("from-file\n".utf8).write(to: root.appendingPathComponent(".zimage/PAIRING-TOKEN"))
        try Data("from-auth\n".utf8).write(to: root.appendingPathComponent(".zimage/auth.token"))
        let material = try LibraryPairing.material(inLibraryRoot: root)
        XCTAssertEqual(material.token, "from-file")
        XCTAssertTrue(material.fromPairingFile)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".zimage/PAIRING-TOKEN"))
        let stored = try LibraryPairing.material(inLibraryRoot: root)
        XCTAssertEqual(stored.token, "from-auth")
        XCTAssertFalse(stored.fromPairingFile)
    }

    func testConnectSwitchesTheGridToThePairedHelper() async throws {
        let browser = LibraryBrowser(
            client: LibraryAppClient.offline(),
            libraryRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            openFile: { _, _ in }
        )
        await browser.reload()
        XCTAssertTrue(browser.session.isEmptyOffline)
        let page = Data(#"{"rows":[{"uid":"still-1","relPath":"Photos/img1.jpg","ext":"jpg","mediaClass":"image","thumbRel":".zimage/cache/thumbs/ab/still-1.jpg"}],"nextCursor":""}"#.utf8)
        let fake = GridFakeListener()
        fake.enqueue(.success(HelperResponse(status: 200, body: page)))
        fake.enqueue(.success(HelperResponse(status: 200, body: Data([0xFF, 0xD8]))))
        browser.connect(HelperClient(credentials: HelperCredentials(host: "192.168.1.147", pin: Data([2]), token: "t")) { request in
            try await fake.send(request)
        })
        await browser.reload()
        XCTAssertEqual(browser.rows.map(\.uid), ["still-1"])
        XCTAssertEqual(fake.paths, ["/v1/assets", "/v1/assets/still-1/thumbnail"])
        XCTAssertNil(browser.notice)
    }

    func testVisibleFolderGetsAPreviewBeforeTheRestOfTheQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-preview-\(UUID().uuidString)", isDirectory: true)
        let photos = root.appendingPathComponent("Photos/2026", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = photos.appendingPathComponent("first.jpg")
        let second = photos.appendingPathComponent("second.jpg")
        try Self.writeTinyJPEG(to: first)
        try Self.writeTinyJPEG(to: second)
        let page = Data("""
        {"rows":[
          {"uid":"aa-first","relPath":"Photos/2026/first.jpg","ext":"jpg","mediaClass":"image","phase":"discovered","isKeeper":false,"pinned":false},
          {"uid":"bb-second","relPath":"Photos/2026/second.jpg","ext":"jpg","mediaClass":"image","phase":"discovered","isKeeper":false,"pinned":false}
        ],"nextCursor":""}
        """.utf8)
        let fake = GridFakeListener()
        let browser = LibraryBrowser(
            client: HelperClient(credentials: HelperCredentials(host: "192.168.1.20", pin: Data([1]), token: "t")) { request in
                try await fake.send(request)
            },
            libraryRoot: root,
            openFile: { _, _ in }
        )
        fake.enqueue(.success(HelperResponse(status: 200, body: page)))
        await browser.reload(media: "photo")
        fake.enqueue(.success(HelperResponse(status: 200, body: Data("{}".utf8))))
        fake.enqueue(.success(HelperResponse(status: 200, body: Data([0xFF, 0xD8]))))
        let made = await browser.previewVisibleOne()
        XCTAssertTrue(made)
        XCTAssertEqual(fake.paths, ["/v1/assets", "/v1/assets/aa-first/facts", "/v1/assets/aa-first/thumbnail"])
        XCTAssertEqual(browser.rows[0].thumbRel, ".zimage/cache/thumbs/aa/aa-first.jpg")
        XCTAssertNil(browser.rows[1].thumbRel)
        XCTAssertNotNil(browser.cells["aa-first"]?.imageData)
    }

    private static func writeTinyJPEG(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    func testBlankSquaresWaitForPreviewsAndOversizedFilesStayEmpty() async throws {
        let waiting = Data("""
        {"rows":[
          {"uid":"soon","relPath":"Photos/soon.jpg","ext":"jpg","mediaClass":"image","phase":"discovered","isKeeper":false,"pinned":false},
          {"uid":"retry","relPath":"Photos/retry.jpg","ext":"jpg","mediaClass":"image","phase":"discovered","decodeSupport":"unknown","isKeeper":false,"pinned":false}
        ],"nextCursor":""}
        """.utf8)
        let settled = Data("""
        {"rows":[
          {"uid":"huge","relPath":"Photos/huge.jpg","ext":"jpg","mediaClass":"image","phase":"discovered","decodeSupport":"needs_mac","isKeeper":false,"pinned":false}
        ],"nextCursor":""}
        """.utf8)
        let browser = LibraryBrowser(
            client: HelperClient(credentials: HelperCredentials(host: "192.168.1.20", pin: Data([1]), token: "t")) { request in
                let body = request.url?.path == "/v1/assets" ? waiting : Data()
                return HelperResponse(status: 200, body: body)
            },
            libraryRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            openFile: { _, _ in }
        )
        await browser.reload()
        XCTAssertTrue(browser.awaitsPreviews)
        XCTAssertEqual(browser.previewStatus, "Reduced previews are still being written. These squares fill in as each one is stored.")
        XCTAssertNil(browser.cells["soon"]?.badge)
        XCTAssertNil(browser.cells["retry"]?.badge)
        XCTAssertTrue(browser.cells["soon"]?.placeholder == true)

        let settledBrowser = LibraryBrowser(
            client: HelperClient(credentials: HelperCredentials(host: "192.168.1.20", pin: Data([1]), token: "t")) { _ in
                HelperResponse(status: 200, body: settled)
            },
            libraryRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            openFile: { _, _ in }
        )
        await settledBrowser.reload()
        XCTAssertFalse(settledBrowser.awaitsPreviews)
        XCTAssertEqual(settledBrowser.previewStatus, "Some photos are over 32 million pixels or could not be reduced. Those squares stay empty.")
        XCTAssertEqual(settledBrowser.cells["huge"]?.badge, "No preview")
        XCTAssertEqual(settledBrowser.thumbnailRequestCount, 0)
    }

    func testContextMenuPutsZImageFirstAndShowsDecimalMegabytes() throws {
        XCTAssertEqual(LibraryItemMenu.commandOrder, ["Open with ZImage", "Show in Finder", "Open With"])
        XCTAssertEqual(LibraryItemMenu.videoCommandOrder, ["Open with QuickTime Player", "Show in Finder", "Open With"])
        XCTAssertEqual(LibraryItemMenu.captureLabel(nil), "No date")
        XCTAssertEqual(LibraryItemMenu.captureLabel("1964"), "1964")
        XCTAssertEqual(LibraryItemMenu.captureLabel("2020-05-01T12:00:00Z"), "2020-05-01")
        let minnesota = "Photos/2010/20100714_27 Minnisota trip/20100717_100SSCAM day 4/SDC13577.MP4"
        XCTAssertEqual(PathCapture.day(in: minnesota), "2010-07-17")
        XCTAssertEqual(PathCapture.lines(for: minnesota), ["Path date 2010-07-17"])
        XCTAssertEqual(LibraryItemMenu.videoCaption(captureTime: nil, relPath: minnesota), "2010-07-17")
        XCTAssertEqual(LibraryItemMenu.videoCaption(captureTime: "2011-01-02T00:00:00Z", relPath: minnesota), "2011-01-02")
        XCTAssertEqual(LibraryItemMenu.videoCaption(captureTime: nil, relPath: "Photos/2010/clip.mp4"), "2010")
        XCTAssertEqual(LibraryItemMenu.videoCaption(captureTime: nil, relPath: "Photos/clip.mp4"), "No date")
        XCTAssertEqual(LibraryItemMenu.sizeLabel(bytes: 2_500_000), "2.5 MB")
        XCTAssertEqual(LibraryItemMenu.sizeLabel(bytes: 0), "0.0 MB")
        XCTAssertEqual(LibraryItemMenu.sizeLabel(bytes: nil), LibraryItemMenu.sizeUnavailable)

        let zimage = URL(fileURLWithPath: "/Applications/ZImage.app")
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let targets = LibraryItemMenu.applications(
            zimage: zimage,
            others: [preview, zimage, preview]
        ) { url in
            url.deletingPathExtension().lastPathComponent
        }
        XCTAssertEqual(targets.map(\.name), ["ZImage", "Preview"])
        XCTAssertEqual(targets.map(\.isZImage), [true, false])
        let quickTime = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
        let vlc = URL(fileURLWithPath: "/Applications/VLC.app")
        let videoTargets = LibraryItemMenu.videoApplications(
            quickTime: quickTime,
            others: [zimage, vlc, quickTime],
            editor: zimage
        ) { url in
            url.deletingPathExtension().lastPathComponent
        }
        XCTAssertEqual(videoTargets.map(\.name), ["QuickTime Player", "VLC"])
        XCTAssertEqual(videoTargets.map(\.isZImage), [false, false])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Photos/still.jpg")
        try Data(count: 1_500_000).write(to: file)
        let browser = LibraryBrowser(
            client: LibraryAppClient.offline(),
            libraryRoot: root,
            openFile: { _, _ in }
        )
        let asset = LibraryAsset(uid: "still", relPath: "Photos/still.jpg", ext: "jpg", mediaClass: "image")
        XCTAssertEqual(browser.fileURL(for: asset), file)
        XCTAssertEqual(browser.sizeLabel(for: asset), "1.5 MB")
        let video = LibraryAsset(uid: "clip", relPath: "Photos/clip.mov", ext: "mov", mediaClass: "video")
        XCTAssertFalse(browser.canOpenInEditor(video))
        XCTAssertTrue(browser.canOpenInEditor(asset))
        let mov = root.appendingPathComponent("Photos/clip.mov")
        try Data(count: 8).write(to: mov)
        var played: [URL] = []
        var edited: [URL] = []
        browser.openVideo = { played.append($0) }
        browser.openFile = { url, _ in edited.append(url) }
        browser.openPrimary(video)
        XCTAssertEqual(played, [mov])
        XCTAssertTrue(edited.isEmpty)
        browser.openPrimary(asset)
        XCTAssertEqual(edited, [file])
        XCTAssertEqual(played.count, 1)
        let webm = LibraryAsset(uid: "webm", relPath: "Photos/clip.webm", ext: "webm", mediaClass: "other")
        XCTAssertTrue(browser.isVideo(webm))
    }

    func testVideoListSortsByDateAndPhotosOmitVideos() async throws {
        let page = Data("""
        {"rows":[
          {"uid":"later","relPath":"Photos/later.mp4","ext":"mp4","mediaClass":"video","captureTime":"2020-05-01T12:00:00Z","isKeeper":false,"pinned":false},
          {"uid":"still","relPath":"Photos/a.jpg","ext":"jpg","mediaClass":"image","isKeeper":false,"pinned":false},
          {"uid":"earlier","relPath":"Photos/earlier.mov","ext":"mov","mediaClass":"video","captureTime":"2014-07-04T15:30:00Z","isKeeper":false,"pinned":false},
          {"uid":"undated","relPath":"Photos/none.mov","ext":"mov","mediaClass":"video","isKeeper":false,"pinned":false}
        ],"nextCursor":""}
        """.utf8)
        let fake = GridFakeListener()
        let browser = LibraryBrowser(
            client: HelperClient(credentials: HelperCredentials(host: "192.168.1.20", pin: Data([1]), token: "t")) { request in
                try await fake.send(request)
            },
            libraryRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            openFile: { _, _ in }
        )
        fake.enqueue(.success(HelperResponse(status: 200, body: page)))
        await browser.reload(media: "video")
        XCTAssertEqual(browser.rows.map(\.uid), ["earlier", "later", "undated"])
        fake.enqueue(.success(HelperResponse(status: 200, body: page)))
        await browser.reload(media: "photo")
        XCTAssertEqual(browser.rows.map(\.uid), ["still"])
        XCTAssertEqual(queryValue("media", fake.urls[0]), "video")
        XCTAssertEqual(queryValue("q", fake.urls[0]), "Photos/")
        XCTAssertEqual(queryValue("media", fake.urls[1]), "photo")
        XCTAssertEqual(queryValue("q", fake.urls[1]), "Photos/")
        browser.displayFolder = "Photos/2026"
        fake.enqueue(.success(HelperResponse(status: 200, body: page)))
        await browser.reload(media: "photo")
        XCTAssertEqual(queryValue("q", fake.urls[2]), "Photos/2026/")
        fake.enqueue(.success(HelperResponse(status: 200, body: page)))
        await browser.reload(media: "video")
        XCTAssertEqual(queryValue("media", fake.urls[3]), "video")
        XCTAssertEqual(queryValue("q", fake.urls[3]), "Photos/2026/")
    }

    func testFolderTreeListsDirectoriesOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-tree-\(UUID().uuidString)", isDirectory: true)
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("2026/day"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("2024"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data([0xFF]).write(to: photos.appendingPathComponent("note.jpg"))
        try Data([0xFF]).write(to: photos.appendingPathComponent("2026/day/a.jpg"))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            LibraryFolderScan.childFolders(libraryRoot: root, parent: "Photos").map(\.name),
            ["2024", "2026"]
        )
        XCTAssertEqual(
            LibraryFolderScan.childFolders(libraryRoot: root, parent: "Photos/2026").map(\.rel),
            ["Photos/2026/day"]
        )
        XCTAssertEqual(LibraryFolderScan.childFolders(libraryRoot: root, parent: "Photos/2026/day"), [])
    }

    func testDisplayFolderStaysInsidePhotos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-display-\(UUID().uuidString)", isDirectory: true)
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("2026"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("_Duplicates").appendingPathComponent("ab"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(DisplayFolder.prefix(selected: photos, libraryRoot: root), "Photos")
        XCTAssertEqual(
            DisplayFolder.prefix(selected: photos.appendingPathComponent("2026"), libraryRoot: root),
            "Photos/2026"
        )
        XCTAssertEqual(
            DisplayFolder.prefix(selected: photos.appendingPathComponent("_Duplicates").appendingPathComponent("ab"), libraryRoot: root),
            "Photos/_Duplicates/ab"
        )
        XCTAssertNil(DisplayFolder.prefix(selected: root, libraryRoot: root))
        XCTAssertNil(DisplayFolder.prefix(selected: root.appendingPathComponent("Audio"), libraryRoot: root))
        XCTAssertEqual(DisplayFolder.needle("Photos"), "Photos/")
        XCTAssertEqual(DisplayFolder.needle("Photos/2026"), "Photos/2026/")
        XCTAssertNil(DisplayFolder.needle("Audio"))
        XCTAssertNil(DisplayFolder.needle("Photos/../Audio"))
        XCTAssertEqual(LibrarySidebar.sectionAfterTreePick("Videos"), "Videos")
        XCTAssertEqual(LibrarySidebar.media(for: "Videos"), "video")
        XCTAssertEqual(LibrarySidebar.sectionAfterTreePick("Photos"), "Photos")
        XCTAssertEqual(LibrarySidebar.sectionAfterTreePick("Review"), "Photos")
        XCTAssertEqual(LibrarySidebar.sectionAfterTreePick("Duplicates"), "Photos")
    }

    func testReorgFolderPickerKeepsAPhotosPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-reorg-\(UUID().uuidString)", isDirectory: true)
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("2025", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("_Duplicates", isDirectory: true).appendingPathComponent("ab", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Audio", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            ReorgFolder.prefix(selected: photos.appendingPathComponent("2025", isDirectory: true), libraryRoot: root),
            "Photos/2025"
        )
        XCTAssertEqual(ReorgFolder.prefix(selected: photos, libraryRoot: root), "Photos")
        XCTAssertNil(ReorgFolder.prefix(selected: root.appendingPathComponent("Audio"), libraryRoot: root))
        XCTAssertNil(ReorgFolder.prefix(selected: photos.appendingPathComponent("_Duplicates").appendingPathComponent("ab"), libraryRoot: root))
        XCTAssertNil(ReorgFolder.prefix(selected: root, libraryRoot: root))
        XCTAssertEqual(ReorgCopy.outsidePhotos, "The plan prefix must be Photos or a folder inside it.")
    }

    func testChangedFolderDoesNotStartTheOldPlan() async throws {
        let status = Data("""
        {"reorgSafeToReboot":true,"runState":"plan_ready","phase":"Photos","pauseRequested":false,"move":3,"alreadyPlaced":1,"park":0,"leave":2,"cacheBytes":10,"rssBytes":1,"lastRecovery":"none"}
        """.utf8)
        let fake = GridFakeListener()
        fake.enqueue(.success(HelperResponse(status: 200, body: status)))
        let browser = LibraryBrowser(
            client: HelperClient(credentials: HelperCredentials(host: "192.168.1.20", pin: Data([1]), token: "t")) { request in
                try await fake.send(request)
            },
            libraryRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            openFile: { _, _ in }
        )
        await browser.loadReorg()
        browser.reorgPrefix = "Photos/2025"
        browser.reorgPrefixChanged(from: "Photos", to: "Photos/2025")
        await browser.startReorg()
        XCTAssertEqual(browser.reorgNotice, ReorgCopy.startNeedsPlan(typed: "Photos/2025", saved: "Photos"))
        XCTAssertNil(browser.reorgPending)
        XCTAssertEqual(fake.paths, ["/v1/reorg/status"])
    }

    func testPlanTimeoutNamesTheWaitAndStartShowsTheCopy() async throws {
        let planning = Data("""
        {"reorgSafeToReboot":true,"runState":"planning","phase":"Photos","pauseRequested":false,"move":4,"alreadyPlaced":1,"park":2,"leave":0,"counting":true,"cacheBytes":0,"rssBytes":0,"lastRecovery":"none"}
        """.utf8)
        let running = Data("""
        {"reorgSafeToReboot":false,"runState":"running","phase":"Photos","pauseRequested":false,"move":3,"alreadyPlaced":1,"park":0,"leave":2,"cacheBytes":10,"rssBytes":1,"lastRecovery":"none"}
        """.utf8)
        let ready = Data("""
        {"reorgSafeToReboot":true,"runState":"plan_ready","phase":"Photos","pauseRequested":false,"move":3,"alreadyPlaced":1,"park":0,"leave":2,"cacheBytes":10,"rssBytes":1,"lastRecovery":"none"}
        """.utf8)
        let fake = GridFakeListener()
        let browser = LibraryBrowser(
            client: HelperClient(credentials: HelperCredentials(host: "192.168.1.20", pin: Data([1]), token: "t")) { request in
                try await fake.send(request)
            },
            libraryRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            openFile: { _, _ in }
        )
        fake.enqueue(.failure(URLError(.timedOut)))
        fake.enqueue(.success(HelperResponse(status: 200, body: planning)))
        await browser.planReorg()
        XCTAssertNil(browser.reorgNotice)
        XCTAssertEqual(browser.reorgPending, .planning("Photos"))
        XCTAssertEqual(browser.reorg?.runState, "planning")
        let counting = ReorgActivity.readout(status: browser.reorg, typedPrefix: browser.reorgPrefix, pending: browser.reorgPending)
        XCTAssertTrue(counting.showsCounts)
        XCTAssertEqual(counting.activity, "Counting")
        XCTAssertEqual(browser.reorg?.move, 4)
        XCTAssertEqual(browser.reorg?.park, 2)
        fake.enqueue(.success(HelperResponse(status: 200, body: ready)))
        await browser.loadReorg()
        XCTAssertEqual(browser.reorg?.runState, "plan_ready")
        XCTAssertNil(browser.reorgNotice)
        XCTAssertNil(browser.reorgPending)
        fake.enqueue(.success(HelperResponse(status: 200, body: running)))
        await browser.startReorg()
        XCTAssertEqual(browser.reorg?.runState, "running")
        XCTAssertNil(browser.reorgPending)
        XCTAssertNil(browser.reorgNotice)
        let copy = ReorgActivity.readout(status: browser.reorg, typedPrefix: "Photos", pending: nil)
        XCTAssertEqual(copy.activity, "Copying")
        XCTAssertTrue(copy.showsCounts)
        XCTAssertEqual(fake.paths, ["/v1/reorg/plan", "/v1/reorg/status", "/v1/reorg/status", "/v1/reorg/start"])
    }

    func testOfflineLaunchDoesNotDial() async {
        let fake = GridFakeListener()
        let browser = LibraryBrowser(client: LibraryAppClient.offline(), libraryRoot: URL(fileURLWithPath: NSTemporaryDirectory()), openFile: { _, _ in })
        await browser.reload()
        XCTAssertTrue(browser.session.isEmptyOffline)
        XCTAssertTrue(browser.rows.isEmpty)
        XCTAssertEqual(fake.callCount, 0)
        XCTAssertEqual(browser.thumbnailRequestCount, 0)
    }
}

private func queryValue(_ name: String, _ url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

private final class GridFakeListener: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<HelperResponse, Error>] = []
    private var seen: [URL] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen.map(\.path)
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }

    func enqueue(_ result: Result<HelperResponse, Error>) {
        lock.lock()
        script.append(result)
        lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> HelperResponse {
        let next = take(request.url)
        guard let next else { throw URLError(.cannotConnectToHost) }
        return try next.get()
    }

    private func take(_ url: URL?) -> Result<HelperResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        if let url { seen.append(url) }
        return script.isEmpty ? nil : script.removeFirst()
    }
}
