import Network
import XCTest
@testable import ZImager

final class HelperSetupTests: XCTestCase {
    func testChoosingThePhotosFolderUsesItsParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-base-\(UUID().uuidString)", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("1998", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(HelperInstallPaths.libraryBase(forChosen: photos).standardizedFileURL.path, root.standardizedFileURL.path)
        let share = root.appendingPathComponent("PhotoVideoAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        XCTAssertEqual(HelperInstallPaths.libraryBase(forChosen: share).standardizedFileURL.path, share.standardizedFileURL.path)
    }

    func testSuggestedNASPathKeepsTheShareName() {
        XCTAssertEqual(
            HelperInstallPaths.suggestedNASPath(
                libraryPath: "/Volumes/BackupData/PhotoVideoAudio",
                volumePath: "/Volumes/BackupData"
            ),
            "/volume1/BackupData/PhotoVideoAudio"
        )
        XCTAssertEqual(
            HelperInstallPaths.suggestedNASPath(
                libraryPath: "/Volumes/PhotoVideoAudio",
                volumePath: "/Volumes/PhotoVideoAudio"
            ),
            "/volume1/PhotoVideoAudio"
        )
    }

    func testNASPathRejectsRelativeAndParentSegments() {
        XCTAssertEqual(HelperInstallPaths.cleanNASPath("  /volume1/BackupData/PhotoVideoAudio  "), "/volume1/BackupData/PhotoVideoAudio")
        XCTAssertNil(HelperInstallPaths.cleanNASPath("volume1/BackupData"))
        XCTAssertNil(HelperInstallPaths.cleanNASPath("/volume1/BackupData/../Photos"))
        XCTAssertNil(HelperInstallPaths.cleanNASPath("/volume1//PhotoVideoAudio"))
    }

    func testTaskCommandQuotesTheScript() {
        XCTAssertEqual(
            HelperInstallPaths.taskCommand(nasPath: "/volume1/BackupData/PhotoVideoAudio"),
            "sh '/volume1/BackupData/PhotoVideoAudio/.zimage/bin/zimage-helper'"
        )
        let stop = HelperInstallPaths.stopCommand(nasPath: "/volume1/BackupData124")
        XCTAssertTrue(stop.contains("PIDFILE='/volume1/BackupData124/.zimage/helper.pid'"))
        XCTAssertTrue(stop.contains("zimage-helper-aarch64"))
        XCTAssertTrue(stop.contains("zimage-helper-x86_64"))
        XCTAssertTrue(stop.contains("/proc/[0-9]*"))
        XCTAssertTrue(stop.contains("zimage-helper-a*"))
        XCTAssertFalse(stop.contains("-config"))
        XCTAssertFalse(stop.contains("rm "))
        XCTAssertEqual(HelperInstallPaths.stopTaskName, "zimage-helper-stop")
    }

    func testVersionCompareTreatsASilentHelperAsOld() {
        XCTAssertTrue(HelperRelease.needsUpdate(running: nil))
        XCTAssertTrue(HelperRelease.needsUpdate(running: ""))
        XCTAssertTrue(HelperRelease.needsUpdate(running: "1.8.5"))
        XCTAssertFalse(HelperRelease.needsUpdate(running: HelperRelease.version))
    }

    func testRefusedPortCountsAsStopped() {
        XCTAssertTrue(HelperPort.meansClosed(.posix(.ECONNREFUSED)))
        XCTAssertFalse(HelperPort.meansClosed(.posix(.ETIMEDOUT)))
        XCTAssertFalse(HelperPort.meansClosed(.posix(.EHOSTUNREACH)))
    }

    func testReplaceWaitsUntilThePortIsRefused() {
        XCTAssertFalse(HelperReplace.allowed(portListening: nil))
        XCTAssertFalse(HelperReplace.allowed(portListening: true))
        XCTAssertTrue(HelperReplace.allowed(portListening: false))
    }

    func testStartScriptSelectsTheCPUAndDoesNotMovePhotos() {
        let script = HelperPackage.script()
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("zimage-helper-aarch64"))
        XCTAssertTrue(script.contains("zimage-helper-x86_64"))
        XCTAssertTrue(script.contains("chattr +C"))
        XCTAssertTrue(script.contains("GOMEMLIMIT=160MiB"))
        XCTAssertTrue(script.contains("library_root_local: \"$ROOT\""))
        XCTAssertFalse(script.contains("rm "))
        XCTAssertTrue(script.contains("\nEOF\n"))
    }

    func testInstallAndRemoveLeaveTheCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-helper-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let arm = root.appendingPathComponent("arm-src")
        let intel = root.appendingPathComponent("intel-src")
        try Data("arm".utf8).write(to: arm)
        try Data("intel".utf8).write(to: intel)
        let catalog = root.appendingPathComponent(".zimage/catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        try Data("catalog".utf8).write(to: catalog.appendingPathComponent("catalog.db"))
        let keep = root.appendingPathComponent(".zimage/bin/notes.txt")
        try FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: keep)

        try HelperPackage.install(libraryRoot: root, arm: arm, intel: intel, version: HelperRelease.version)
        XCTAssertTrue(HelperPackage.programInstalled(at: root))
        XCTAssertEqual(HelperPackage.versionFile(at: root), HelperRelease.version)
        let script = try String(contentsOf: HelperPackage.binDirectory(libraryRoot: root).appendingPathComponent(HelperPackage.scriptName), encoding: .utf8)
        XCTAssertTrue(script.contains("#!/bin/sh"))

        try HelperPackage.removeProgram(at: root)
        XCTAssertFalse(HelperPackage.programInstalled(at: root))
        XCTAssertEqual(try Data(contentsOf: catalog.appendingPathComponent("catalog.db")), Data("catalog".utf8))
        XCTAssertEqual(try Data(contentsOf: keep), Data("keep".utf8))
        XCTAssertFalse(HelperPackage.offerUpdate(at: root))
    }

    func testOfferUpdateWhenTheShareHasAnUnversionedHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-helper-offer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(HelperPackage.offerUpdate(at: root))
        let bin = HelperPackage.binDirectory(libraryRoot: root)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: bin.appendingPathComponent(HelperPackage.scriptName))
        XCTAssertTrue(HelperPackage.offerUpdate(at: root))
        try (HelperRelease.version + "\n").write(to: bin.appendingPathComponent(HelperPackage.versionName), atomically: true, encoding: .utf8)
        XCTAssertFalse(HelperPackage.offerUpdate(at: root))
    }

    func testServerNameUsesTheSMBHost() {
        XCTAssertEqual(HelperServerList.shortMountHost("DS423._smb._tcp.local"), "DS423")
        XCTAssertEqual(HelperServerList.shortMountHost("DS220.local"), "DS220")
        XCTAssertEqual(HelperServerList.baseName(for: URL(fileURLWithPath: "/tmp/PhotoVideoAudio")), "PhotoVideoAudio")
    }

    func testServerListKeepsTwoSharesAndTheOlderBookmark() throws {
        let suite = "com.Win32Forth.ZImage.servers.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("share-a-\(UUID().uuidString)", isDirectory: true)
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("share-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try LibraryFolderBookmark.store(first, defaults: defaults)
        defaults.set("192.168.1.147", forKey: LibraryAppClient.hostDefaultsKey)
        HelperServerList.migrate(defaults: defaults)
        HelperServerList.migrate(defaults: defaults)
        let migrated = HelperServerList.load(defaults: defaults)
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].host, "192.168.1.147")
        XCTAssertEqual(migrated[0].name, first.lastPathComponent)

        let extra = HelperServerRecord(
            id: UUID().uuidString,
            name: HelperServerList.uniqueName(second.lastPathComponent, among: migrated),
            nasPath: "/volume1/Other/PhotoVideoAudio",
            bookmark: try LibraryFolderBookmark.data(for: second),
            host: "192.168.1.50"
        )
        HelperServerList.upsert(extra, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: LibraryAppClient.hostDefaultsKey), "192.168.1.50")
        XCTAssertEqual(HelperServerList.load(defaults: defaults).count, 2)

        let back = try XCTUnwrap(HelperServerList.select(migrated[0].id, defaults: defaults))
        XCTAssertEqual(back.host, "192.168.1.147")
        XCTAssertEqual(defaults.string(forKey: LibraryAppClient.hostDefaultsKey), "192.168.1.147")
        let resolved = try XCTUnwrap(LibraryFolderBookmark.resolve(defaults: defaults))
        XCTAssertEqual(resolved.standardizedFileURL.path, first.standardizedFileURL.path)

        let remaining = HelperServerList.remove(id: migrated[0].id, defaults: defaults)
        XCTAssertEqual(remaining?.id, extra.id)
        XCTAssertEqual(defaults.string(forKey: LibraryAppClient.hostDefaultsKey), "192.168.1.50")
    }
}
