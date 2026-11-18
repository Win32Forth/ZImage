import Foundation

/// A new name for one file that stays in the folder it is already in.
enum FileRename {
    enum Problem: Equatable, Error {
        case empty
        case unchanged
        case invalid
        case taken
        case missing
        case failed
    }

    /// The name that would be written, or why the typed text cannot be a file name.
    static func cleaned(_ typed: String) -> Result<String, Problem> {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        if trimmed == "." || trimmed == ".." { return .failure(.invalid) }
        if trimmed.utf8.count > 255 { return .failure(.invalid) }
        if trimmed.contains(where: { $0 == "/" || $0 == ":" || $0 == "\0" || $0.isNewline }) {
            return .failure(.invalid)
        }
        return .success(trimmed)
    }

    /// The file's path with its last component replaced.
    static func relocatedPath(_ relative: String, fileName: String) -> String {
        let parent = (relative as NSString).deletingLastPathComponent
        if parent.isEmpty { return fileName }
        return (parent as NSString).appendingPathComponent(fileName)
    }

    /// Where the file would land. A case-only change is allowed when that path is this same file.
    static func destination(from source: URL, typed: String, occupied: (URL) -> Bool) -> Result<URL, Problem> {
        switch cleaned(typed) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let newName):
            if newName == source.lastPathComponent { return .failure(.unchanged) }
            let dest = source.deletingLastPathComponent().appendingPathComponent(newName)
            let sameFile = newName.compare(source.lastPathComponent, options: String.CompareOptions.caseInsensitive) == .orderedSame
            if !sameFile, occupied(dest) { return .failure(.taken) }
            return .success(dest)
        }
    }

    static func message(for problem: Problem, name: String) -> String? {
        switch problem {
        case .empty:
            return "Type a file name."
        case .unchanged:
            return nil
        case .invalid:
            return "That name cannot be used."
        case .taken:
            return "A file named \(name) is already in this folder."
        case .missing, .failed:
            return "The file could not be renamed."
        }
    }

    /// Renames the file. A case-only change goes through a temporary name so the volume accepts it.
    static func perform(source: URL, typed: String) -> Result<URL, Problem> {
        let decision = destination(from: source, typed: typed) { url in
            FileManager.default.fileExists(atPath: url.path)
        }
        guard case .success(let dest) = decision else {
            if case .failure(let problem) = decision { return .failure(problem) }
            return .failure(.failed)
        }
        let fileAccess = source.startAccessingSecurityScopedResource()
        let directory = source.deletingLastPathComponent()
        let directoryAccess = directory.startAccessingSecurityScopedResource()
        defer {
            if fileAccess { source.stopAccessingSecurityScopedResource() }
            if directoryAccess { directory.stopAccessingSecurityScopedResource() }
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return .failure(.missing) }
        let caseOnly = dest.lastPathComponent.compare(source.lastPathComponent, options: String.CompareOptions.caseInsensitive) == .orderedSame
        do {
            if caseOnly {
                let temporary = directory.appendingPathComponent(".zimage-rename-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: source, to: temporary)
                do {
                    try FileManager.default.moveItem(at: temporary, to: dest)
                } catch {
                    try? FileManager.default.moveItem(at: temporary, to: source)
                    return .failure(.failed)
                }
            } else {
                try FileManager.default.moveItem(at: source, to: dest)
            }
            return .success(dest)
        } catch {
            return .failure(.failed)
        }
    }
}
