import Foundation

/// Parametric undo log. `cursor` is the number of commands currently applied.
/// Commands at indexes `cursor..<count` are the redo tail.
///
/// The log may grow to `depthCap` commands. The commit that would pass that
/// cap folds every command older than the newest `minimumDistinctUndo` into
/// one keyframe. After that fold, later appends stay folded the same way, so
/// a long session retains one keyframe plus the last six commands. Six undo
/// steps stay distinct. The keyframe is the state those older commands
/// produced, so the current image does not change.
nonisolated struct HistoryLog: Codable, Equatable, Sendable {
    var commands: [EditCommand]
    var cursor: Int

    static let depthCap = 100
    static let minimumDistinctUndo = 6

    init(commands: [EditCommand] = [], cursor: Int = 0) {
        self.commands = commands
        self.cursor = cursor
    }

    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor < commands.count }

    var state: EditState {
        EditState.replay(Array(commands.prefix(max(0, min(cursor, commands.count)))))
    }

    mutating func commit(_ command: EditCommand) {
        if cursor < commands.count {
            commands.removeSubrange(cursor..<commands.count)
        }
        commands.append(command)
        compactAfterAppendingCommit()
        cursor = commands.count
    }

    mutating func undo() {
        if cursor > 0 {
            cursor -= 1
        }
    }

    mutating func redo() {
        if cursor < commands.count {
            cursor += 1
        }
    }

    /// `index` is a command index. The cursor becomes `index + 1` so that
    /// command is included. A cursor is never left past the end.
    mutating func selectCommand(at index: Int) {
        let appliedThrough = index + 1
        cursor = min(max(0, appliedThrough), commands.count)
    }

    private mutating func compactAfterAppendingCommit() {
        let overCap = commands.count > Self.depthCap
        let alreadyFolded = commands.contains(where: \.isKeyframe)
        let overRetainedWindow = alreadyFolded && commands.count > Self.minimumDistinctUndo + 1
        guard overCap || overRetainedWindow else { return }

        let keep = min(Self.minimumDistinctUndo, commands.count)
        guard commands.count > keep else { return }
        let older = Array(commands.dropLast(keep))
        let recent = Array(commands.suffix(keep))
        let folded = EditState.replay(older)
        commands = [.keyframe(folded)] + recent
    }
}
