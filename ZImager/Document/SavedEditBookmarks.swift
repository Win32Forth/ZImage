import Foundation

/// Security-scoped bookmarks for the `.zimg` that holds one photo's edits.
/// Keyed by the original file's BLAKE3 so opening that photo can load the edits
/// wherever the `.zimg` was saved.
nonisolated enum SavedEditBookmarks {
    private static let defaults = UserDefaults(suiteName: "com.Win32Forth.ZImage.editBookmarks")
    private static let key = "byDigest"

    static func store(_ bookmark: Data, for digest: String) {
        var map = defaults?.dictionary(forKey: key) ?? [:]
        map[digest] = bookmark
        defaults?.set(map, forKey: key)
    }

    static func bookmark(for digest: String) -> Data? {
        defaults?.dictionary(forKey: key)?[digest] as? Data
    }

    static func remove(digest: String) {
        var map = defaults?.dictionary(forKey: key) ?? [:]
        map.removeValue(forKey: digest)
        defaults?.set(map, forKey: key)
    }
}

/// Edits live here because the photo folder on the share is not writable.
nonisolated enum LocalEditStore {
    static func folder() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = base.appendingPathComponent("ZImage/edits", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func fileURL(digest: String) throws -> URL {
        try folder().appendingPathComponent(digest + ".zimg")
    }
}
