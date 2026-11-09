import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ZImager

@MainActor
final class OpenResetTests: XCTestCase {
    func testSecondPhotoDropsToneAndRotation() async throws {
        let first = temporaryFile("first.jpg")
        let second = temporaryFile("second.jpg")
        try writeJPEG(width: 32, height: 24, to: first)
        try writeJPEG(width: 24, height: 32, to: second)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let model = EditorModel()
        model.openSecurityScopedFile(at: first)
        try await waitUntil(model.proxy != nil, model: model)
        model.rotateClockwise()
        model.beginToneDrag()
        model.nudgeTone(\.exposureEV, to: 0.8, label: "Exposure")
        model.endToneDrag()
        XCTAssertEqual(model.draftGeometry.quarterTurns, 1)
        XCTAssertEqual(model.draftTone.exposureEV, 0.8, accuracy: 0.0001)

        model.openSecurityScopedFile(at: second)
        try await waitUntil(model.openedFileName == second.lastPathComponent && model.proxy != nil, model: model)
        XCTAssertEqual(model.draftGeometry, .identity)
        XCTAssertEqual(model.draftTone, .identity)
        XCTAssertEqual(model.log.state, .identity)
        XCTAssertTrue(model.log.commands.isEmpty)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.draftGeometry, .identity)
        XCTAssertEqual(model.draftTone, .identity)
        XCTAssertEqual(model.openedFileName, second.lastPathComponent)
    }

    func testSavedZimgKeepsItsRotation() async throws {
        let photo = temporaryFile("saved.jpg")
        try writeJPEG(width: 40, height: 16, to: photo)
        let original = try Data(contentsOf: photo)
        var saved = HistoryLog()
        var geometry = GeometryState.identity
        geometry.quarterTurns = 1
        saved.commit(.setGeometry(geometry, label: "Rotate clockwise"))
        var tone = ToneState.identity
        tone.contrast = 0.4
        saved.commit(.setTone(tone, label: "Contrast"))
        let bookmark = try? photo.bookmarkData(options: [.withSecurityScope])
        let zimgBytes = try ZImgRaw.bytesForSavePanel(
            log: saved,
            original: original,
            pathHint: photo.path,
            bookmark: bookmark,
            uti: UTType.jpeg.identifier,
            previewJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
        let zimg = temporaryFile("saved.zimg")
        try zimgBytes.write(to: zimg)
        let other = temporaryFile("other.jpg")
        try writeJPEG(width: 16, height: 16, to: other)
        defer {
            try? FileManager.default.removeItem(at: photo)
            try? FileManager.default.removeItem(at: zimg)
            try? FileManager.default.removeItem(at: other)
        }

        let model = EditorModel()
        model.openSecurityScopedFile(at: other)
        try await waitUntil(model.proxy != nil, model: model)
        model.rotateClockwise()
        model.rotateClockwise()
        XCTAssertEqual(model.draftGeometry.quarterTurns, 2)

        model.openSecurityScopedFile(at: zimg)
        try await waitUntil(
            model.openedFileName == photo.lastPathComponent && model.draftGeometry.quarterTurns == 1,
            model: model
        )
        XCTAssertNil(model.canvasMessage)
        XCTAssertEqual(model.draftGeometry.quarterTurns, 1)
        XCTAssertEqual(model.draftTone.contrast, 0.4, accuracy: 0.0001)
        XCTAssertEqual(model.log.commands.count, 2)
    }

    func testFailedOpenDropsThePreviousAdjustments() async throws {
        let photo = temporaryFile("photo.jpg")
        try writeJPEG(width: 20, height: 20, to: photo)
        let broken = temporaryFile("broken.x3f")
        try Data("ABCD".utf8).write(to: broken)
        defer {
            try? FileManager.default.removeItem(at: photo)
            try? FileManager.default.removeItem(at: broken)
        }

        let model = EditorModel()
        model.openSecurityScopedFile(at: photo)
        try await waitUntil(model.proxy != nil, model: model)
        model.rotateClockwise()
        model.beginToneDrag()
        model.nudgeTone(\.exposureEV, to: -0.5, label: "Exposure")
        model.endToneDrag()

        model.openSecurityScopedFile(at: broken)
        try await waitUntil(model.canvasMessage != nil, model: model)
        XCTAssertNil(model.proxy)
        XCTAssertEqual(model.draftGeometry, .identity)
        XCTAssertEqual(model.draftTone, .identity)
        XCTAssertTrue(model.log.commands.isEmpty)
    }

    func testReturningToTheFirstPhotoRestoresItsEdits() async throws {
        let first = temporaryFile("return-first.jpg")
        let second = temporaryFile("return-second.jpg")
        try writeJPEG(width: 30, height: 18, to: first, red: 0.15)
        try writeJPEG(width: 18, height: 30, to: second, red: 0.55)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let model = EditorModel()
        model.openSecurityScopedFile(at: first)
        try await waitUntil(model.proxy != nil, model: model)
        model.rotateClockwise()
        model.beginToneDrag()
        model.nudgeTone(\.exposureEV, to: 0.7, label: "Exposure")
        model.endToneDrag()

        model.openSecurityScopedFile(at: second)
        try await waitUntil(model.openedFileName == second.lastPathComponent && model.proxy != nil, model: model)
        XCTAssertEqual(model.draftGeometry, .identity)
        XCTAssertEqual(model.draftTone, .identity)

        model.openSecurityScopedFile(at: first)
        try await waitUntil(model.openedFileName == first.lastPathComponent && model.draftGeometry.quarterTurns == 1, model: model)
        XCTAssertEqual(model.draftGeometry.quarterTurns, 1)
        XCTAssertEqual(model.draftTone.exposureEV, 0.7, accuracy: 0.0001)
        let stored = try XCTUnwrap(model.localEditFile())
        XCTAssertNotEqual(
            stored.deletingLastPathComponent().standardizedFileURL,
            first.deletingLastPathComponent().standardizedFileURL
        )
    }

    func testSaveWritesOutsideThePhotoFolderAndReopens() async throws {
        let photo = temporaryFile("readonly-share.jpg")
        try writeJPEG(width: 26, height: 18, to: photo, red: 0.42)
        let original = try Data(contentsOf: photo)
        let digest = Blake3.hex(original)
        let stored = try LocalEditStore.fileURL(digest: digest)
        defer {
            try? FileManager.default.removeItem(at: photo)
            try? FileManager.default.removeItem(at: stored)
            SavedEditBookmarks.remove(digest: digest)
        }

        let model = EditorModel()
        model.openSecurityScopedFile(at: photo)
        try await waitUntil(model.proxy != nil, model: model)
        model.rotateClockwise()
        model.save()
        try await waitUntil(FileManager.default.fileExists(atPath: stored.path), model: model)
        XCTAssertNotEqual(
            stored.deletingLastPathComponent().standardizedFileURL,
            photo.deletingLastPathComponent().standardizedFileURL
        )
        XCTAssertEqual(model.previewBanner, "Edits saved.")

        let again = EditorModel()
        again.openSecurityScopedFile(at: photo)
        try await waitUntil(
            again.openedFileName == photo.lastPathComponent && again.draftGeometry.quarterTurns == 1,
            model: again
        )
        XCTAssertEqual(again.draftGeometry.quarterTurns, 1)
    }

    func testSiblingZimgAppliesOnALaterOpen() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("zimage-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = folder.appendingPathComponent("beside.jpg")
        try writeJPEG(width: 28, height: 14, to: photo, red: 0.33)
        let original = try Data(contentsOf: photo)
        var saved = HistoryLog()
        var geometry = GeometryState.identity
        geometry.quarterTurns = 1
        saved.commit(.setGeometry(geometry, label: "Rotate clockwise"))
        let zimg = folder.appendingPathComponent("beside.zimg")
        let bytes = try ZImgRaw.bytesForSavePanel(
            log: saved,
            original: original,
            pathHint: photo.path,
            bookmark: nil,
            uti: UTType.jpeg.identifier,
            previewJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
        try bytes.write(to: zimg)
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = EditorModel()
        model.openSecurityScopedFile(at: photo)
        try await waitUntil(model.openedFileName == photo.lastPathComponent && model.draftGeometry.quarterTurns == 1, model: model)
        XCTAssertEqual(model.draftGeometry.quarterTurns, 1)
        XCTAssertEqual(model.log.commands.count, 1)
    }

    func testSavedZimgAppliesEvenWhenItIsNotBesideThePhoto() async throws {
        let photo = temporaryFile("linked.jpg")
        try writeJPEG(width: 22, height: 22, to: photo, red: 0.81)
        let original = try Data(contentsOf: photo)
        let digest = Blake3.hex(original)
        var saved = HistoryLog()
        var geometry = GeometryState.identity
        geometry.quarterTurns = 2
        saved.commit(.setGeometry(geometry, label: "Rotate clockwise"))
        var tone = ToneState.identity
        tone.contrast = 0.25
        saved.commit(.setTone(tone, label: "Contrast"))
        let zimg = temporaryFile("linked-elsewhere.zimg")
        let bytes = try ZImgRaw.bytesForSavePanel(
            log: saved,
            original: original,
            pathHint: photo.path,
            bookmark: nil,
            uti: UTType.jpeg.identifier,
            previewJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
        try bytes.write(to: zimg)
        let bookmark = try zimg.bookmarkData(options: [.withSecurityScope])
        SavedEditBookmarks.store(bookmark, for: digest)
        defer {
            SavedEditBookmarks.remove(digest: digest)
            try? FileManager.default.removeItem(at: photo)
            try? FileManager.default.removeItem(at: zimg)
        }

        let model = EditorModel()
        model.openSecurityScopedFile(at: photo)
        try await waitUntil(model.openedFileName == photo.lastPathComponent && model.draftGeometry.quarterTurns == 2, model: model)
        XCTAssertNil(model.canvasMessage)
        XCTAssertEqual(model.draftGeometry.quarterTurns, 2)
        XCTAssertEqual(model.draftTone.contrast, 0.25, accuracy: 0.0001)
    }

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zimage-open-\(UUID().uuidString)-\(name)")
    }

    private func waitUntil(_ ready: @autoclosure () -> Bool, model: EditorModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !ready(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(ready(), model.canvasMessage ?? "open did not finish")
    }

    private func writeJPEG(width: Int, height: Int, to url: URL, red: CGFloat = 0.2) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not write a JPEG")
            return
        }
        context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            XCTFail("Could not write a JPEG")
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            XCTFail("Could not write a JPEG")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            XCTFail("Could not write a JPEG")
        }
    }
}
