import XCTest
@testable import ZImager

final class FolderOrganizeTests: XCTestCase {
    func testCatalogDateWinsAndInvalidDaysAreRefused() {
        let header = [
            "DateTimeOriginal 1999:01:02 00:00:00",
            "DateTimeDigitized 1998:03:04 00:00:00",
            "DateTime 1997:05:06 00:00:00",
        ]
        XCTAssertEqual(
            FolderOrganize.day(catalog: "2024-06-15T12:00:00Z", headerLines: header)?.folder,
            "Photos/2024/2024-06-15"
        )
        XCTAssertEqual(FolderOrganize.day(catalog: nil, headerLines: header)?.folder, "Photos/1999/1999-01-02")
        XCTAssertEqual(
            FolderOrganize.day(catalog: "", headerLines: ["DateTimeDigitized 2010:03:04 01:02:03"])?.folder,
            "Photos/2010/2010-03-04"
        )
        XCTAssertEqual(
            FolderOrganize.day(catalog: nil, headerLines: ["DateTime 2011:05:06 00:00:00"])?.folder,
            "Photos/2011/2011-05-06"
        )
        XCTAssertNil(FolderOrganize.day(catalog: nil, headerLines: []))
        XCTAssertNil(FolderOrganize.day(catalog: "0000:00:00 00:00:00", headerLines: []))
        XCTAssertNil(FolderOrganize.day(catalog: "2024-02-31", headerLines: []))
        XCTAssertNil(FolderOrganize.day(catalog: "1700-01-01", headerLines: []))
        XCTAssertNil(FolderOrganize.folder(for: nil).hasPrefix("Photos/_Review") ? nil : FolderOrganize.folder(for: nil))
        XCTAssertEqual(FolderOrganize.folder(for: nil), "Photos/_Review")
    }

    func testDuplicateIsSameSizeOrARenamedCollision() {
        let neighbors = [
            FolderOrganize.Neighbor(name: "a.jpg", size: 10),
            FolderOrganize.Neighbor(name: "b.jpg", size: 10),
        ]
        XCTAssertTrue(FolderOrganize.isDuplicate(sourceName: "a.jpg", placedName: "a.jpg", placedSize: 10, neighbors: neighbors))
        XCTAssertFalse(FolderOrganize.isDuplicate(
            sourceName: "a.jpg",
            placedName: "a.jpg",
            placedSize: 11,
            neighbors: [FolderOrganize.Neighbor(name: "b.jpg", size: 9)]
        ))
        XCTAssertTrue(FolderOrganize.isDuplicate(sourceName: "a.jpg", placedName: "a-2.jpg", placedSize: 4, neighbors: []))
        XCTAssertFalse(FolderOrganize.allows("Photos/_Duplicates"))
        XCTAssertFalse(FolderOrganize.allows("Photos/_Removed/extra"))
        XCTAssertTrue(FolderOrganize.allows("Photos/Blogger 1600"))
        XCTAssertEqual(
            FolderOrganize.summary(reviewed: 1, dated: 2, duplicates: 1, stayed: 1),
            "Organized the first page, 4 photos. 1 went to Photos/_Review. 2 went to date folders. 1 duplicate preview was saved. 1 stayed."
        )
    }

    func testMovePlacesTheFileAndADuplicatePreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-organize-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent("Photos/Inbox", isDirectory: true)
        let day = root.appendingPathComponent("Photos/2024/2024-06-15", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("same-bytes".utf8)
        try bytes.write(to: inbox.appendingPathComponent("a.jpg"))
        try bytes.write(to: day.appendingPathComponent("b.jpg"))
        let outcome = FolderMove.perform(libraryRoot: root, items: [("Photos/Inbox/a.jpg", "Photos/2024/2024-06-15")])
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(outcome.placed, ["Photos/2024/2024-06-15/a.jpg"])
        let placed = root.appendingPathComponent("Photos/2024/2024-06-15/a.jpg")
        let size = Int64((try placed.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        XCTAssertTrue(FolderOrganize.isDuplicate(
            sourceName: "a.jpg",
            placedName: "a.jpg",
            placedSize: size,
            neighbors: FolderOrganize.neighbors(of: day)
        ))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let reference = FolderMove.writeNewFile(
            libraryRoot: root,
            directory: FolderOrganize.duplicatesFolder,
            fileName: FolderOrganize.referenceFileName(placedPath: outcome.placed[0]),
            data: jpeg
        )
        XCTAssertEqual(reference, "Photos/_Duplicates/a.jpg")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Photos/_Duplicates/a.jpg")), jpeg)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("a.jpg").path))
        XCTAssertEqual(try Data(contentsOf: placed), bytes)
    }

    func testAPhotoAlreadyInItsDayFolderStaysEligibleForConfidence() {
        let day = FolderOrganize.Day(year: 2024, month: 6, day: 15)
        XCTAssertTrue(FolderOrganize.alreadyPlaced(path: "Photos/2024/2024-06-15/a.jpg", day: day))
        XCTAssertTrue(FolderOrganize.alreadyPlaced(path: "Photos/2024/2024-06-15/event/a.jpg", day: day))
        XCTAssertFalse(FolderOrganize.alreadyPlaced(path: "Photos/Inbox/a.jpg", day: day))
        XCTAssertFalse(FolderOrganize.alreadyPlaced(path: "Photos/2024/a.jpg", day: day))
        XCTAssertFalse(FolderOrganize.alreadyPlaced(path: "Photos/2024/2024-06-16/a.jpg", day: day))
        XCTAssertFalse(FolderOrganize.alreadyPlaced(path: "Photos/2024/2024-06-15-extra/a.jpg", day: day))
        let lines = [
            "DateTimeOriginal 2020:01:01 00:00:00",
            "DateTimeDigitized 2024:06:15 08:00:00",
            "DateTime 1999:01:01 00:00:00",
        ]
        XCTAssertTrue(FolderOrganize.headerMatches(day: day, headerLines: lines))
        XCTAssertFalse(FolderOrganize.headerMatches(day: day, headerLines: ["DateTimeOriginal 2020:01:01 00:00:00"]))
        XCTAssertTrue(FolderOrganize.headerMatches(day: day, headerLines: [
            "DateTimeOriginal 2020:01:01 00:00:00",
            "DateTime 2024:06:15 08:00:00",
        ]))
        XCTAssertEqual(
            FolderOrganize.day(catalog: nil, headerLines: [
                "DateTimeOriginal 0000:00:00",
                "DateTime 2024:06:15 08:00:00",
            ])?.folder,
            "Photos/2024/2024-06-15"
        )
        XCTAssertTrue(FolderOrganize.confidenceIsZero(0))
        XCTAssertFalse(FolderOrganize.confidenceIsZero(nil))
        XCTAssertFalse(FolderOrganize.confidenceIsZero(0.95))
        XCTAssertFalse(FolderOrganize.confidenceIsZero(1))
        XCTAssertEqual(
            FolderOrganize.summary(reviewed: 0, dated: 0, duplicates: 0, stayed: 2, confirmed: 1, pages: 3, confidenceMissed: true),
            "Organized 3 pages, 2 photos. 1 catalog confidence was set to 1.00. Catalog confidence was not stored. 2 stayed."
        )
        XCTAssertEqual(
            FolderOrganize.summary(reviewed: 0, dated: 0, duplicates: 0, stayed: 2, confirmed: 2),
            "Organized the first page, 2 photos. 2 catalog confidence values were set to 1.00. 2 stayed."
        )
    }
}
