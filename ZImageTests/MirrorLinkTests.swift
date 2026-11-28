import XCTest
@testable import ZImager

@MainActor
final class MirrorLinkTests: XCTestCase {
    func testOldServerJSONStillLoads() throws {
        let json = """
        [{"id":"a","name":"DS423","nasPath":"/volume1/a","bookmark":"","host":"192.168.1.147"}]
        """.data(using: .utf8)!
        let rows = try JSONDecoder().decode([HelperServerRecord].self, from: json)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].duty, "")
        XCTAssertEqual(rows[0].follows, "")
        let again = try JSONDecoder().decode([HelperServerRecord].self, from: JSONEncoder().encode(rows))
        XCTAssertEqual(again, rows)
    }

    func testLinkAndUnlink() {
        let rows = [
            HelperServerRecord(id: "main", name: "DS423", nasPath: "/volume1/a", bookmark: Data(), host: "192.168.1.147"),
            HelperServerRecord(id: "mirror", name: "DS124", nasPath: "/volume1/b", bookmark: Data(), host: "192.168.1.34"),
        ]
        let linked = MirrorRoster.link(mainID: "main", mirrorID: "mirror", rows: rows)
        XCTAssertEqual(linked?[0].duty, MirrorRoster.main)
        XCTAssertEqual(linked?[0].follows, "")
        XCTAssertEqual(linked?[1].duty, MirrorRoster.mirror)
        XCTAssertEqual(linked?[1].follows, "main")
        XCTAssertNil(MirrorRoster.link(mainID: "main", mirrorID: "main", rows: rows))
        let cleared = MirrorRoster.unlink(linked ?? [])
        XCTAssertEqual(cleared.map(\.duty), ["", ""])
        XCTAssertEqual(cleared.map(\.follows), ["", ""])
    }

    func testMenuTitleNamesTheDuty() {
        let row = HelperServerRecord(id: "m", name: "DS124", nasPath: "/volume1/b", bookmark: Data(), host: "192.168.1.34", duty: MirrorRoster.mirror)
        XCTAssertEqual(MirrorRoster.menuTitle(row, active: true), "DS124 · Mirror ✓")
        XCTAssertEqual(MirrorRoster.menuTitle(row, active: false), "DS124 · Mirror")
    }

    func testBesideNameAndRecoveredBorder() {
        XCTAssertEqual(MirrorDiff.besideName("photo.jpg", taken: []), "photo.jpg")
        XCTAssertEqual(MirrorDiff.besideName("photo.jpg", taken: ["photo.jpg"]), "photo-2.jpg")
        XCTAssertEqual(MirrorDiff.besideName("photo.jpg", taken: ["photo.jpg", "photo-2.jpg"]), "photo-3.jpg")
        XCTAssertEqual(
            MirrorDiff.besidePath("Photos/day/photo.jpg", taken: []),
            "Photos/day/photo.jpg"
        )
        XCTAssertEqual(
            MirrorDiff.besidePath("Photos/day/photo.jpg", taken: ["Photos/day/photo.jpg"]),
            "Photos/day/photo-2.jpg"
        )
        XCTAssertEqual(
            MirrorDiff.besideSidecar(
                photoSource: "Photos/day/photo.jpg",
                photoDest: "Photos/day/photo-2.jpg",
                sidecar: "Photos/day/photo.zflat"
            ),
            "Photos/day/photo-2.zflat"
        )
        let kept = MirrorDiff.onlyOnMirror(
            main: ["Photos/day/photo-2.jpg"],
            mirror: ["Photos/day/photo.jpg"],
            recovered: ["Photos/day/photo.jpg": "Photos/day/photo-2.jpg"]
        )
        XCTAssertTrue(kept.isEmpty)
        let missing = MirrorDiff.onlyOnMirror(
            main: ["Photos/day/photo.jpg"],
            mirror: ["Photos/day/other.jpg"],
            recovered: [:]
        )
        XCTAssertEqual(missing, ["Photos/day/other.jpg"])
    }

    func testRemoveFromMainParksTheMirrorOriginal() {
        let mirror = "Photos/1980/Ansel Adams/photo.jpg"
        let beside = "Photos/1980/Ansel Adams/photo-2.jpg"
        let other = "Photos/day/other.jpg"
        let recovered = [mirror: beside, other: "Photos/day/other-2.jpg"]
        XCTAssertEqual(MirrorLedger.pathsToPark(main: beside, recovered: recovered), [beside, mirror])
        XCTAssertEqual(MirrorLedger.pathsToPark(main: mirror, recovered: recovered), [mirror])
        XCTAssertEqual(
            MirrorLedger.forgetting(beside, in: recovered),
            [other: "Photos/day/other-2.jpg"]
        )
        XCTAssertTrue(MirrorLedger.forgetting(mirror, in: recovered)[mirror] == nil)
        XCTAssertEqual(MirrorLedger.pathsToPark(main: "Photos/_Removed/photo.jpg", recovered: recovered), [])
        XCTAssertEqual(MirrorLedger.pathsToPark(main: "Photos/../photo.jpg", recovered: [:]), [])
    }

    func testRecoveredFileIsTheOneEditInLibraryOpens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-landed-\(UUID().uuidString)", isDirectory: true)
        let folder = "Photos/day"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mirror = folder + "/photo.jpg"
        let beside = folder + "/photo-2.jpg"
        let recovered = [mirror: beside]
        XCTAssertNil(MirrorDiff.mainPath(mirror: mirror, root: root, recovered: recovered))
        try Data("copy".utf8).write(to: root.appendingPathComponent(beside))
        XCTAssertEqual(MirrorDiff.mainPath(mirror: mirror, root: root, recovered: recovered), beside)
        XCTAssertEqual(LibrarySwitch.folderToKeep((beside as NSString).deletingLastPathComponent), folder)
        try Data("main".utf8).write(to: root.appendingPathComponent(mirror))
        XCTAssertEqual(MirrorDiff.mainPath(mirror: mirror, root: root, recovered: recovered), mirror)
        XCTAssertNil(MirrorDiff.mainPath(mirror: mirror, root: root, recovered: [mirror: "Photos/../photo-2.jpg"]))
        XCTAssertNil(MirrorDiff.mainPath(mirror: mirror, root: root, recovered: [mirror: "Notes/photo-2.jpg"]))
    }

    func testFilesToCopyUsesSize() {
        let list = MirrorDiff.filesToCopy(
            mainBytes: ["Photos/a.jpg": 10, "Photos/b.jpg": 4, "Notes/c.jpg": 1],
            mirrorBytes: ["Photos/a.jpg": 10, "Photos/b.jpg": 9]
        )
        XCTAssertEqual(list, ["Photos/b.jpg"])
    }

    func testConfigRoleLine() {
        let text = "listen: \"0.0.0.0:8742\"\nlibrary_root_local: \"/volume1/lib\"\n"
        let mirror = MirrorConfigText.setting(role: MirrorRoster.mirror, in: text)
        XCTAssertTrue(mirror.contains("role: \"mirror\"\n"))
        XCTAssertTrue(mirror.contains("library_root_local"))
        let cleared = MirrorConfigText.setting(role: "", in: mirror)
        XCTAssertFalse(cleared.contains("role:"))
        XCTAssertTrue(cleared.hasSuffix("\n"))
    }

    func testRoleIsNotWrittenUntilTheHelperMatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-role-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent(".zimage/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".zimage/config.yaml")
        try "library_root_local: \"/volume1/lib\"\n".write(to: config, atomically: true, encoding: .utf8)
        try "1.8.6\n".write(to: bin.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MirrorConfigFile.apply(role: MirrorRoster.mirror, libraryRoot: root), .skippedOldHelper)
        let unchanged = try String(contentsOf: config, encoding: .utf8)
        XCTAssertFalse(unchanged.contains("role:"))
        try (HelperRelease.version + "\n").write(to: bin.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MirrorConfigFile.apply(role: MirrorRoster.mirror, libraryRoot: root), .updated)
        let written = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(written.contains("role: \"mirror\""))
        XCTAssertEqual(MirrorConfigFile.apply(role: "", libraryRoot: root), .updated)
        let cleared = try String(contentsOf: config, encoding: .utf8)
        XCTAssertFalse(cleared.contains("role:"))
    }

    func testCopyBesideLeavesTheOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-copy-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        let folder = "Photos/day"
        try FileManager.default.createDirectory(at: source.appendingPathComponent(folder), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest.appendingPathComponent(folder), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = folder + "/photo.jpg"
        try Data("main".utf8).write(to: dest.appendingPathComponent(relative))
        try Data("mirror".utf8).write(to: source.appendingPathComponent(relative))
        let edits = source.appendingPathComponent(".zimage/edits", isDirectory: true)
        try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: true)
        try Data("edit".utf8).write(to: edits.appendingPathComponent("abc.zimg"))
        try Data("flat".utf8).write(to: source.appendingPathComponent(folder + "/photo.zflat"))
        let landed = try MirrorCopy.copyBeside(relative: relative, from: source, to: dest)
        XCTAssertEqual(landed, folder + "/photo-2.jpg")
        let original = try Data(contentsOf: dest.appendingPathComponent(relative))
        XCTAssertEqual(original, Data("main".utf8))
        let recovered = try Data(contentsOf: dest.appendingPathComponent(landed))
        XCTAssertEqual(recovered, Data("mirror".utf8))
        MirrorCopy.copyRecoverSidecars(photoSource: relative, photoDest: landed, from: source, to: dest)
        let flat = try Data(contentsOf: dest.appendingPathComponent(folder + "/photo-2.zflat"))
        XCTAssertEqual(flat, Data("flat".utf8))
        let copied = MirrorCopy.copyEdits(mainUID: "abc", mirrorUID: "def", from: source, to: dest)
        XCTAssertEqual(copied, 1)
        let saved = try Data(contentsOf: dest.appendingPathComponent(".zimage/edits/def.zimg"))
        XCTAssertEqual(saved, Data("edit".utf8))
    }

    func testCopyBesideKeepsAFreeName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-copy-free-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        let folder = "Photos/day"
        try FileManager.default.createDirectory(at: source.appendingPathComponent(folder), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest.appendingPathComponent(folder), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = folder + "/photo.jpg"
        try Data("mirror".utf8).write(to: source.appendingPathComponent(relative))
        let landed = try MirrorCopy.copyBeside(relative: relative, from: source, to: dest)
        XCTAssertEqual(landed, relative)
        let recovered = try Data(contentsOf: dest.appendingPathComponent(relative))
        XCTAssertEqual(recovered, Data("mirror".utf8))
    }

    func testSyncEditsCopiesTheFlattenAndRemovesAStaleOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-sync-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        let mainEdits = source.appendingPathComponent(".zimage/edits", isDirectory: true)
        let mirrorEdits = dest.appendingPathComponent(".zimage/edits", isDirectory: true)
        try FileManager.default.createDirectory(at: mainEdits, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mirrorEdits, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("edit".utf8).write(to: mainEdits.appendingPathComponent("abc.zimg"))
        try Data("flat".utf8).write(to: mainEdits.appendingPathComponent("abc.zflat"))
        try Data("old-flat".utf8).write(to: mirrorEdits.appendingPathComponent("def.zflat"))
        try Data("old-jpg".utf8).write(to: mirrorEdits.appendingPathComponent("def.zjpg"))
        let copied = MirrorCopy.syncEdits(mainUID: "abc", mirrorUID: "def", from: source, to: dest)
        XCTAssertEqual(copied, 2)
        let saved = try Data(contentsOf: mirrorEdits.appendingPathComponent("def.zimg"))
        let flat = try Data(contentsOf: mirrorEdits.appendingPathComponent("def.zflat"))
        XCTAssertEqual(saved, Data("edit".utf8))
        XCTAssertEqual(flat, Data("flat".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirrorEdits.appendingPathComponent("def.zjpg").path))
        try FileManager.default.removeItem(at: mainEdits.appendingPathComponent("abc.zflat"))
        let again = MirrorCopy.syncEdits(mainUID: "abc", mirrorUID: "def", from: source, to: dest)
        XCTAssertEqual(again, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirrorEdits.appendingPathComponent("def.zflat").path))
        let kept = try Data(contentsOf: mirrorEdits.appendingPathComponent("def.zimg"))
        XCTAssertEqual(kept, Data("edit".utf8))
    }

    func testWriteThumbStoresThePreviewJPEG() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-thumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertEqual(MirrorCopy.thumbRelative(uid: "abcd"), ".zimage/cache/thumbs/ab/abcd.jpg")
        XCTAssertEqual(MirrorCopy.thumbRelative(uid: "ab/cd"), "")
        MirrorCopy.writeThumb(jpeg: jpeg, uid: "ab/cd", root: root)
        MirrorCopy.writeThumb(jpeg: jpeg, uid: "abcd", root: root)
        let saved = try Data(contentsOf: root.appendingPathComponent(".zimage/cache/thumbs/ab/abcd.jpg"))
        XCTAssertEqual(saved, jpeg)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".zimage/cache/thumbs/ab/ab/cd.jpg").path))
    }

    func testImmediateCopyReplacesASameSizeFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-replace-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        let folder = "Photos/day"
        try FileManager.default.createDirectory(at: source.appendingPathComponent(folder), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest.appendingPathComponent(folder), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = folder + "/photo.jpg"
        try Data("aaaa".utf8).write(to: source.appendingPathComponent(relative))
        try Data("bbbb".utf8).write(to: dest.appendingPathComponent(relative))
        try MirrorCopy.copyFile(relative: relative, from: source, to: dest)
        let skipped = try Data(contentsOf: dest.appendingPathComponent(relative))
        XCTAssertEqual(skipped, Data("bbbb".utf8))
        try MirrorCopy.copyFile(relative: relative, from: source, to: dest, replacing: true)
        let replaced = try Data(contentsOf: dest.appendingPathComponent(relative))
        XCTAssertEqual(replaced, Data("aaaa".utf8))
    }

    func testMirrorRenamesFinishInOrder() throws {
        let suite = "zimage-q-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-q-\(UUID().uuidString)", isDirectory: true)
        let folder = "Photos/day"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: root.appendingPathComponent(folder + "/a.jpg"))
        try Data("flat".utf8).write(to: root.appendingPathComponent(folder + "/a.zflat"))
        let first = MirrorQueue.Op(kind: MirrorQueue.file, from: folder + "/a.jpg", to: folder + "/b.jpg")
        let second = MirrorQueue.Op(kind: MirrorQueue.file, from: folder + "/b.jpg", to: folder + "/c.jpg")
        MirrorQueue.enqueue(first, mirrorRoot: root, defaults: defaults)
        MirrorQueue.enqueue(second, mirrorRoot: root, defaults: defaults)
        XCTAssertEqual(MirrorQueue.load(root: root).map(\.to), [folder + "/b.jpg", folder + "/c.jpg"])
        XCTAssertEqual(MirrorQueue.advance(root: root, defaults: defaults), .applied)
        XCTAssertEqual(MirrorQueue.load(root: root), [second])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(folder + "/a.jpg").path))
        XCTAssertEqual(MirrorQueue.advance(root: root, defaults: defaults), .applied)
        XCTAssertTrue(MirrorQueue.load(root: root).isEmpty)
        let landed = try Data(contentsOf: root.appendingPathComponent(folder + "/c.jpg"))
        XCTAssertEqual(landed, Data("a".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(folder + "/b.jpg").path))
        let flat = try Data(contentsOf: root.appendingPathComponent(folder + "/c.zflat"))
        XCTAssertEqual(flat, Data("flat".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(folder + "/a.zflat").path))
    }

    func testWaitingRenameStaysInFront() throws {
        let suite = "zimage-wait-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-wait-\(UUID().uuidString)", isDirectory: true)
        let folder = "Photos/day"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("b".utf8).write(to: root.appendingPathComponent(folder + "/b.jpg"))
        let waiting = MirrorQueue.Op(kind: MirrorQueue.file, from: folder + "/a.jpg", to: folder + "/missing.jpg")
        let later = MirrorQueue.Op(kind: MirrorQueue.file, from: folder + "/b.jpg", to: folder + "/c.jpg")
        try MirrorQueue.store([waiting, later], root: root)
        XCTAssertEqual(MirrorQueue.advance(root: root, defaults: defaults), .waiting)
        XCTAssertEqual(MirrorQueue.load(root: root), [waiting, later])
        let kept = try Data(contentsOf: root.appendingPathComponent(folder + "/b.jpg"))
        XCTAssertEqual(kept, Data("b".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(folder + "/c.jpg").path))
    }

    func testFolderRenameRewritesTheNextFile() throws {
        let suite = "zimage-folder-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos/old"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("pic".utf8).write(to: root.appendingPathComponent("Photos/old/a.jpg"))
        let folder = MirrorQueue.Op(kind: MirrorQueue.folder, from: "Photos/old", to: "Photos/new")
        let file = MirrorQueue.Op(kind: MirrorQueue.file, from: "Photos/old/a.jpg", to: "Photos/old/b.jpg")
        try MirrorQueue.store([folder, file], root: root)
        let rewritten = MirrorQueue.rewrite([file], after: folder)
        XCTAssertEqual(rewritten.first?.from, "Photos/new/a.jpg")
        XCTAssertEqual(rewritten.first?.to, "Photos/new/b.jpg")
        XCTAssertEqual(
            MirrorQueue.destination("Photos/old/a.jpg", ops: [folder] + rewritten),
            "Photos/new/b.jpg"
        )
        XCTAssertEqual(MirrorQueue.advance(root: root, defaults: defaults), .applied)
        XCTAssertEqual(MirrorQueue.load(root: root), rewritten)
        XCTAssertEqual(MirrorQueue.advance(root: root, defaults: defaults), .applied)
        let landed = try Data(contentsOf: root.appendingPathComponent("Photos/new/b.jpg"))
        XCTAssertEqual(landed, Data("pic".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Photos/old").path))
    }

    func testRenameWaitsOnTheMirrorUntilTheShareIsMounted() throws {
        let suite = "zimage-pending-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let op = MirrorQueue.Op(kind: MirrorQueue.file, from: "Photos/day/a.jpg", to: "Photos/day/b.jpg")
        MirrorQueue.enqueue(op, mirrorRoot: nil, defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos/day"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        MirrorQueue.flushPending(into: root, defaults: defaults)
        XCTAssertEqual(MirrorQueue.load(root: root), [op])
        XCTAssertNil(defaults.data(forKey: MirrorQueue.pendingKey))
    }

    func testMirrorFrameColors() {
        XCTAssertEqual(MirrorFrame.kind(orphan: true, selected: false), .red)
        XCTAssertEqual(MirrorFrame.kind(orphan: true, selected: true), .purple)
        XCTAssertEqual(MirrorFrame.kind(orphan: false, selected: true), .green)
        XCTAssertEqual(MirrorFrame.kind(orphan: false, selected: false), .none)
    }

    func testMirrorResumeSkipsFinishedFolders() {
        var place = MirrorProgress.empty(mainID: "main", mirrorID: "mirror")
        place.folder = "Photos/1964/1964-11-24"
        place.file = "b.jpg"
        place.filesDone = false
        XCTAssertEqual(MirrorProgress.step(folder: "Photos", place: place), .skipFiles)
        XCTAssertEqual(MirrorProgress.step(folder: "Photos/1964", place: place), .skipFiles)
        XCTAssertEqual(MirrorProgress.step(folder: "Photos/1964/1964-01-01", place: place), .skipTree)
        XCTAssertEqual(MirrorProgress.step(folder: "Photos/1964/1964-11-24", place: place), .resumeFiles)
        XCTAssertTrue(MirrorProgress.skipFile("a.jpg", place: place, folder: "Photos/1964/1964-11-24"))
        XCTAssertTrue(MirrorProgress.skipFile("b.jpg", place: place, folder: "Photos/1964/1964-11-24"))
        XCTAssertFalse(MirrorProgress.skipFile("c.jpg", place: place, folder: "Photos/1964/1964-11-24"))
        XCTAssertEqual(MirrorProgress.step(folder: "Photos/1965", place: place), .copy)
        place.filesDone = true
        place.subtreeDone = true
        XCTAssertEqual(MirrorProgress.step(folder: "Photos/1964/1964-11-24", place: place), .skipTree)
        XCTAssertEqual(MirrorProgress.step(folder: "Photos/1964/1964-11-24/event", place: place), .skipTree)
        XCTAssertEqual(MirrorProgress.step(folder: "Photos/1965", place: place), .copy)
    }

    func testMirrorProgressRestoresTheSavedPlace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos/day"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var place = MirrorProgress.empty(mainID: "main", mirrorID: "mirror")
        place.folder = "Photos/day"
        place.file = "a.jpg"
        MirrorProgress.store(place, root: root)
        let loaded = MirrorProgress.restored(from: root, mainID: "main", mirrorID: "mirror")
        XCTAssertEqual(loaded.folder, "Photos/day")
        XCTAssertEqual(loaded.file, "a.jpg")
        place.finished = true
        MirrorProgress.store(place, root: root)
        let fresh = MirrorProgress.restored(from: root, mainID: "main", mirrorID: "mirror")
        XCTAssertEqual(fresh.folder, "")
        let otherPair = MirrorProgress.restored(from: root, mainID: "other", mirrorID: "mirror")
        XCTAssertEqual(otherPair.folder, "")
        MirrorProgress.remove(root: root)
        XCTAssertNil(MirrorProgress.load(root: root))
        XCTAssertTrue(MirrorProgress.shouldContinue(nil, mainID: "main", mirrorID: "mirror"))
        XCTAssertFalse(MirrorProgress.shouldContinue(place, mainID: "main", mirrorID: "mirror"))
        var open = place
        open.finished = false
        open.folder = "Photos/1964/1964-11-24"
        XCTAssertTrue(MirrorProgress.shouldContinue(open, mainID: "main", mirrorID: "mirror"))
        XCTAssertFalse(MirrorProgress.shouldContinue(open, mainID: "other", mirrorID: "mirror"))
    }

    func testListFolderAndNeedsCopyStayInOneFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-list-\(UUID().uuidString)", isDirectory: true)
        let main = root.appendingPathComponent("main", isDirectory: true)
        let mirror = root.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: main.appendingPathComponent("Photos/day/nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mirror.appendingPathComponent("Photos/day"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("same".utf8).write(to: main.appendingPathComponent("Photos/day/a.jpg"))
        try Data("same".utf8).write(to: mirror.appendingPathComponent("Photos/day/a.jpg"))
        try Data("main".utf8).write(to: main.appendingPathComponent("Photos/day/b.jpg"))
        let listed = MirrorCopy.listFolder("Photos/day", root: main)
        XCTAssertTrue(listed.readable)
        XCTAssertEqual(listed.files.map(\.name), ["a.jpg", "b.jpg"])
        XCTAssertEqual(listed.children, ["Photos/day/nested"])
        XCTAssertFalse(MirrorCopy.needsCopy(relative: "Photos/day/a.jpg", destRelative: "Photos/day/a.jpg", from: main, to: mirror))
        XCTAssertTrue(MirrorCopy.needsCopy(relative: "Photos/day/b.jpg", destRelative: "Photos/day/b.jpg", from: main, to: mirror))
        let top = MirrorCopy.listFolder("Photos", root: main)
        XCTAssertEqual(top.files, [])
        XCTAssertEqual(top.children, ["Photos/day"])
    }

    func testFolderToKeepStaysInsidePhotos() {
        XCTAssertEqual(LibrarySwitch.folderToKeep("Photos"), "Photos")
        XCTAssertEqual(LibrarySwitch.folderToKeep("Photos/1964"), "Photos/1964")
        XCTAssertNil(LibrarySwitch.folderToKeep("Photos/../Secret"))
        XCTAssertNil(LibrarySwitch.folderToKeep("Photos/."))
        XCTAssertNil(LibrarySwitch.folderToKeep(""))
    }

    func testChoiceUsesThePageThatHoldsTheOpenPhoto() {
        let first = [LibraryAsset(uid: "main-a", relPath: "Photos/1964/a.jpg", ext: "jpg", mediaClass: "image")]
        let second = [LibraryAsset(uid: "mirror-b", relPath: "Photos/1964/b.jpg", ext: "jpg", mediaClass: "image")]
        let choice = LibrarySwitch.choice(
            pages: [first, second],
            videos: [],
            paths: ["Photos/1964/a.jpg", "Photos/1964/B.JPG"],
            primary: "Photos/1964/B.JPG"
        )
        XCTAssertEqual(choice?.page, 1)
        XCTAssertEqual(choice?.uids, ["mirror-b"])
        XCTAssertEqual(choice?.primaryUID, "mirror-b")
        let waiting = LibrarySwitch.choice(
            pages: [first],
            videos: [],
            paths: ["Photos/1964/a.jpg", "Photos/1964/b.jpg"],
            primary: "Photos/1964/b.jpg"
        )
        XCTAssertEqual(waiting?.page, 0)
        XCTAssertEqual(waiting?.uids, ["main-a"])
        XCTAssertNil(waiting?.primaryUID)
    }

    func testKeepLibraryPlaceOpensTheSamePhotoOnTheOtherServer() async throws {
        let harness = try SwitchHarness()
        defer { harness.remove() }
        try harness.write("Photos/1964/b.jpg")
        harness.browser.displayFolder = "Photos/other"
        harness.browser.selectedUID = "main-b"
        harness.browser.connect(harness.client(page: SwitchHarness.page(uid: "mirror-b", path: "Photos/1964/b.jpg")))
        XCTAssertEqual(harness.browser.displayFolder, DisplayFolder.root)
        XCTAssertNil(harness.browser.selectedUID)
        await harness.browser.keepLibraryPlace(
            folder: "Photos/1964",
            paths: ["Photos/1964/a.jpg", "Photos/1964/b.jpg"],
            primary: "Photos/1964/b.jpg",
            opening: true
        )
        XCTAssertEqual(harness.browser.displayFolder, "Photos/1964")
        XCTAssertEqual(harness.browser.selectedUID, "mirror-b")
        XCTAssertFalse(harness.browser.selectedUIDs.contains("main-b"))
        XCTAssertEqual(harness.opened.map(\.lastPathComponent), ["b.jpg"])
        XCTAssertNil(harness.browser.notice)
        XCTAssertFalse(harness.browser.switchNeedsFolderView)
    }

    func testKeepLibraryPlaceSelectsInFolderViewWithoutOpening() async throws {
        let harness = try SwitchHarness()
        defer { harness.remove() }
        try harness.write("Photos/1964/b.jpg")
        harness.browser.connect(harness.client(page: SwitchHarness.page(uid: "mirror-b", path: "Photos/1964/b.jpg")))
        await harness.browser.keepLibraryPlace(
            folder: "Photos/1964",
            paths: ["Photos/1964/b.jpg"],
            primary: "Photos/1964/b.jpg",
            opening: false
        )
        XCTAssertEqual(harness.browser.displayFolder, "Photos/1964")
        XCTAssertEqual(harness.browser.selectedUID, "mirror-b")
        XCTAssertTrue(harness.opened.isEmpty)
        XCTAssertNil(harness.browser.notice)
        XCTAssertFalse(harness.browser.switchNeedsFolderView)
    }

    func testKeepLibraryPlaceSelectsAPhotoOnALaterPage() async throws {
        let harness = try SwitchHarness()
        defer { harness.remove() }
        try harness.write("Photos/1964/b.jpg")
        let first = (0..<200).map { ("p\($0)", "Photos/1964/p\($0).jpg") }
        var second = (200..<399).map { ("p\($0)", "Photos/1964/p\($0).jpg") }
        second.append(("mirror-b", "Photos/1964/b.jpg"))
        let third = [("tail", "Photos/1964/tail.jpg")]
        harness.browser.connect(harness.client(pages: [
            "": SwitchHarness.page(rows: first, cursor: "c1"),
            "c1": SwitchHarness.page(rows: second, cursor: "c2"),
            "c2": SwitchHarness.page(rows: third, cursor: ""),
        ]))
        await harness.browser.keepLibraryPlace(
            folder: "Photos/1964",
            paths: ["Photos/1964/b.jpg"],
            primary: "Photos/1964/b.jpg",
            opening: false
        )
        XCTAssertEqual(harness.browser.selectedUID, "mirror-b")
        XCTAssertEqual(harness.browser.folderPage, 1)
        XCTAssertTrue(harness.browser.selectedUIDs.contains("mirror-b"))
        XCTAssertTrue(harness.opened.isEmpty)
        XCTAssertNil(harness.browser.notice)
        var spins = 0
        while harness.browser.folderPageCounting && spins < 100 {
            try await Task.sleep(for: .milliseconds(10))
            spins += 1
        }
        XCTAssertFalse(harness.browser.folderPageCounting)
        XCTAssertEqual(harness.browser.folderPhotoTotal, 401)
        XCTAssertEqual(harness.browser.selectedUID, "mirror-b")
        XCTAssertEqual(harness.browser.folderPage, 1)
        await harness.browser.reload(media: "photo")
        XCTAssertEqual(harness.browser.selectedUID, "mirror-b")
        XCTAssertEqual(harness.browser.folderPage, 1)
    }

    func testPreviewFileNameDoesNotNeedTheFile() {
        let id = UUID().uuidString
        let missing = URL(fileURLWithPath: "/tmp/zimage-missing-\(id).jpg")
        let name = FolderPreviewCache.fileName(for: missing)
        XCTAssertTrue(name.hasSuffix(".jpg"))
        XCTAssertEqual(name, FolderPreviewCache.fileName(for: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let uncollapsed = URL(fileURLWithPath: "/tmp/zimage-missing/../zimage-missing-\(id).jpg")
        XCTAssertNotEqual(uncollapsed.path, missing.path)
        XCTAssertNotEqual(FolderPreviewCache.fileName(for: uncollapsed), name)
    }

    func testOpenWithMenuDoesNotNeedTheFile() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-openwith-\(UUID().uuidString)", isDirectory: true)
        let browser = LibraryBrowser(
            client: LibraryAppClient.offline(),
            libraryRoot: root,
            openFile: { _, _ in }
        )
        let asset = LibraryAsset(uid: "still", relPath: "Photos/missing.jpg", ext: "jpg", mediaClass: "image")
        let targets = browser.openWithTargets(for: asset)
        XCTAssertEqual(targets, browser.openWithTargets(for: asset))
        XCTAssertFalse(targets.isEmpty)
        XCTAssertEqual(browser.listedSizeLabel(for: asset), LibraryItemMenu.sizeUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Photos/missing.jpg").path))
    }

    func testKeepLibraryPlaceLeavesImageViewWhenThePhotoIsMissing() async throws {
        let harness = try SwitchHarness()
        defer { harness.remove() }
        harness.browser.connect(harness.client(page: SwitchHarness.page(uid: "mirror-a", path: "Photos/1964/a.jpg")))
        await harness.browser.keepLibraryPlace(
            folder: "Photos/1964",
            paths: ["Photos/1964/b.jpg"],
            primary: "Photos/1964/b.jpg",
            opening: true
        )
        XCTAssertEqual(harness.browser.displayFolder, "Photos/1964")
        XCTAssertTrue(harness.opened.isEmpty)
        XCTAssertEqual(harness.browser.notice, "This photo is not on this server.")
        XCTAssertTrue(harness.browser.switchNeedsFolderView)
    }

    func testKeepLibraryPlaceOpensAFileTheCatalogHasNotListed() async throws {
        let harness = try SwitchHarness()
        defer { harness.remove() }
        try harness.write("Photos/1964/b.jpg")
        harness.browser.connect(harness.client(page: SwitchHarness.page(uid: "mirror-a", path: "Photos/1964/a.jpg")))
        await harness.browser.keepLibraryPlace(
            folder: "Photos/1964",
            paths: ["Photos/1964/b.jpg"],
            primary: "Photos/1964/b.jpg",
            opening: true
        )
        XCTAssertEqual(harness.browser.displayFolder, "Photos/1964")
        XCTAssertEqual(harness.opened.map(\.lastPathComponent), ["b.jpg"])
        XCTAssertNil(harness.browser.notice)
        XCTAssertFalse(harness.browser.switchNeedsFolderView)
    }
}

private final class SwitchOpenLog: @unchecked Sendable {
    var urls: [URL] = []
}

@MainActor
private final class SwitchHarness {
    let root: URL
    let browser: LibraryBrowser
    let log: SwitchOpenLog
    var opened: [URL] { log.urls }

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = SwitchOpenLog()
        let browser = LibraryBrowser(
            client: HelperClient(credentials: HelperCredentials(host: "192.168.1.147", pin: Data([1]), token: "t")) { _ in
                throw URLError(.cannotConnectToHost)
            },
            libraryRoot: root,
            openFile: { url, _ in log.urls.append(url) }
        )
        self.root = root
        self.log = log
        self.browser = browser
    }

    func write(_ relative: String) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func client(page: Data) -> HelperClient {
        client(pages: ["": page])
    }

    func client(pages: [String: Data]) -> HelperClient {
        HelperClient(credentials: HelperCredentials(host: "192.168.1.34", pin: Data([2]), token: "t")) { request in
            let path = request.url?.path ?? ""
            if path == "/v1/focus" {
                throw URLError(.cannotConnectToHost)
            }
            guard path == "/v1/assets" else {
                throw URLError(.cannotConnectToHost)
            }
            let items = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?.queryItems
            let media = items?.first { $0.name == "media" }?.value
            if media == "video" {
                throw URLError(.cannotConnectToHost)
            }
            let cursor = items?.first { $0.name == "cursor" }?.value ?? ""
            guard let body = pages[cursor] else {
                throw URLError(.cannotConnectToHost)
            }
            return HelperResponse(status: 200, body: body)
        }
    }

    static func page(uid: String, path: String) -> Data {
        page(rows: [(uid, path)], cursor: "")
    }

    static func page(rows: [(String, String)], cursor: String) -> Data {
        let encoded = rows.map { uid, path in
            #"{"uid":"\#(uid)","relPath":"\#(path)","ext":"jpg","mediaClass":"image"}"#
        }.joined(separator: ",")
        return Data(#"{"rows":[\#(encoded)],"nextCursor":"\#(cursor)"}"#.utf8)
    }
}
