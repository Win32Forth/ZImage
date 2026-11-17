import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ZImager

final class FolderBrowserTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FolderPreviewCache.wipe()
        FolderPreviewCache.byteCap = FolderPreviewCache.defaultByteCap
    }

    override func tearDown() {
        FolderPreviewCache.byteCap = FolderPreviewCache.defaultByteCap
        FolderPreviewCache.wipe()
        super.tearDown()
    }

    @MainActor
    func testFixtureListsThreeImagesAndOneChildAndSliderWritesNoSecondJPEG() throws {
        XCTAssertEqual(PreviewSize.label, "Preview size")
        XCTAssertEqual(PreviewSize.minimumPoints, 80)
        XCTAssertEqual(PreviewSize.maximumPoints, 480)
        XCTAssertEqual(PreviewSize.defaultPoints, 160)
        XCTAssertEqual(PreviewSize.clamped(10), 80)
        XCTAssertEqual(PreviewSize.clamped(900), 480)
        XCTAssertTrue(FolderPreviewCache.directory.path.hasSuffix("ZImage/folder-previews"))
        XCTAssertEqual(FolderPreviewCache.maxLongEdge, 250)
        XCTAssertEqual(FolderPreviewCache.jpegQuality, 0.7, accuracy: 0.001)
        XCTAssertEqual(FolderPreviewCache.defaultMegabytes, 200)
        XCTAssertEqual(FolderPreviewCache.bytes(forMegabytes: 200), FolderPreviewCache.defaultByteCap)
        XCTAssertEqual(FolderPreviewCache.megabytes(from: " 40 "), 40)
        XCTAssertNil(FolderPreviewCache.megabytes(from: "0"))
        XCTAssertNil(FolderPreviewCache.megabytes(from: "no"))
        XCTAssertEqual(FolderPreviewCache.defaultByteCap, 200 * 1024 * 1024)

        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let entries = try FolderListing.list(folder: root)
        XCTAssertEqual(entries.map(\.name), ["child", "a.jpg", "b.jpg", "wide.jpg"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, false, false, false])
        let names = Set(entries.map(\.name))
        XCTAssertFalse(names.contains("nested.jpg"))
        XCTAssertFalse(names.contains("notes.txt"))
        XCTAssertFalse(names.contains("page.pdf"))
        XCTAssertFalse(names.contains("sample.x3f"))

        let images = entries.filter { !$0.isDirectory }
        XCTAssertEqual(images.count, 3)
        for image in images {
            let jpeg = try FolderPreviewCache.ensureJPEG(for: image.url)
            let edge = try pixelLongEdge(jpeg)
            XCTAssertLessThanOrEqual(edge, 250)
            XCTAssertEqual(jpeg.lastPathComponent, FolderPreviewCache.fileName(for: image.url))
        }
        let wide = try XCTUnwrap(images.first { $0.name == "wide.jpg" })
        let wideEdge = try pixelLongEdge(FolderPreviewCache.directory.appendingPathComponent(FolderPreviewCache.fileName(for: wide.url)))
        XCTAssertGreaterThan(wideEdge, 200)
        XCTAssertLessThanOrEqual(wideEdge, 250)
        XCTAssertEqual(FolderPreviewCache.stamps().count, 3)

        let firstBytes = Dictionary(uniqueKeysWithValues: FolderPreviewCache.stamps().map { ($0.name, $0.bytes) })
        for image in images {
            _ = try FolderPreviewCache.ensureJPEG(for: image.url)
        }
        let rewritten = FolderPreviewCache.stamps()
        XCTAssertEqual(rewritten.count, 3)
        for stamp in rewritten {
            XCTAssertEqual(stamp.bytes, firstBytes[stamp.name])
        }

        let beforeSlider = rewritten
        let model = EditorModel()
        XCTAssertEqual(model.previewPoints, 160)
        model.previewPoints = PreviewSize.clamped(80)
        model.previewPoints = PreviewSize.clamped(480)
        XCTAssertEqual(model.previewPoints, 480)
        XCTAssertEqual(FolderPreviewCache.stamps(), beforeSlider)
        XCTAssertEqual(model.log.commands.count, 0)
    }

    @MainActor
    func testThumbnailOpensInTheEditorAndBackReturnsToTheGrid() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EditorModel()
        model.openFolder(at: root)
        try await waitUntil { model.folderEntries.map(\.name) == ["child", "a.jpg", "b.jpg", "wide.jpg"] }
        XCTAssertTrue(model.showsFolderGrid)
        XCTAssertEqual(model.folderURL?.lastPathComponent, root.lastPathComponent)
        XCTAssertEqual(model.browseRoot?.lastPathComponent, root.lastPathComponent)

        let child = try XCTUnwrap(model.folderEntries.first { $0.isDirectory })
        model.openListedEntry(child)
        try await waitUntil { model.folderEntries.map(\.name) == ["nested.jpg"] }
        XCTAssertEqual(model.folderURL?.lastPathComponent, "child")
        XCTAssertEqual(model.browseRoot?.lastPathComponent, root.lastPathComponent)
        XCTAssertTrue(model.showsFolderGrid)

        let image = try XCTUnwrap(model.folderEntries.first)
        model.openListedEntry(image)
        XCTAssertFalse(model.showsFolderGrid)
        try await waitUntil { model.proxy != nil }
        let proxy = try XCTUnwrap(model.proxy)
        XCTAssertEqual(proxy.entryPoint, .imageIOThumbnail)
        XCTAssertLessThanOrEqual(proxy.longEdge, ProxyRenderer.maxLongEdge)
        XCTAssertEqual(model.openedFileName, "nested.jpg")
        XCTAssertEqual(model.log.commands.count, 0)
        XCTAssertNotNil(model.preview)

        model.returnToFolderGrid()
        XCTAssertTrue(model.showsFolderGrid)
        XCTAssertEqual(model.folderURL?.lastPathComponent, "child")
        try await waitUntil { model.previewJPEG(for: image) != nil }
    }

    @MainActor
    func testFolderImageMenuLeadsWithEditThenFinderThenOpenIn() throws {
        XCTAssertEqual(EditorImageMenu.commandOrder, ["Edit Image", "Show in Finder", "Open In"])
        XCTAssertEqual(
            EditorImageMenu.videoCommandOrder,
            ["Open with QuickTime Player", "Show in Finder", "Open With"]
        )
        let preview = URL(fileURLWithPath: "/Applications/Preview.app")
        let editor = URL(fileURLWithPath: "/Applications/ZImage.app")
        let again = URL(fileURLWithPath: "/Applications/Preview.app")
        let targets = LibraryItemMenu.applications(zimage: editor, others: [preview, editor, again]) { url in
            url.deletingPathExtension().lastPathComponent
        }
        XCTAssertEqual(targets.map(\.name), ["ZImage", "Preview"])
        XCTAssertTrue(targets[0].isZImage)
        XCTAssertFalse(targets[1].isZImage)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-size-\(UUID().uuidString).jpg")
        try Data(repeating: 1, count: 2_500_000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = EditorModel()
        let entry = FolderEntry(url: file, name: file.lastPathComponent, isDirectory: false)
        XCTAssertEqual(model.sizeLabel(for: entry), "2.5 MB")
    }

    func testFolderScrollKeepsTheOffsetAcrossAHiddenGrid() {
        let visible = FolderScrollSample(y: 800, contentHeight: 4000, containerHeight: 500)
        XCTAssertEqual(FolderScrollKeep.rememberedY(visible), 800)
        XCTAssertNil(FolderScrollKeep.rememberedY(FolderScrollSample(y: 0, contentHeight: 10, containerHeight: 500)))
        XCTAssertNil(FolderScrollKeep.rememberedY(FolderScrollSample(y: 800, contentHeight: 4000, containerHeight: 0)))
        XCTAssertEqual(FolderScrollKeep.restoreTarget(saved: 9000, sample: visible), 3500)
        XCTAssertNil(FolderScrollKeep.restoreTarget(saved: 800, sample: FolderScrollSample(y: 0, contentHeight: 0, containerHeight: 500)))

        let reset = FolderScrollSample(y: 0, contentHeight: 4000, containerHeight: 500)
        let holding = FolderScrollKeep.decide(sample: reset, saved: 800, holding: true, folderVisible: true, userMoved: false)
        XCTAssertEqual(holding.scrollTo, 800)
        XCTAssertNil(holding.rememberY)
        XCTAssertFalse(holding.clearHold)

        let arrived = FolderScrollKeep.decide(sample: visible, saved: 800, holding: true, folderVisible: true, userMoved: false)
        XCTAssertEqual(arrived.rememberY, 800)
        XCTAssertTrue(arrived.clearHold)
        XCTAssertNil(arrived.scrollTo)

        let hidden = FolderScrollKeep.decide(sample: reset, saved: 800, holding: false, folderVisible: false, userMoved: false)
        XCTAssertNil(hidden.rememberY)
        XCTAssertNil(hidden.scrollTo)
    }

    func testFolderListShowsAVideoBesideTheStills() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("clip.mp4"))
        let entries = try FolderListing.list(folder: root)
        XCTAssertEqual(entries.map(\.name), ["child", "a.jpg", "b.jpg", "clip.mp4", "wide.jpg"])
        let video = try XCTUnwrap(entries.first { $0.name == "clip.mp4" })
        XCTAssertTrue(video.isVideo)
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.name == "a.jpg" }).isVideo)
        let quickTime = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
        let vlc = URL(fileURLWithPath: "/Applications/VLC.app")
        let editor = URL(fileURLWithPath: "/Applications/ZImage.app")
        let targets = LibraryItemMenu.videoApplications(
            quickTime: quickTime,
            others: [vlc, editor, quickTime],
            editor: editor
        ) { url in
            url.deletingPathExtension().lastPathComponent
        }
        XCTAssertEqual(targets.map(\.name), ["QuickTime Player", "VLC"])
        XCTAssertFalse(targets.contains { $0.isZImage })
    }

    func testSubScanListsImagesAndVideosInsideSubfolders() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child", isDirectory: true)
        try Data().write(to: child.appendingPathComponent("clip.mp4"))
        try Data("nope".utf8).write(to: child.appendingPathComponent("notes.txt"))

        let entries = try FolderListing.list(folder: root, includeSubfolders: true)
        XCTAssertEqual(
            entries.map(\.name),
            ["a.jpg", "b.jpg", "child/clip.mp4", "child/nested.jpg", "wide.jpg"]
        )
        XCTAssertFalse(entries.contains { $0.isDirectory })
        let video = try XCTUnwrap(entries.first { $0.name == "child/clip.mp4" })
        XCTAssertTrue(video.isVideo)
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.name == "child/nested.jpg" }).isVideo)
        XCTAssertEqual(EditorFolderScan.childFolders(of: root).map(\.name), ["child"])
    }

    func testFolderNameFilterMatchesPartOfTheFileName() {
        XCTAssertTrue(FolderNameFilter.matches("Red eye test.jpg", query: "Red"))
        XCTAssertTrue(FolderNameFilter.matches("red-eye-2.JPG", query: " red "))
        XCTAssertFalse(FolderNameFilter.matches("portrait.jpg", query: "Red"))
        XCTAssertTrue(FolderNameFilter.matches("portrait.jpg", query: "   "))
    }

    @MainActor
    func testDiskFolderGridHidesFilesThatDoNotMatchTheName() {
        let model = EditorModel()
        model.folderEntries = [
            FolderEntry(url: URL(fileURLWithPath: "/tmp/a.jpg"), name: "a.jpg", isDirectory: false),
            FolderEntry(url: URL(fileURLWithPath: "/tmp/Red eye test.jpg"), name: "Red eye test.jpg", isDirectory: false),
            FolderEntry(url: URL(fileURLWithPath: "/tmp/red-eye-2.jpg"), name: "red-eye-2.jpg", isDirectory: false),
            FolderEntry(url: URL(fileURLWithPath: "/tmp/child"), name: "child", isDirectory: true),
        ]
        XCTAssertEqual(model.visibleFolderEntries.map(\.name), ["a.jpg", "Red eye test.jpg", "red-eye-2.jpg"])
        model.folderNameQuery = "Red"
        model.findFolderByName()
        XCTAssertEqual(model.visibleFolderEntries.map(\.name), ["Red eye test.jpg", "red-eye-2.jpg"])
        model.clearFolderNameFilter()
        XCTAssertEqual(model.folderNameQuery, "")
        XCTAssertEqual(model.visibleFolderEntries.map(\.name), ["a.jpg", "Red eye test.jpg", "red-eye-2.jpg"])
    }

    func testFolderPreviewQueueDoesTheVisiblePageFirst() {
        let page1 = URL(fileURLWithPath: "/tmp/p001.jpg")
        let page2 = URL(fileURLWithPath: "/tmp/p201.jpg")
        let later = URL(fileURLWithPath: "/tmp/p400.jpg")
        let done: Set<String> = [FolderEntry.cacheKey(for: page1)]
        XCTAssertEqual(
            FolderPreviewQueue.nextURL(visible: [page2], folder: [page1, page2, later], done: done),
            page2
        )
        XCTAssertEqual(
            FolderPreviewQueue.nextURL(visible: [page1], folder: [page1, page2, later], done: done),
            page2
        )
        XCTAssertNil(FolderPreviewQueue.nextURL(visible: [page1], folder: [page1], done: done))
    }

    func testFolderPageRangeOmitsTheTotalUntilTheCountIsKnown() {
        XCTAssertEqual(FolderPage.limit, 200)
        XCTAssertEqual(FolderPage.pageCount(total: 0), 1)
        XCTAssertEqual(FolderPage.pageCount(total: 200), 1)
        XCTAssertEqual(FolderPage.pageCount(total: 201), 2)
        XCTAssertEqual(FolderPage.range(page: 0, countOnPage: 200, total: nil), "1\u{2013}200")
        XCTAssertEqual(FolderPage.range(page: 1, countOnPage: 1, total: 201), "201\u{2013}201 of 201")
        XCTAssertEqual(
            FolderPage.range(page: 1, countOnPage: 200, total: 1_842),
            "201\u{2013}400 of \(1_842.formatted())"
        )
        XCTAssertEqual(FolderPage.range(page: 0, countOnPage: 0, total: 10), "")
    }

    @MainActor
    func testDiskFolderPagerStepsByTwoHundredPhotos() {
        let model = EditorModel()
        func photo(_ index: Int) -> FolderEntry {
            let name = String(format: "p%03d.jpg", index)
            return FolderEntry(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: false)
        }
        let clip = FolderEntry(
            url: URL(fileURLWithPath: "/tmp/clip.mp4"),
            name: "clip.mp4",
            isDirectory: false,
            isVideo: true
        )
        model.folderEntries = (0..<201).map(photo) + [clip]
        XCTAssertEqual(model.folderPhotoCount, 201)
        XCTAssertTrue(model.showsFolderPager)
        XCTAssertEqual(model.folderPagerRange, "1\u{2013}200 of 201")
        XCTAssertEqual(model.pagedFolderEntries.filter { !$0.isVideo }.map(\.name).first, "p000.jpg")
        XCTAssertEqual(model.pagedFolderEntries.filter { !$0.isVideo }.map(\.name).last, "p199.jpg")
        XCTAssertEqual(model.pagedFolderEntries.last?.name, "clip.mp4")
        model.showFolderPage(1)
        XCTAssertEqual(model.pagedFolderEntries.map(\.name), ["p200.jpg"])
        XCTAssertEqual(model.folderPagerRange, "201\u{2013}201 of 201")
        model.showFolderPage(8)
        XCTAssertEqual(model.folderPageIndex, 1)
        model.showFolderPage(1)
        model.folderNameQuery = "p200"
        model.findFolderByName()
        XCTAssertEqual(model.folderPageIndex, 0)
        XCTAssertFalse(model.showsFolderPager)
        XCTAssertEqual(model.visibleFolderEntries.map(\.name), ["p200.jpg"])
        model.clearFolderNameFilter()
        XCTAssertTrue(model.showsFolderPager)
        XCTAssertEqual(model.folderPageIndex, 0)

        model.folderEntries = (0..<200).map(photo) + [clip]
        XCTAssertEqual(model.folderPhotoCount, 200)
        XCTAssertFalse(model.showsFolderPager)
        XCTAssertEqual(model.pagedFolderEntries.count, 201)
    }

    func testTreeListsChildFoldersAndNotTheFilesInsideThem() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let nodes = EditorFolderScan.childFolders(of: root)
        XCTAssertEqual(nodes.map(\.name), ["child"])
        XCTAssertTrue(EditorFolderScan.childFolders(of: nodes[0].url).isEmpty)
        XCTAssertEqual(EditorFolderSpan.clamped(10, available: 1000), 180)
        XCTAssertEqual(EditorFolderSpan.clamped(900, available: 1000), 720)
        XCTAssertEqual(EditorFolderSpan.clamped(400, available: 500), 260)
    }

    func testInspectorSplitKeepsEachPanelAndLeavesTheRestForHistory() {
        XCTAssertEqual(InspectorPanelSpan.resizeAbove(proposed: 240, current: 200, history: 160), 240)
        XCTAssertEqual(
            InspectorPanelSpan.resizeAbove(proposed: 10, current: 200, history: 160),
            InspectorPanelSpan.minimum
        )
        XCTAssertEqual(
            InspectorPanelSpan.resizeAbove(proposed: 500, current: 200, history: 160),
            200 + 160 - InspectorPanelSpan.historyMinimum
        )

        let preferred = InspectorHeights(tone: 200, geometry: 180, eyedropper: 150)
        XCTAssertEqual(InspectorPanelSpan.fitted(preferred, available: 800), preferred)
        let tight = InspectorPanelSpan.fitted(preferred, available: InspectorPanelSpan.minimum * 3 + InspectorPanelSpan.historyMinimum)
        XCTAssertEqual(tight.tone, InspectorPanelSpan.minimum, accuracy: 0.01)
        XCTAssertEqual(tight.geometry, InspectorPanelSpan.minimum, accuracy: 0.01)
        XCTAssertEqual(tight.eyedropper, InspectorPanelSpan.minimum, accuracy: 0.01)
        let cramped = InspectorPanelSpan.fitted(preferred, available: 400)
        XCTAssertGreaterThanOrEqual(cramped.tone, InspectorPanelSpan.minimum)
        XCTAssertGreaterThanOrEqual(cramped.geometry, InspectorPanelSpan.minimum)
        XCTAssertGreaterThanOrEqual(cramped.eyedropper, InspectorPanelSpan.minimum)
        XCTAssertEqual(
            cramped.tone + cramped.geometry + cramped.eyedropper,
            400 - InspectorPanelSpan.historyMinimum,
            accuracy: 0.01
        )
        XCTAssertEqual(InspectorMetrics.heightFactor, 0.56, accuracy: 0.001)
        XCTAssertEqual(InspectorMetrics.compressed(100), 56, accuracy: 0.001)
        XCTAssertEqual(InspectorMetrics.stackSpacing, 5.6, accuracy: 0.001)
        XCTAssertEqual(InspectorMetrics.panelTopPadding, 8)
        XCTAssertEqual(InspectorMetrics.panelBottomPadding, 8)
        XCTAssertEqual(InspectorPanelSpan.dividerHit, 4)
        XCTAssertEqual(InspectorPanelSpan.chrome, 12)
        XCTAssertEqual(InspectorPanelSpan.halfBlank(200, content: 120), 160, accuracy: 0.001)
        XCTAssertEqual(InspectorPanelSpan.halfBlank(100, content: 150), 100, accuracy: 0.001)

        var folded = InspectorCollapse()
        folded.tone = true
        let withToneFolded = InspectorPanelSpan.fitted(preferred, available: 800, collapsed: folded)
        XCTAssertEqual(withToneFolded.tone, InspectorPanelSpan.collapsedHeight, accuracy: 0.01)
        XCTAssertEqual(withToneFolded.geometry, preferred.geometry, accuracy: 0.01)
        XCTAssertEqual(withToneFolded.eyedropper, preferred.eyedropper, accuracy: 0.01)
        XCTAssertEqual(InspectorDisclosure.symbol(collapsed: true), "chevron.up")
        XCTAssertEqual(InspectorDisclosure.symbol(collapsed: false), "chevron.down")
    }

    func testLRUKeepsTheNewestPreviewAndWipeClearsTheDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-lru-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.jpg")
        let second = root.appendingPathComponent("second.jpg")
        try writeJPEG(width: 32, height: 32, to: first)
        try writeJPEG(width: 32, height: 32, to: second)

        _ = try FolderPreviewCache.ensureJPEG(for: first)
        _ = try FolderPreviewCache.ensureJPEG(for: second)
        XCTAssertEqual(FolderPreviewCache.stamps().count, 2)

        FolderPreviewCache.byteCap = 1
        _ = try FolderPreviewCache.ensureJPEG(for: first)
        let remaining = FolderPreviewCache.stamps()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.name, FolderPreviewCache.fileName(for: first))

        FolderPreviewCache.wipe()
        XCTAssertEqual(FolderPreviewCache.stamps().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: FolderPreviewCache.directory.path))
    }

    @MainActor
    func testLastSelectedFolderReturnsOnTheNextLaunch() throws {
        let suite = "ZImage.lastFolder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try makeFixture()
        let child = root.appendingPathComponent("child", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let model = EditorModel()
        model.folderBookmarkDefaults = defaults
        model.openFolder(at: root)
        model.selectBrowseFolder(child)

        let again = EditorModel()
        again.folderBookmarkDefaults = defaults
        again.restoreLastFolder()
        XCTAssertEqual(FolderEntry.cacheKey(for: try XCTUnwrap(again.browseRoot)), FolderEntry.cacheKey(for: root))
        XCTAssertEqual(FolderEntry.cacheKey(for: try XCTUnwrap(again.folderURL)), FolderEntry.cacheKey(for: child))
        XCTAssertTrue(again.showsFolderGrid)

        let covered = EditorModel()
        covered.folderBookmarkDefaults = defaults
        covered.openSecurityScopedFile(at: child.appendingPathComponent("nested.jpg"))
        covered.restoreLastFolder()
        XCTAssertFalse(covered.showsFolderGrid)
        XCTAssertEqual(covered.browseRoot.map(FolderEntry.cacheKey(for:)), FolderEntry.cacheKey(for: root))

        let selection = try outside.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(selection, forKey: EditorFolderBookmark.selectionKey)
        let fallback = EditorModel()
        fallback.folderBookmarkDefaults = defaults
        fallback.restoreLastFolder()
        XCTAssertEqual(FolderEntry.cacheKey(for: try XCTUnwrap(fallback.browseRoot)), FolderEntry.cacheKey(for: root))
        XCTAssertEqual(FolderEntry.cacheKey(for: try XCTUnwrap(fallback.folderURL)), FolderEntry.cacheKey(for: root))

        try FileManager.default.removeItem(at: root)
        let gone = EditorModel()
        gone.folderBookmarkDefaults = defaults
        gone.restoreLastFolder()
        XCTAssertNil(gone.browseRoot)
        XCTAssertEqual(gone.folderMessage, EditorFolderBookmark.unavailableMessage)
        XCTAssertTrue(gone.showsFolderGrid)
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-folder-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writeJPEG(width: 64, height: 40, to: root.appendingPathComponent("a.jpg"))
        try writeJPEG(width: 40, height: 64, to: root.appendingPathComponent("b.jpg"))
        try writeJPEG(width: 1800, height: 400, to: root.appendingPathComponent("wide.jpg"))
        try writeJPEG(width: 20, height: 20, to: child.appendingPathComponent("nested.jpg"))
        try Data("notes".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("%PDF-1.1\n".utf8).write(to: root.appendingPathComponent("page.pdf"))
        try Data([0x46, 0x4F, 0x56, 0x62]).write(to: root.appendingPathComponent("sample.x3f"))
        return root
    }

    private func writeJPEG(width: Int, height: Int, to url: URL) throws {
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
            throw FolderPreviewError.writeFailed(url.lastPathComponent)
        }
        context.setFillColor(CGColor(red: 0.25, green: 0.45, blue: 0.65, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw FolderPreviewError.writeFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FolderPreviewError.writeFailed(url.lastPathComponent)
        }
    }

    private func pixelLongEdge(_ url: URL) throws -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("Missing JPEG properties at \(url.lastPathComponent)")
            throw FolderPreviewError.unreadable(url.lastPathComponent)
        }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return max(width, height)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("Timed out waiting for the folder browser")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
