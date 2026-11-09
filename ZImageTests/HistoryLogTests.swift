import XCTest
@testable import ZImager

final class HistoryLogTests: XCTestCase {
    func testOneHundredTwentyCommitsCompactToKeyframePlusSix() throws {
        var originals: [EditCommand] = []
        originals.reserveCapacity(120)
        for index in 0..<114 {
            var tone = ToneState.identity
            tone.exposureEV = Double(index) * 0.01
            originals.append(.setTone(tone, label: "Exposure \(index)"))
        }
        originals.append(.setTone(.identity, label: "Tone A"))
        originals.append(.setTone(.identity, label: "Tone B"))
        originals.append(.setGeometry(.identity, label: "Straighten"))
        let inpaintID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        originals.append(.addInpaint(.empty(id: inpaintID)))
        originals.append(.setTone(.identity, label: "Tone C"))
        originals.append(.setTone(.identity, label: "Tone D"))
        XCTAssertEqual(originals.count, 120)

        var log = HistoryLog()
        for command in originals {
            log.commit(command)
        }

        XCTAssertEqual(log.commands.count, 7)
        XCTAssertEqual(log.cursor, 7)
        XCTAssertTrue(log.commands[0].isKeyframe)
        XCTAssertEqual(Array(log.commands.suffix(6)), Array(originals.suffix(6)))

        let expected = EditState.replay(originals)
        XCTAssertEqual(log.state, expected)
        if case .keyframe(let folded) = log.commands[0] {
            XCTAssertEqual(folded, EditState.replay(Array(originals.prefix(114))))
        } else {
            XCTFail("First command should be the compaction keyframe")
        }

        for _ in 0..<6 {
            log.undo()
        }
        XCTAssertEqual(log.cursor, 1)
        XCTAssertEqual(log.state, EditState.replay(Array(originals.prefix(114))))

        for _ in 0..<6 {
            log.redo()
        }
        XCTAssertEqual(log.cursor, 7)
        XCTAssertEqual(log.state, expected)

        let data = try JSONEncoder().encode(log)
        let decoded = try JSONDecoder().decode(HistoryLog.self, from: data)
        XCTAssertEqual(decoded.cursor, 7)
        XCTAssertEqual(decoded, log)
        XCTAssertEqual(decoded.state, expected)

        let encodedCommands = decoded.commands
        XCTAssertTrue(encodedCommands.contains { command in
            if case .setTone(let tone, _) = command { return tone == .identity }
            return false
        })
        XCTAssertTrue(encodedCommands.contains { command in
            if case .setGeometry(let geometry, _) = command { return geometry == .identity }
            return false
        })
        XCTAssertTrue(encodedCommands.contains { command in
            if case .addInpaint(let op) = command { return op.maskPNG.isEmpty }
            return false
        })
    }

    func testCommitDropsRedoTailBeforeAppending() {
        var log = HistoryLog()
        log.commit(.setTone(.identity, label: "One"))
        log.commit(.setTone(.identity, label: "Two"))
        log.undo()
        var changed = ToneState.identity
        changed.brightness = 0.25
        log.commit(.setTone(changed, label: "Replacement"))

        XCTAssertEqual(log.cursor, 2)
        XCTAssertEqual(log.commands.count, 2)
        XCTAssertEqual(log.commands[1].historyTitle, "Replacement")
        XCTAssertFalse(log.canRedo)
    }

    func testPasteSettingsAppliesToneAndGeometryInOneStep() {
        var tone = ToneState.identity
        tone.exposureEV = 1.5
        var geometry = GeometryState.identity
        geometry.straightenDegrees = 4
        var log = HistoryLog()
        log.commit(.setCrop(NormRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        log.commit(.pasteSettings(tone: tone, geometry: geometry))
        XCTAssertEqual(log.state.tone.exposureEV, 1.5, accuracy: 1e-9)
        XCTAssertEqual(log.state.geometry.straightenDegrees, 4, accuracy: 1e-9)
        XCTAssertEqual(log.state.crop, NormRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        XCTAssertEqual(log.commands[1].historyTitle, "Paste settings")
        log.undo()
        XCTAssertEqual(log.state.tone, .identity)
        XCTAssertEqual(log.state.geometry, .identity)
        XCTAssertNotNil(log.state.crop)
    }
}
