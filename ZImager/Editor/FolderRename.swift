import Foundation
import SwiftUI

/// A new name for one folder that stays in the folder it is already in.
enum FolderRename {
    enum Problem: Equatable, Error {
        case empty
        case unchanged
        case invalid
        case taken
        case missing
        case failed
        case link
    }

    /// Photos, and the three shelves the library looks up by name, keep those names.
    static let shelves = ["Photos/_Removed", "Photos/_Duplicates", "Photos/_Review"]

    private static let reservedNames: Set<String> = ["_Removed", "_Duplicates", "_Review"]

    /// The name that would be written. Spaces inside the name stay. The edges are trimmed.
    static func cleaned(_ typed: String) -> Result<String, Problem> {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        if trimmed == "." || trimmed == ".." { return .failure(.invalid) }
        if trimmed.utf8.count > 255 { return .failure(.invalid) }
        if reservedNames.contains(trimmed) { return .failure(.invalid) }
        if trimmed.contains(where: { $0 == "/" || $0 == ":" || $0 == "\0" || $0.isNewline }) {
            return .failure(.invalid)
        }
        return .success(trimmed)
    }

    /// A folder under Photos, other than Photos itself and the three shelves.
    static func catalogAllows(_ relative: String) -> Bool {
        if relative == DisplayFolder.root || shelves.contains(relative) { return false }
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts.first == DisplayFolder.root else { return false }
        return parts.allSatisfy { $0 != "." && $0 != ".." && !$0.contains("\0") }
    }

    static func keptMessage(relative: String) -> String {
        if relative == DisplayFolder.root {
            return "Photos stays at the top of the library."
        }
        return "That folder keeps its name."
    }

    /// Replaces `oldPrefix` with `newPrefix` when `path` is that folder or a file inside it.
    nonisolated static func shiftedRelative(_ path: String, from oldPrefix: String, to newPrefix: String) -> String? {
        if path == oldPrefix { return newPrefix }
        guard path.hasPrefix(oldPrefix + "/") else { return nil }
        return newPrefix + path.dropFirst(oldPrefix.count)
    }

    /// The same replacement for a file path. Several spellings of the old folder are accepted.
    static func shiftedPath(_ path: String, from old: URL, to new: URL) -> String? {
        let pairs = [
            (FolderEntry.cacheKey(for: old), FolderEntry.cacheKey(for: new)),
            (old.standardizedFileURL.path, new.standardizedFileURL.path),
            (old.path, new.path),
        ]
        for (fromPath, toPath) in pairs {
            if path == fromPath { return toPath }
            if path.hasPrefix(fromPath + "/") {
                return toPath + path.dropFirst(fromPath.count)
            }
        }
        return nil
    }

    /// The URL `path` would have after the folder rename. Nil when `path` is outside that folder.
    static func shifted(_ url: URL, from old: URL, to new: URL) -> URL? {
        guard let path = shiftedPath(FolderEntry.cacheKey(for: url), from: old, to: new) else { return nil }
        if path == FolderEntry.cacheKey(for: new) { return new }
        return URL(fileURLWithPath: path)
    }

    /// Where the folder would land. A case-only change is allowed when that path is this same folder.
    static func destination(from source: URL, typed: String, occupied: (URL) -> Bool) -> Result<URL, Problem> {
        switch cleaned(typed) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let newName):
            if newName == source.lastPathComponent { return .failure(.unchanged) }
            let dest = source.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
            let sameFolder = newName.compare(source.lastPathComponent, options: String.CompareOptions.caseInsensitive) == .orderedSame
            if !sameFolder, occupied(dest) { return .failure(.taken) }
            return .success(dest)
        }
    }

    static func message(for problem: Problem, name: String) -> String? {
        switch problem {
        case .empty:
            return "Type a folder name."
        case .unchanged:
            return nil
        case .invalid:
            return "That name cannot be used."
        case .taken:
            return "A folder named \(name) is already here."
        case .missing, .failed, .link:
            return "The folder could not be renamed."
        }
    }

    /// The directory for a catalog path. A symbolic link, or a path that leaves the library, is refused.
    static func libraryDirectory(libraryRoot: URL, relative: String) -> URL? {
        guard catalogAllows(relative) else { return nil }
        let parts = relative.split(separator: "/").map(String.init)
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var url = root
        for part in parts {
            url = url.appendingPathComponent(part, isDirectory: true)
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true { return nil }
            guard values?.isDirectory == true else { return nil }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(rootPrefix) else { return nil }
            url = resolved
        }
        return url
    }

    /// Renames the folder. A case-only change goes through a temporary name. A symbolic link is left in place.
    static func perform(source: URL, typed: String) -> Result<URL, Problem> {
        let decision = destination(from: source, typed: typed) { url in
            FileManager.default.fileExists(atPath: url.path)
        }
        guard case .success(let dest) = decision else {
            if case .failure(let problem) = decision { return .failure(problem) }
            return .failure(.failed)
        }
        let values = try? source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values?.isSymbolicLink == true { return .failure(.link) }
        guard values?.isDirectory == true else { return .failure(.missing) }
        let folderAccess = source.startAccessingSecurityScopedResource()
        let directory = source.deletingLastPathComponent()
        let directoryAccess = directory.startAccessingSecurityScopedResource()
        defer {
            if folderAccess { source.stopAccessingSecurityScopedResource() }
            if directoryAccess { directory.stopAccessingSecurityScopedResource() }
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return .failure(.missing) }
        let caseOnly = dest.lastPathComponent.compare(source.lastPathComponent, options: String.CompareOptions.caseInsensitive) == .orderedSame
        do {
            if caseOnly {
                let temporary = directory.appendingPathComponent(".zimage-rename-\(UUID().uuidString)", isDirectory: true)
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

    /// Puts a renamed folder back at its previous URL.
    static func restore(from dest: URL, to original: URL) -> Bool {
        guard case .success = perform(source: dest, typed: original.lastPathComponent) else { return false }
        return true
    }
}

/// What the catalog did after the folder moved on disk.
enum LibraryFolderRenameFollow: Equatable, Sendable {
    /// The folder is not inside the paired library.
    case outside
    /// Catalog paths now use the new folder name. Asset ids stayed.
    case updated
    /// The catalog still has the old name, so the folder should move back.
    case failed
    /// The reply never arrived. The new directory stays, because the catalog write may still finish.
    case unsettled
}

/// Right-click Rename on one folder row.
struct FolderRenameMenu: ViewModifier {
    var allowed: Bool
    var enabled: Bool
    var start: () -> Void

    func body(content: Content) -> some View {
        if allowed {
            content.contextMenu {
                Button(LibraryItemMenu.rename, action: start)
                    .disabled(!enabled)
                    .accessibilityIdentifier("Rename folder")
                    .help("Gives this folder a new name in the same place.")
            }
        } else {
            content
        }
    }
}
