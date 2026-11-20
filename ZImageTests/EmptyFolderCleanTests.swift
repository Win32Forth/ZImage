import XCTest
@testable import ZImager

final class EmptyFolderCleanTests: XCTestCase {
    func testEmptyFoldersGoAndAFileKeepsItsFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let year = root.appendingPathComponent("Photos/Year", isDirectory: true)
        let day = year.appendingPathComponent("Day", isDirectory: true)
        let empty = year.appendingPathComponent("Empty", isDirectory: true)
        let nested = empty.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let photo = day.appendingPathComponent("photo.jpg")
        try Data("photo".utf8).write(to: photo)
        try Data("keep".utf8).write(to: year.appendingPathComponent(".DS_Store"))

        let outcome = EmptyFolderClean.removeEmpty(libraryRoot: root, folder: "Photos/Year")
        XCTAssertEqual(Set(outcome.removed), ["Photos/Year/Empty/Nested", "Photos/Year/Empty"])
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: year.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: day.path))
        XCTAssertEqual(try Data(contentsOf: photo), Data("photo".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: year.appendingPathComponent(".DS_Store").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertEqual(outcome.removedFiles, 1)
    }

    func testPhotosItselfStaysWhileAnEmptyChildGoes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("Photos/OnlyEmpty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let outcome = EmptyFolderClean.removeEmpty(libraryRoot: root, folder: "Photos")
        XCTAssertEqual(outcome.removed, ["Photos/OnlyEmpty"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Photos").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertEqual(EmptyFolderClean.summary(removed: 1, failed: 0), "Deleted 1 empty folder.")
        XCTAssertEqual(EmptyFolderClean.summary(removed: 0, failed: 0), "No empty folders were deleted.")
    }

    func testAHiddenFileKeepsTheFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Photos/Dot", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hidden = folder.appendingPathComponent(".keep")
        try Data("store".utf8).write(to: hidden)
        let outcome = EmptyFolderClean.removeEmpty(libraryRoot: root, folder: "Photos/Dot")
        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertEqual(outcome.removedFiles, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: hidden), Data("store".utf8))
    }

    func testThumbnailCachesGoAndAnEmptyFolderFollows() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let year = root.appendingPathComponent("Photos/1980 Ansel Adams", isDirectory: true)
        let day = year.appendingPathComponent("1980-7-22 Ansel Adams", isDirectory: true)
        let kept = root.appendingPathComponent("Photos/Kept", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("thumbs".utf8).write(to: day.appendingPathComponent("Thumbs.db"))
        try Data("desktop".utf8).write(to: day.appendingPathComponent("desktop.ini"))
        let photo = kept.appendingPathComponent("photo.jpg")
        try Data("photo".utf8).write(to: photo)
        try Data("fork".utf8).write(to: kept.appendingPathComponent("._photo.jpg"))
        try Data("store".utf8).write(to: kept.appendingPathComponent(".DS_Store"))
        let outcome = EmptyFolderClean.removeEmpty(libraryRoot: root, folder: "Photos/1980 Ansel Adams")
        XCTAssertEqual(Set(outcome.removed), ["Photos/1980 Ansel Adams/1980-7-22 Ansel Adams", "Photos/1980 Ansel Adams"])
        XCTAssertEqual(outcome.removedFiles, 2)
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: year.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: day.path))
        let keptOutcome = EmptyFolderClean.removeEmpty(libraryRoot: root, folder: "Photos/Kept")
        XCTAssertTrue(keptOutcome.removed.isEmpty)
        XCTAssertEqual(keptOutcome.removedFiles, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertEqual(try Data(contentsOf: photo), Data("photo".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.appendingPathComponent("._photo.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.appendingPathComponent(".DS_Store").path))
        XCTAssertEqual(
            EmptyFolderClean.summary(removed: 2, failed: 0, files: 2),
            "Deleted 2 empty folders. Deleted 2 hidden files."
        )
    }

    func testASymlinkIsLeftAndIsNotFollowed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("zimage-clean-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let box = root.appendingPathComponent("Photos/Box", isDirectory: true)
        let empty = box.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let link = box.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let outcome = EmptyFolderClean.removeEmpty(libraryRoot: root, folder: "Photos/Box")
        XCTAssertEqual(outcome.removed, ["Photos/Box/Empty"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(EmptyFolderClean.removeEmpty(libraryRoot: root, folder: "Photos/../\(outside.lastPathComponent)").failed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-clean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos", isDirectory: true), withIntermediateDirectories: true)
        return root
    }
}
