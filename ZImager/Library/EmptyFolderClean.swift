import Darwin
import Foundation

/// Deletes the selected folder and the folders inside it when they contain no files.
/// Thumbs.db, desktop.ini, .DS_Store, and AppleDouble files are deleted first.
/// Any other file keeps its folder. Photos itself stays.
/// A symbolic link is left in place and is not followed. `rmdir` refuses a folder that is not empty.
nonisolated enum EmptyFolderClean {
    struct Outcome: Equatable, Sendable {
        var removed: [String] = []
        var removedFiles = 0
        var failed = 0
        var missing = false
    }

    static func allows(_ folder: String) -> Bool {
        let parts = folder.split(separator: "/").map(String.init)
        return parts.first == "Photos" && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }
    }

    static func removeEmpty(libraryRoot: URL, folder: String) -> Outcome {
        guard allows(folder), let directory = resolve(libraryRoot: libraryRoot, relative: folder) else {
            return Outcome(failed: 1)
        }
        let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            return Outcome(failed: 1)
        }
        guard values?.isDirectory == true else {
            return Outcome(missing: true)
        }
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard directory.path.hasPrefix(rootPrefix) else { return Outcome(failed: 1) }
        var outcome = Outcome()
        _ = sweep(
            url: directory,
            relative: folder,
            rootPrefix: rootPrefix,
            deleteSelf: folder != "Photos",
            outcome: &outcome
        )
        return outcome
    }

    /// A leftover catalog file. A photograph, a video, and any other name stay.
    static func isClutter(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "thumbs.db" || lower == "ehthumbs.db" || lower == "ehthumbs_vista.db" || lower == "desktop.ini" || lower == ".ds_store" {
            return true
        }
        return name.hasPrefix("._") && name.count > 2
    }

    static func summary(removed: Int, failed: Int, files: Int = 0) -> String {
        if files == 0 {
            if removed == 0 && failed == 0 {
                return "No empty folders were deleted."
            }
            if removed == 0 {
                return "Empty folders could not be deleted."
            }
            let line = removed == 1 ? "Deleted 1 empty folder." : "Deleted \(removed.formatted()) empty folders."
            guard failed > 0 else { return line }
            let stay = failed == 1 ? "1 folder could not be deleted." : "\(failed.formatted()) folders could not be deleted."
            return line + " " + stay
        }
        var parts: [String] = []
        if removed > 0 {
            parts.append(removed == 1 ? "Deleted 1 empty folder." : "Deleted \(removed.formatted()) empty folders.")
        }
        parts.append(files == 1 ? "Deleted 1 hidden file." : "Deleted \(files.formatted()) hidden files.")
        if failed > 0 {
            parts.append(failed == 1 ? "1 folder could not be deleted." : "\(failed.formatted()) folders could not be deleted.")
        }
        return parts.joined(separator: " ")
    }

    /// True when `url` is gone.
    private static func sweep(
        url: URL,
        relative: String,
        rootPrefix: String,
        deleteSelf: Bool,
        outcome: inout Outcome
    ) -> Bool {
        guard url.path.hasPrefix(rootPrefix) else {
            outcome.failed += 1
            return false
        }
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            outcome.failed += 1
            return false
        }
        var blocked = false
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                blocked = true
                continue
            }
            let name = item.lastPathComponent
            if values?.isDirectory != true {
                if isClutter(name), removeClutterFile(item) {
                    outcome.removedFiles += 1
                    continue
                }
                blocked = true
                continue
            }
            guard name != ".", name != "..", !name.contains("/") else {
                blocked = true
                continue
            }
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(prefix) else {
                blocked = true
                continue
            }
            let gone = sweep(
                url: resolved,
                relative: relative + "/" + name,
                rootPrefix: rootPrefix,
                deleteSelf: true,
                outcome: &outcome
            )
            if !gone { blocked = true }
        }
        guard !blocked, deleteSelf else { return false }
        let left = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
        guard let left, left.isEmpty else {
            outcome.failed += 1
            return false
        }
        if removeEmptyDirectory(url) {
            outcome.removed.append(relative)
            return true
        }
        outcome.failed += 1
        return false
    }

    /// `rmdir` deletes a directory only when it has no entries.
    private static func removeEmptyDirectory(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return false }
            return rmdir(pointer) == 0
        }
    }

    /// `unlink` removes one file. It does not remove a directory.
    private static func removeClutterFile(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return false }
            return unlink(pointer) == 0
        }
    }

    /// The folder must already exist and stay inside the library. A symlink stops the walk.
    private static func resolve(libraryRoot: URL, relative: String) -> URL? {
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.first == "Photos", parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            return nil
        }
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var url = root
        for (index, part) in parts.enumerated() {
            url = url.appendingPathComponent(part, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return index == parts.count - 1 ? url : nil
            }
            if index == parts.count - 1 {
                guard url.path.hasPrefix(rootPrefix) else { return nil }
                return url
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(rootPrefix) else { return nil }
            url = resolved
        }
        return nil
    }
}
