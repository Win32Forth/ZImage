import Foundation

/// One directory under Photos. The grid lists the files. The tree does not.
struct LibraryFolderNode: Identifiable, Equatable, Sendable {
    let rel: String
    let name: String
    var id: String { rel }
}

/// Child directories of one folder. A click loads the next level. The whole share is not scanned.
enum LibraryFolderScan {
    nonisolated static func childFolders(libraryRoot: URL, parent: String) -> [LibraryFolderNode] {
        let directory = libraryRoot.appending(path: parent)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var folders: [LibraryFolderNode] = []
        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isDirectory == true else { continue }
            let rel = parent + "/" + name
            guard let prefix = DisplayFolder.prefix(selected: url, libraryRoot: libraryRoot), prefix == rel else { continue }
            folders.append(LibraryFolderNode(rel: rel, name: name))
        }
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
