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
        XCTAssertEqual(entries.map(\.name), ["child", "a.jpg", "b.jpg", "sample.x3f", "wide.jpg"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, false, false, false, false])
        let names = Set(entries.map(\.name))
        XCTAssertFalse(names.contains("nested.jpg"))
        XCTAssertFalse(names.contains("notes.txt"))
        XCTAssertFalse(names.contains("page.pdf"))
        XCTAssertTrue(names.contains("sample.x3f"))

        let images = entries.filter { !$0.isDirectory && $0.url.pathExtension.lowercased() == "jpg" }
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
        try await waitUntil { model.folderEntries.map(\.name) == ["child", "a.jpg", "b.jpg", "sample.x3f", "wide.jpg"] }
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
        XCTAssertEqual(entries.map(\.name), ["child", "a.jpg", "b.jpg", "clip.mp4", "sample.x3f", "wide.jpg"])
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
            ["a.jpg", "b.jpg", "child/clip.mp4", "child/nested.jpg", "sample.x3f", "wide.jpg"]
        )
        XCTAssertFalse(entries.contains { $0.isDirectory })
        let video = try XCTUnwrap(entries.first { $0.name == "child/clip.mp4" })
        XCTAssertTrue(video.isVideo)
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.name == "child/nested.jpg" }).isVideo)
        XCTAssertEqual(EditorFolderScan.childFolders(of: root).map(\.name), ["child"])
    }

    func testX3FCellUsesTheEmbeddedPreview() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-x3f-cell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("plain.x3f")
        try Data(folderPlainX3F(columns: 400, rows: 10)).write(to: url)

        let entries = try FolderListing.list(folder: root)
        XCTAssertEqual(entries.map(\.name), ["plain.x3f"])
        let jpeg = try FolderPreviewCache.ensureJPEG(for: entries[0].url)
        let edge = try pixelLongEdge(jpeg)
        XCTAssertGreaterThan(edge, 200)
        XCTAssertLessThanOrEqual(edge, FolderPreviewCache.maxLongEdge)
    }

    @MainActor
    func testRenameKeepsTheFileInItsFolderAndUpdatesTheSelection() throws {
        XCTAssertEqual(LibraryItemMenu.rename, "Rename")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Left-Right.tiff")
        let other = root.appendingPathComponent("kept.tiff")
        try Data("merged".utf8).write(to: source)
        try Data("other".utf8).write(to: other)
        let entry = FolderEntry(url: source, name: source.lastPathComponent, isDirectory: false)
        let neighbor = FolderEntry(url: other, name: other.lastPathComponent, isDirectory: false)
        let model = EditorModel()
        model.folderEntries = [entry, neighbor]
        model.selectFolderEntry(entry, shift: false)

        model.renameFolderEntry(entry, to: "  panorama.tiff  ")
        let renamed = root.appendingPathComponent("panorama.tiff")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(model.folderEntries.map(\.name), ["panorama.tiff", "kept.tiff"])
        XCTAssertEqual(model.selectedFolderKey, FolderEntry.cacheKey(for: renamed))
        XCTAssertEqual(model.folderRotateNote, "Renamed to panorama.tiff.")
        XCTAssertEqual(try Data(contentsOf: renamed), Data("merged".utf8))

        let current = try XCTUnwrap(model.folderEntries.first)
        model.renameFolderEntry(current, to: "kept.tiff")
        XCTAssertEqual(model.folderRotateNote, "A file named kept.tiff is already in this folder.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(try Data(contentsOf: other), Data("other".utf8))

        model.renameFolderEntry(current, to: "panorama.tiff")
        XCTAssertEqual(model.folderEntries.map(\.name), ["panorama.tiff", "kept.tiff"])

        model.renameFolderEntry(current, to: "Panorama.tiff")
        let cased = root.appendingPathComponent("Panorama.tiff")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cased.path))
        XCTAssertEqual(model.folderEntries.first?.name, "Panorama.tiff")

        XCTAssertEqual(FileRename.cleaned(""), .failure(.empty))
        XCTAssertEqual(FileRename.cleaned("a/b.tiff"), .failure(.invalid))
        XCTAssertEqual(FileRename.cleaned("a:b.tiff"), .failure(.invalid))
        XCTAssertEqual(
            FileRename.relocatedPath("Photos/Blogger 1600/Left-Right.tiff", fileName: "panorama.tiff"),
            "Photos/Blogger 1600/panorama.tiff"
        )
    }

    func testDiskMoveLandsUnderTheOpenedRootUnlessItIsASubfolder() throws {
        let root = URL(fileURLWithPath: "/tmp/Pictures")
        let open = root.appendingPathComponent("Vacation")
        let photo = open.appendingPathComponent("a.jpg")
        let nested = open.appendingPathComponent("Day").appendingPathComponent("b.jpg")
        let outside = root.appendingPathComponent("Other").appendingPathComponent("c.jpg")
        XCTAssertEqual(
            FolderMove.diskDestination(root: root, openFolder: open, file: photo, folderName: " Album ", subfolder: false)?.path,
            root.appendingPathComponent("Album").path
        )
        XCTAssertEqual(
            FolderMove.diskDestination(root: root, openFolder: open, file: nested, folderName: "Album", subfolder: true)?.path,
            open.appendingPathComponent("Album").path
        )
        XCTAssertNil(FolderMove.diskDestination(root: root, openFolder: open, file: outside, folderName: "Album", subfolder: false))
        XCTAssertNil(FolderMove.diskDestination(root: root, openFolder: open, file: photo, folderName: "_Removed", subfolder: false))
        XCTAssertNil(FolderMove.diskDestination(root: root, openFolder: open, file: photo, folderName: "A/B", subfolder: true))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-disk-move-\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = directory.appendingPathComponent("Vacation", isDirectory: true)
        let album = directory.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = sourceFolder.appendingPathComponent("a.jpg")
        let second = sourceFolder.appendingPathComponent("b.jpg")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        try Data("kept".utf8).write(to: album.appendingPathComponent("a.jpg"))
        let moved = FolderMove.perform(files: [
            (first, album),
            (second, album),
            (album.appendingPathComponent("a.jpg"), album),
        ])
        XCTAssertEqual(moved.moved, 2)
        XCTAssertEqual(moved.stayed, 1)
        XCTAssertEqual(try Data(contentsOf: album.appendingPathComponent("a.jpg")), Data("kept".utf8))
        XCTAssertEqual(try Data(contentsOf: album.appendingPathComponent("a-2.jpg")), Data("a".utf8))
        XCTAssertEqual(try Data(contentsOf: album.appendingPathComponent("b.jpg")), Data("b".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    @MainActor
    func testDiskMoveRefreshesTheFolderAndTheTree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-disk-tree-\(UUID().uuidString)", isDirectory: true)
        let vacation = root.appendingPathComponent("Vacation", isDirectory: true)
        try FileManager.default.createDirectory(at: vacation, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = vacation.appendingPathComponent("a.jpg")
        try Data("a".utf8).write(to: photo)
        let model = EditorModel()
        model.browseRoot = root
        model.folderURL = vacation
        let entry = FolderEntry(url: photo, name: photo.lastPathComponent, isDirectory: false)
        model.folderEntries = [entry]
        model.selectFolderEntry(entry, shift: false)
        model.moveSelectedFolderFiles(to: "Album", subfolder: false)
        try await waitUntil { model.folderRotateNote == "Moved 1 file to Album." }
        let dest = root.appendingPathComponent("Album").appendingPathComponent("a.jpg")
        XCTAssertEqual(try Data(contentsOf: dest), Data("a".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertEqual(model.folderTreeRevision, 1)
        XCTAssertEqual(model.folderTreeParents.map { FolderEntry.cacheKey(for: $0) }, [FolderEntry.cacheKey(for: root)])
        XCTAssertFalse(model.folderRotateBusy)
        try await waitUntil { model.folderListingReady && !model.folderEntries.contains { $0.name == "a.jpg" } }

        let again = vacation.appendingPathComponent("b.jpg")
        try Data("b".utf8).write(to: again)
        let second = FolderEntry(url: again, name: again.lastPathComponent, isDirectory: false)
        model.folderEntries.append(second)
        model.selectFolderEntry(second, shift: false)
        model.moveSelectedFolderFiles(to: "Album", subfolder: true)
        try await waitUntil { model.folderRotateNote == "Moved 1 file to Vacation/Album." }
        XCTAssertEqual(try Data(contentsOf: vacation.appendingPathComponent("Album").appendingPathComponent("b.jpg")), Data("b".utf8))
        XCTAssertEqual(model.folderTreeRevision, 2)
        XCTAssertEqual(model.folderTreeParents.map { FolderEntry.cacheKey(for: $0) }, [FolderEntry.cacheKey(for: vacation)])
    }

    @MainActor
    func testFolderRenameKeepsSpacesAndRefusesAShelfACollisionAndASymlink() throws {
        XCTAssertEqual(FolderRename.cleaned("  Trip Album  "), .success("Trip Album"))
        XCTAssertEqual(FolderRename.cleaned("   "), .failure(.empty))
        XCTAssertEqual(FolderRename.cleaned("A/B"), .failure(.invalid))
        XCTAssertEqual(FolderRename.cleaned("A:B"), .failure(.invalid))
        XCTAssertEqual(FolderRename.cleaned("_Review"), .failure(.invalid))
        XCTAssertEqual(FolderRename.cleaned("_Removed"), .failure(.invalid))
        XCTAssertEqual(FolderRename.cleaned("_Duplicates"), .failure(.invalid))
        XCTAssertFalse(FolderRename.catalogAllows("Photos"))
        XCTAssertFalse(FolderRename.catalogAllows("Photos/_Removed"))
        XCTAssertFalse(FolderRename.catalogAllows("Photos/_Duplicates"))
        XCTAssertFalse(FolderRename.catalogAllows("Photos/_Review"))
        XCTAssertTrue(FolderRename.catalogAllows("Photos/2024/_Removed"))
        XCTAssertFalse(FolderRename.catalogAllows("Photos/../Secret"))
        XCTAssertEqual(FolderRename.keptMessage(relative: "Photos"), "Photos stays at the top of the library.")
        XCTAssertEqual(FolderRename.keptMessage(relative: "Photos/_Removed"), "That folder keeps its name.")
        XCTAssertEqual(
            FolderRename.shiftedRelative("Photos/Album/a.jpg", from: "Photos/Album", to: "Photos/Trip Album"),
            "Photos/Trip Album/a.jpg"
        )
        XCTAssertEqual(
            FolderRename.shiftedRelative("Photos/Album", from: "Photos/Album", to: "Photos/Trip Album"),
            "Photos/Trip Album"
        )
        XCTAssertNil(FolderRename.shiftedRelative("Photos/Album2/b.jpg", from: "Photos/Album", to: "Photos/Trip Album"))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-folder-rename-\(UUID().uuidString)", isDirectory: true)
        let album = root.appendingPathComponent("Album", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        let real = root.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = album.appendingPathComponent("a.jpg")
        try Data("a".utf8).write(to: photo)
        try Data("b".utf8).write(to: other.appendingPathComponent("b.jpg"))
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(FolderRename.perform(source: album, typed: "Other"), .failure(.taken))
        XCTAssertEqual(try Data(contentsOf: photo), Data("a".utf8))
        XCTAssertEqual(try Data(contentsOf: other.appendingPathComponent("b.jpg")), Data("b".utf8))
        XCTAssertEqual(FolderRename.perform(source: link, typed: "Away"), .failure(.link))
        XCTAssertEqual(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))

        let cased = try XCTUnwrap(try? FolderRename.perform(source: album, typed: "album").get())
        XCTAssertEqual(cased.lastPathComponent, "album")
        XCTAssertEqual(try Data(contentsOf: cased.appendingPathComponent("a.jpg")), Data("a".utf8))
        let spaced = try XCTUnwrap(try? FolderRename.perform(source: cased, typed: "  Trip Album  ").get())
        XCTAssertEqual(spaced.lastPathComponent, "Trip Album")
        XCTAssertEqual(try Data(contentsOf: spaced.appendingPathComponent("a.jpg")), Data("a".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: album.path))
    }

    @MainActor
    func testRenameBrowseFolderUpdatesTheOpenFolderAndTheSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-browse-rename-\(UUID().uuidString)", isDirectory: true)
        let album = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = album.appendingPathComponent("a.jpg")
        try writeJPEG(width: 8, height: 8, to: photo)
        let bytes = try Data(contentsOf: photo)
        let model = EditorModel()
        model.browseRoot = root
        model.folderURL = album
        let entry = FolderEntry(url: photo, name: photo.lastPathComponent, isDirectory: false)
        model.folderEntries = [entry]
        model.selectFolderEntry(entry, shift: false)

        model.renameBrowseFolder(album, to: "  Trip Album  ")
        let dest = root.appendingPathComponent("Trip Album", isDirectory: true)
        let moved = dest.appendingPathComponent("a.jpg")
        XCTAssertEqual(try Data(contentsOf: moved), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertEqual(model.folderURL.map { FolderEntry.cacheKey(for: $0) }, FolderEntry.cacheKey(for: dest))
        XCTAssertEqual(model.folderRotateNote, "Renamed to Trip Album.")
        XCTAssertEqual(model.folderTreeRevision, 1)
        XCTAssertEqual(model.folderTreeParents.map { FolderEntry.cacheKey(for: $0) }, [FolderEntry.cacheKey(for: root)])
        try await waitUntil { model.folderListingReady && model.folderEntries.contains { $0.name == "a.jpg" } }
        XCTAssertEqual(model.selectedFolderKey, FolderEntry.cacheKey(for: moved))
        XCTAssertFalse(model.folderRotateBusy)

        let kept = root.appendingPathComponent("Kept", isDirectory: true)
        model.followLibraryFolderRename = { _, _ in .updated }
        model.renameBrowseFolder(dest, to: "Kept")
        try await waitUntil { model.folderRotateNote == "Renamed to Kept." && !model.folderRotateBusy }
        XCTAssertEqual(try Data(contentsOf: kept.appendingPathComponent("a.jpg")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertEqual(model.folderURL.map { FolderEntry.cacheKey(for: $0) }, FolderEntry.cacheKey(for: kept))
    }

    @MainActor
    func testRenameBrowseFolderMovesBackWhenTheCatalogCannotFollow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-browse-restore-\(UUID().uuidString)", isDirectory: true)
        let album = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = album.appendingPathComponent("a.jpg")
        try Data("a".utf8).write(to: photo)
        let model = EditorModel()
        model.browseRoot = root
        model.folderURL = album
        model.libraryRelativePath = { _ in "Photos/Album" }
        model.followLibraryFolderRename = { _, _ in .failed }

        model.renameBrowseFolder(album, to: "Trip")
        try await waitUntil {
            model.folderRotateNote == "The folder stayed as it is. The catalog could not follow the new name."
                && !model.folderRotateBusy
        }
        XCTAssertEqual(try Data(contentsOf: photo), Data("a".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Trip").path))
        XCTAssertEqual(model.folderURL.map { FolderEntry.cacheKey(for: $0) }, FolderEntry.cacheKey(for: album))
        XCTAssertEqual(model.folderTreeRevision, 0)
    }

    @MainActor
    func testRenameBrowseFolderRefusesPhotosAndRenamesTheOpenedRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-browse-root-\(UUID().uuidString)", isDirectory: true)
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let renamedName = "Pictures-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent(renamedName))
        }
        try Data("a".utf8).write(to: photos.appendingPathComponent("a.jpg"))
        let model = EditorModel()
        model.browseRoot = root
        model.folderURL = photos
        model.libraryRelativePath = { url in
            url.lastPathComponent == "Photos" ? "Photos" : nil
        }
        model.renameBrowseFolder(photos, to: "Library")
        XCTAssertEqual(model.folderRotateNote, "Photos stays at the top of the library.")
        XCTAssertEqual(try Data(contentsOf: photos.appendingPathComponent("a.jpg")), Data("a".utf8))
        XCTAssertEqual(model.folderTreeRevision, 0)

        model.folderURL = root
        model.libraryRelativePath = { _ in nil }
        model.renameBrowseFolder(root, to: renamedName)
        let renamed = root.deletingLastPathComponent().appendingPathComponent(renamedName, isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: renamed.appendingPathComponent("Photos").appendingPathComponent("a.jpg")), Data("a".utf8))
        XCTAssertEqual(model.browseRoot.map { FolderEntry.cacheKey(for: $0) }, FolderEntry.cacheKey(for: renamed))
        XCTAssertEqual(model.folderURL.map { FolderEntry.cacheKey(for: $0) }, FolderEntry.cacheKey(for: renamed))
        XCTAssertEqual(model.folderRotateNote, "Renamed to \(renamedName).")
        XCTAssertEqual(model.folderTreeRevision, 0)
        try await waitUntil { model.folderListingReady && model.folderEntries.contains { $0.name == "Photos" } }
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

    func testFolderHeadingEndsWithTheImageCount() {
        XCTAssertEqual(FolderPage.heading(folder: "Photos/Trips", photoCount: nil), "Photos/Trips")
        XCTAssertEqual(FolderPage.heading(folder: "Photos/Trips", photoCount: 12_345), "Photos/Trips (12345)")
        XCTAssertEqual(FolderPage.heading(folder: "Photos", photoCount: 0), "Photos (0)")
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
    func testBuildPreviewsSkipsAPhotoThatAlreadyHasOne() async throws {
        XCTAssertEqual(FolderPreviewBuild.filterNote, "Clear the name filter before building previews.")
        XCTAssertEqual(FolderPreviewBuild.finished(photos: 0, built: 0, missed: 0), "This folder has no photos.")
        XCTAssertEqual(FolderPreviewBuild.finished(photos: 2, built: 0, missed: 0), "Every photo in this folder already has a preview.")
        XCTAssertEqual(FolderPreviewBuild.finished(photos: 2, built: 1, missed: 0), "Built 1 preview.")
        XCTAssertEqual(FolderPreviewBuild.finished(photos: 3, built: 2, missed: 0), "Built 2 previews.")
        XCTAssertEqual(FolderPreviewBuild.finished(photos: 2, built: 0, missed: 1), "No preview could be read.")
        XCTAssertEqual(
            FolderPreviewBuild.finished(photos: 3, built: 1, missed: 1),
            "Built 1 preview. 1 photo could not be read."
        )
        XCTAssertEqual(
            FolderPreviewBuild.progress(done: 0, total: 3),
            "Building previews. \(0.formatted()) of \(3.formatted())."
        )
        let only = MacCheckpoint.thumbnailOnlyBody(Data([0xFF, 0xD8]))
        let onlyText = String(decoding: only, as: UTF8.self)
        XCTAssertTrue(onlyText.contains("thumbnail"))
        XCTAssertFalse(onlyText.contains("dhash"))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keptURL = root.appendingPathComponent("kept.jpg")
        let missingURL = root.appendingPathComponent("missing.jpg")
        let badURL = root.appendingPathComponent("bad.jpg")
        let videoURL = root.appendingPathComponent("clip.mov")
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writeJPEG(width: 16, height: 16, to: keptURL)
        try writeJPEG(width: 16, height: 16, to: missingURL)
        try Data("not a jpeg".utf8).write(to: badURL)
        try Data("not a movie".utf8).write(to: videoURL)
        _ = try FolderPreviewCache.ensureJPEG(for: keptURL)
        XCTAssertNil(FolderPreviewFacts.body(for: badURL))
        let facts = try XCTUnwrap(FolderPreviewFacts.body(for: missingURL))
        XCTAssertTrue(String(decoding: facts, as: UTF8.self).contains("thumbnail"))
        let keptJPEG = FolderPreviewCache.directory.appendingPathComponent(FolderPreviewCache.fileName(for: keptURL))
        let keptStamp = try keptJPEG.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let model = EditorModel()
        model.folderURL = root
        model.folderListingReady = true
        model.folderEntries = [
            FolderEntry(url: child, name: "child", isDirectory: true),
            FolderEntry(url: keptURL, name: "kept.jpg", isDirectory: false),
            FolderEntry(url: missingURL, name: "missing.jpg", isDirectory: false),
            FolderEntry(url: badURL, name: "bad.jpg", isDirectory: false),
            FolderEntry(url: videoURL, name: "clip.mov", isDirectory: false, isVideo: true),
        ]
        model.folderNameFilter = "red"
        await model.buildMissingFolderPreviews()
        XCTAssertEqual(model.folderPreviewBuildNote, FolderPreviewBuild.filterNote)
        XCTAssertFalse(FolderPreviewCache.hasJPEG(for: missingURL))

        model.folderNameFilter = ""
        await model.buildMissingFolderPreviews()
        XCTAssertFalse(model.folderPreviewBuildBusy)
        XCTAssertEqual(model.folderPreviewBuildNote, FolderPreviewBuild.finished(photos: 3, built: 1, missed: 1))
        XCTAssertTrue(FolderPreviewCache.hasJPEG(for: missingURL))
        XCTAssertFalse(FolderPreviewCache.hasJPEG(for: badURL))
        XCTAssertFalse(FolderPreviewCache.hasJPEG(for: videoURL))
        let missing = try XCTUnwrap(model.folderEntries.first { $0.name == "missing.jpg" })
        XCTAssertNotNil(model.previewJPEG(for: missing))
        let after = try keptJPEG.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(keptStamp, after)

        model.folderEntries.removeAll { $0.name == "bad.jpg" }
        await model.buildMissingFolderPreviews()
        XCTAssertEqual(model.folderPreviewBuildNote, "Every photo in this folder already has a preview.")
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

    /// A type-2 format-3 preview. Rows are padded to 4 bytes. The color is constant.
    private func folderPlainX3F(columns: Int, rows: Int) -> Data {
        let packed = columns * 3
        let stride = (packed + 3) & ~3
        var payload = Data(count: stride * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let at = row * stride + column * 3
                payload[at] = 20
                payload[at + 1] = 40
                payload[at + 2] = 60
            }
        }
        var header = Data("SECi".utf8)
        header.append(contentsOf: folderLE(0))
        header.append(contentsOf: folderLE(2))
        header.append(contentsOf: folderLE(3))
        header.append(contentsOf: folderLE(UInt32(columns)))
        header.append(contentsOf: folderLE(UInt32(rows)))
        header.append(contentsOf: folderLE(UInt32(stride)))
        var body = Data("FOVb".utf8)
        let offset = UInt32(body.count)
        body.append(header)
        body.append(payload)
        let length = UInt32(header.count + payload.count)
        let directory = UInt32(body.count)
        body.append(contentsOf: Data("SECd".utf8))
        body.append(contentsOf: folderLE(0))
        body.append(contentsOf: folderLE(1))
        body.append(contentsOf: folderLE(offset))
        body.append(contentsOf: folderLE(length))
        body.append(contentsOf: Data("IMA2".utf8))
        body.append(contentsOf: folderLE(directory))
        return body
    }

    private func folderLE(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 4)
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
