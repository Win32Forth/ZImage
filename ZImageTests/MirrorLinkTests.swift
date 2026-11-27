import XCTest
@testable import ZImager

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
        XCTAssertEqual(MirrorDiff.besideName("photo.jpg", taken: ["photo.jpg"]), "photo-2.jpg")
        XCTAssertEqual(MirrorDiff.besideName("photo.jpg", taken: ["photo.jpg", "photo-2.jpg"]), "photo-3.jpg")
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
}
