import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One main library and one mirror. The mirror copies the main server's folders and file names.
enum MirrorRoster {
    nonisolated static let main = "main"
    nonisolated static let mirror = "mirror"
    nonisolated static let dutyKey = "ZImageLibrary.serverDuty"

    static func locked(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: dutyKey) == mirror
    }

    static func mainRow(in rows: [HelperServerRecord]) -> HelperServerRecord? {
        rows.first { $0.duty == main }
    }

    static func mirrorRow(in rows: [HelperServerRecord]) -> HelperServerRecord? {
        rows.first { $0.duty == mirror }
    }

    /// One main and one mirror. Any earlier pair is cleared.
    static func link(mainID: String, mirrorID: String, rows: [HelperServerRecord]) -> [HelperServerRecord]? {
        guard mainID != mirrorID,
              rows.contains(where: { $0.id == mainID }),
              rows.contains(where: { $0.id == mirrorID }) else { return nil }
        return rows.map { row in
            var copy = row
            if row.id == mainID {
                copy.duty = main
                copy.follows = ""
            } else if row.id == mirrorID {
                copy.duty = mirror
                copy.follows = mainID
            } else {
                copy.duty = ""
                copy.follows = ""
            }
            return copy
        }
    }

    static func unlink(_ rows: [HelperServerRecord]) -> [HelperServerRecord] {
        rows.map { row in
            var copy = row
            copy.duty = ""
            copy.follows = ""
            return copy
        }
    }

    static func menuTitle(_ row: HelperServerRecord, active: Bool) -> String {
        var title = row.name
        if row.duty == main { title += " · Main" }
        if row.duty == mirror { title += " · Mirror" }
        if active { title += " ✓" }
        return title
    }
}

/// The folder and photo to keep when the main library and the mirror trade places.
enum LibrarySwitch {
    struct Choice: Equatable {
        var page: Int
        var uids: [String]
        /// The photo the user had open or selected, when that photo is in `pages` or `videos`.
        var primaryUID: String?
    }

    /// `Photos`, or a folder under it. A path that leaves the library is dropped.
    static func folderToKeep(_ folder: String) -> String? {
        let parts = folder.split(separator: "/").map(String.init)
        guard parts.first == DisplayFolder.root,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// The page that holds `primary`, and the selected photos that share that page.
    /// `primaryUID` stays empty until that photo has been read.
    static func choice(
        pages: [[LibraryAsset]],
        videos: [LibraryAsset],
        paths: [String],
        primary: String?
    ) -> Choice? {
        func same(_ asset: LibraryAsset, _ path: String) -> Bool {
            asset.relPath?.caseInsensitiveCompare(path) == .orderedSame
        }
        func wanted(_ asset: LibraryAsset) -> Bool {
            if paths.contains(where: { same(asset, $0) }) { return true }
            if let primary, same(asset, primary) { return true }
            return false
        }
        var hits: [(page: Int, asset: LibraryAsset)] = []
        for (index, page) in pages.enumerated() {
            for asset in page where wanted(asset) {
                hits.append((index, asset))
            }
        }
        for asset in videos where wanted(asset) {
            hits.append((0, asset))
        }
        guard !hits.isEmpty else { return nil }
        let primaryHit = primary.flatMap { path in hits.first { same($0.asset, path) } }
        let page = primaryHit?.page ?? hits[0].page
        let onPage = hits.filter { $0.page == page }
        var uids: [String] = []
        for path in paths {
            guard let hit = onPage.first(where: { same($0.asset, path) }) else { continue }
            if !uids.contains(hit.asset.uid) { uids.append(hit.asset.uid) }
        }
        if let primaryHit, primaryHit.page == page, !uids.contains(primaryHit.asset.uid) {
            uids.append(primaryHit.asset.uid)
        }
        if uids.isEmpty {
            uids = onPage.map(\.asset.uid)
        }
        return Choice(page: page, uids: uids, primaryUID: primaryHit?.asset.uid)
    }
}

/// Which mirror files are missing on the main server, and which main files the mirror still needs.
nonisolated enum MirrorDiff {
    static let sidecarExtensions = ["zimg", "ztiff", "zflat", "zjpg"]

    static func onlyOnMirror(main: Set<String>, mirror: Set<String>, recovered: [String: String]) -> Set<String> {
        var missing = Set<String>()
        for path in mirror where path.hasPrefix("Photos/") {
            if main.contains(path) { continue }
            if let landed = recovered[path], main.contains(landed) { continue }
            missing.insert(path)
        }
        return missing
    }

    /// The main-library file Edit in Library opens.
    /// The same path wins when that file is still there.
    /// A recovery that landed beside it is used when the original path is absent.
    static func mainPath(mirror relative: String, root: URL, recovered: [String: String], fileManager: FileManager = .default) -> String? {
        if safePhoto(relative), fileManager.fileExists(atPath: root.appendingPathComponent(relative).path) {
            return relative
        }
        guard let landed = recovered[relative], safePhoto(landed),
              fileManager.fileExists(atPath: root.appendingPathComponent(landed).path) else {
            return nil
        }
        return landed
    }

    /// Page paths whose bytes are absent from the main server. A recovery ledger path that still exists is present.
    static func missingPaths(_ paths: [String], mainRoot: URL, recovered: [String: String], fileManager: FileManager = .default) -> Set<String> {
        var present = Set<String>()
        for path in paths {
            if fileManager.fileExists(atPath: mainRoot.appendingPathComponent(path).path) {
                present.insert(path)
            }
            if let landed = recovered[path], fileManager.fileExists(atPath: mainRoot.appendingPathComponent(landed).path) {
                present.insert(landed)
            }
        }
        return onlyOnMirror(main: present, mirror: Set(paths), recovered: recovered)
    }

    /// Main files whose mirror copy is missing or a different size. The result is sorted.
    static func filesToCopy(mainBytes: [String: Int64], mirrorBytes: [String: Int64]) -> [String] {
        mainBytes.keys.filter { path in
            path.hasPrefix("Photos/") && mirrorBytes[path] != mainBytes[path]
        }.sorted()
    }

    /// The same name when it is free in that folder. A name already there becomes `photo-2.jpg`, then `photo-3.jpg`.
    static func besidePath(_ relative: String, taken: Set<String>) -> String? {
        let file = (relative as NSString).lastPathComponent
        let folder = (relative as NSString).deletingLastPathComponent
        guard let name = besideName(file, taken: takenNames(in: folder, paths: taken)) else { return nil }
        if folder.isEmpty || folder == "." { return name }
        return folder + "/" + name
    }

    /// Keeps `photo.jpg` when that name is free. The next free collision name is `photo-2.jpg`.
    static func besideName(_ fileName: String, taken: Set<String>) -> String? {
        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }
        if !taken.contains(fileName) { return fileName }
        let suffix = ext.isEmpty ? "" : "." + ext
        var number = 2
        while number <= 999 {
            let name = stem + "-" + String(number) + suffix
            if !taken.contains(name) { return name }
            number += 1
        }
        return nil
    }

    /// The same collision number applied to a sidecar of that photo.
    static func besideSidecar(photoSource: String, photoDest: String, sidecar: String) -> String? {
        let photoFile = (photoSource as NSString).lastPathComponent
        let destFile = (photoDest as NSString).lastPathComponent
        let photoStem = (photoFile as NSString).deletingPathExtension
        let destStem = (destFile as NSString).deletingPathExtension
        let sideFile = (sidecar as NSString).lastPathComponent
        let sideStem = (sideFile as NSString).deletingPathExtension
        guard sideStem == photoStem else { return nil }
        let ext = (sideFile as NSString).pathExtension
        let folder = (sidecar as NSString).deletingLastPathComponent
        let name = ext.isEmpty ? destStem : destStem + "." + ext
        if folder.isEmpty || folder == "." { return name }
        return folder + "/" + name
    }

    private static func safePhoto(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts.first == "Photos" else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }
    }

    private static func takenNames(in folder: String, paths: Set<String>) -> Set<String> {
        var names = Set<String>()
        for path in paths {
            let parent = (path as NSString).deletingLastPathComponent
            let same = parent == folder || ((folder.isEmpty || folder == ".") && (parent.isEmpty || parent == "."))
            if same { names.insert((path as NSString).lastPathComponent) }
        }
        return names
    }
}

/// Remembers a recovery so the red border comes off after the bytes land under a new name.
enum MirrorLedger {
    static let key = "ZImageLibrary.mirrorRecovered"

    static func load(defaults: UserDefaults = .standard) -> [String: String] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func remember(mirror: String, main: String, defaults: UserDefaults = .standard) {
        var map = load(defaults: defaults)
        map[mirror] = main
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// Drops a recovery whose main file, or whose mirror original, was removed.
    static func forget(main path: String, defaults: UserDefaults = .standard) {
        let map = forgetting(path, in: load(defaults: defaults))
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: key)
    }

    static func forgetting(_ path: String, in recovered: [String: String]) -> [String: String] {
        recovered.filter { key, value in
            key.caseInsensitiveCompare(path) != .orderedSame && value.caseInsensitiveCompare(path) != .orderedSame
        }
    }

    /// Mirror files that go to Photos/_Removed when this main file is removed.
    /// The same path is included. A recovered beside-name also includes the mirror original.
    static func pathsToPark(main relative: String, recovered: [String: String]) -> [String] {
        var paths: [String] = []
        func add(_ path: String) {
            guard path.hasPrefix("Photos/"), !path.contains("..") else { return }
            if path == "Photos/_Removed" || path.hasPrefix("Photos/_Removed/") { return }
            if paths.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) { return }
            paths.append(path)
        }
        add(relative)
        let extras = recovered.compactMap { mirror, landed -> String? in
            landed.caseInsensitiveCompare(relative) == .orderedSame ? mirror : nil
        }.sorted()
        for path in extras { add(path) }
        return paths
    }
}

/// Adds or removes `role: "mirror"` without changing the rest of the helper config.
nonisolated enum MirrorConfigText {
    static func setting(role: String, in text: String) -> String {
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("role:")
        }
        var lines = kept
        while lines.last?.isEmpty == true { lines.removeLast() }
        if role == MirrorRoster.mirror {
            lines.append("role: \"mirror\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Writes `role` only when the installed helper is this app's build.
/// An older helper rejects an unknown config key and will not start.
nonisolated enum MirrorConfigFile {
    enum Result: Equatable {
        case unchanged
        case updated
        case skippedOldHelper
        case unreadable
    }

    static func apply(role: String, libraryRoot: URL) -> Result {
        guard HelperPackage.versionFile(at: libraryRoot) == HelperRelease.version else { return .skippedOldHelper }
        let url = libraryRoot.appendingPathComponent(".zimage/config.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .unreadable }
        let next = MirrorConfigText.setting(role: role, in: text)
        if next == text { return .unchanged }
        do {
            try next.write(to: url, atomically: true, encoding: .utf8)
            return .updated
        } catch {
            return .unreadable
        }
    }
}

/// The border drawn around one folder-view photo.
nonisolated enum MirrorFrame {
    enum Kind: Equatable, Sendable {
        case none
        case red
        case purple
        case green
    }

    /// An orphan that is not selected stays red. A selected orphan is purple. Any other selected photo is green.
    static func kind(orphan: Bool, selected: Bool) -> Kind {
        if orphan && selected { return .purple }
        if orphan { return .red }
        if selected { return .green }
        return .none
    }
}

/// How far a mirror pass has confirmed files on the main server.
/// A later start skips folders that this place already finished.
nonisolated enum MirrorProgress {
    static let fileName = ".zimage/mirror-progress.json"

    struct Place: Codable, Equatable, Sendable {
        var mainID: String
        var mirrorID: String
        /// Photos-relative folder the pass has reached. Empty before the first folder.
        var folder: String
        /// Last file name confirmed in `folder`.
        var file: String
        /// Every file directly in `folder` is confirmed. Child folders may remain.
        var filesDone: Bool
        /// `folder` and every folder under it are confirmed.
        var subtreeDone: Bool
        var finished: Bool
        /// Files that could not be copied. The pass tries them again before it finishes.
        var retry: [String]
    }

    enum Step: Equatable, Sendable {
        /// This folder and everything under it is already confirmed.
        case skipTree
        /// Files in this folder are confirmed. Child folders still need a look.
        case skipFiles
        /// Some files in this folder are confirmed. Continue after `file`.
        case resumeFiles
        /// Nothing in this folder has been confirmed.
        case copy
    }

    static func empty(mainID: String, mirrorID: String) -> Place {
        Place(
            mainID: mainID,
            mirrorID: mirrorID,
            folder: "",
            file: "",
            filesDone: false,
            subtreeDone: false,
            finished: false,
            retry: []
        )
    }

    /// A linked pair keeps going when nothing is saved yet, and when the saved place is unfinished.
    /// A finished place waits until Start mirroring is clicked.
    static func shouldContinue(_ place: Place?, mainID: String, mirrorID: String) -> Bool {
        guard let place else { return true }
        guard place.mainID == mainID, place.mirrorID == mirrorID else { return false }
        return !place.finished
    }

    /// A finished pass, a different pair, or a missing file starts at the first folder.
    static func restored(from root: URL, mainID: String, mirrorID: String, fileManager: FileManager = .default) -> Place {
        guard let place = load(root: root, fileManager: fileManager),
              place.mainID == mainID,
              place.mirrorID == mirrorID,
              !place.finished else {
            return empty(mainID: mainID, mirrorID: mirrorID)
        }
        return place
    }

    /// Folders are visited files-first, then child folders in name order.
    static func step(folder: String, place: Place) -> Step {
        if place.folder.isEmpty { return .copy }
        if folder == place.folder {
            if place.subtreeDone { return .skipTree }
            if place.filesDone { return .skipFiles }
            return .resumeFiles
        }
        if place.folder.hasPrefix(folder + "/") { return .skipFiles }
        if folder.hasPrefix(place.folder + "/") {
            if place.subtreeDone || !place.filesDone { return .skipTree }
            return .copy
        }
        if folder < place.folder { return .skipTree }
        return .copy
    }

    /// A file at or before the saved name was confirmed on the previous pass.
    static func skipFile(_ name: String, place: Place, folder: String) -> Bool {
        guard step(folder: folder, place: place) == .resumeFiles else { return false }
        return name < place.file || name == place.file
    }

    static func load(root: URL, fileManager: FileManager = .default) -> Place? {
        let url = root.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let place = try? JSONDecoder().decode(Place.self, from: data) else { return nil }
        return place
    }

    static func store(_ place: Place, root: URL, fileManager: FileManager = .default) {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? JSONEncoder().encode(place) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func remove(root: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: root.appendingPathComponent(fileName))
    }
}

/// File copies for the mirror. Call these off the main thread. They do not open the catalog.
nonisolated enum MirrorCopy {
    static func relativePath(of file: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(path.dropFirst(rootPath.count + 1))
        guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { return nil }
        return relative
    }

    /// Regular files under `Photos`, with their sizes.
    static func photoFiles(root: URL, fileManager: FileManager = .default) -> [String: Int64] {
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: photos,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var files: [String: Int64] = [:]
        for case let url as URL in enumerator {
            guard let relative = relativePath(of: url, under: root), relative.hasPrefix("Photos/") else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            files[relative] = Int64(size)
        }
        return files
    }

    struct File: Sendable, Equatable {
        var name: String
        var size: Int64
    }

    struct Directory: Sendable, Equatable {
        var files: [File]
        var children: [String]
        var readable: Bool
    }

    /// One folder, not its descendants. Names are sorted. Hidden names are left out.
    static func listFolder(_ relative: String, root: URL, fileManager: FileManager = .default) -> Directory {
        guard relative == "Photos" || relative.hasPrefix("Photos/"), !relative.contains("..") else {
            return Directory(files: [], children: [], readable: false)
        }
        let url = root.appendingPathComponent(relative, isDirectory: true)
        guard let items = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Directory(files: [], children: [], readable: false)
        }
        var files: [File] = []
        var children: [String] = []
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(".") { continue }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values?.isDirectory == true {
                children.append(relative + "/" + name)
                continue
            }
            if values?.isRegularFile == true, let size = values?.fileSize {
                files.append(File(name: name, size: Int64(size)))
            }
        }
        files.sort { $0.name < $1.name }
        children.sort { $0 < $1 }
        return Directory(files: files, children: children, readable: true)
    }

    /// True when `copyFile` would write bytes. A matching size, or a different path that already exists, stays put.
    static func needsCopy(
        relative: String,
        destRelative: String,
        from sourceRoot: URL,
        to destRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard relative.hasPrefix("Photos/"), destRelative.hasPrefix("Photos/"),
              !relative.contains(".."), !destRelative.contains("..") else { return false }
        let source = sourceRoot.appendingPathComponent(relative)
        guard fileManager.fileExists(atPath: source.path) else { return false }
        let dest = destRoot.appendingPathComponent(destRelative)
        if !fileManager.fileExists(atPath: dest.path) { return true }
        if sameByteCount(source, dest, fileManager: fileManager) { return false }
        return destRelative == relative
    }

    static func copyItem(from source: URL, to dest: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = dest.deletingLastPathComponent().appendingPathComponent(".zimage-copy-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: temp)
        do {
            if fileManager.fileExists(atPath: dest.path) {
                _ = try fileManager.replaceItemAt(dest, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: dest)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    static func copyFile(
        relative: String,
        from sourceRoot: URL,
        to destRoot: URL,
        destRelative: String? = nil,
        replacing: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        let destRel = destRelative ?? relative
        guard relative.hasPrefix("Photos/"), destRel.hasPrefix("Photos/"),
              !relative.contains(".."), !destRel.contains("..") else { return }
        let source = sourceRoot.appendingPathComponent(relative)
        let dest = destRoot.appendingPathComponent(destRel)
        if fileManager.fileExists(atPath: dest.path) {
            // A library walk skips a same-size file. A save the user just made can keep
            // the same byte count, so that copy replaces the mirror file.
            if !replacing, sameByteCount(source, dest, fileManager: fileManager) { return }
            if destRel != relative { return }
        }
        try copyItem(from: source, to: dest, fileManager: fileManager)
    }

    private static func sameByteCount(_ left: URL, _ right: URL, fileManager: FileManager) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        let a = try? left.resourceValues(forKeys: keys).fileSize
        let b = try? right.resourceValues(forKeys: keys).fileSize
        return a != nil && a == b
    }

    /// Copies one photo onto the main server. The name stays the same when it is free.
    /// A name that is already in that folder gains `-2`. The new relative path is returned.
    static func copyBeside(relative: String, from sourceRoot: URL, to destRoot: URL, fileManager: FileManager = .default) throws -> String {
        let folder = (relative as NSString).deletingLastPathComponent
        let destFolder = destRoot.appendingPathComponent(folder, isDirectory: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: destFolder.path)) ?? []
        var taken = Set(names.map { folder == "." || folder.isEmpty ? $0 : folder + "/" + $0 })
        if fileManager.fileExists(atPath: destRoot.appendingPathComponent(relative).path) {
            taken.insert(relative)
        }
        guard let destRelative = MirrorDiff.besidePath(relative, taken: taken) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let source = sourceRoot.appendingPathComponent(relative)
        let dest = destRoot.appendingPathComponent(destRelative)
        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: dest)
        return destRelative
    }

    /// Sidecars that sit beside the photo, renamed with the recovered photo's collision number.
    static func copyRecoverSidecars(photoSource: String, photoDest: String, from sourceRoot: URL, to destRoot: URL, fileManager: FileManager = .default) {
        let folder = (photoSource as NSString).deletingLastPathComponent
        let stem = ((photoSource as NSString).lastPathComponent as NSString).deletingPathExtension
        let dir = sourceRoot.appendingPathComponent(folder)
        let names = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            guard MirrorDiff.sidecarExtensions.contains(ext) else { continue }
            guard (name as NSString).deletingPathExtension == stem else { continue }
            let side = folder.isEmpty || folder == "." ? name : folder + "/" + name
            guard let destRel = MirrorDiff.besideSidecar(photoSource: photoSource, photoDest: photoDest, sidecar: side) else { continue }
            let dest = destRoot.appendingPathComponent(destRel)
            if fileManager.fileExists(atPath: dest.path) { continue }
            try? copyItem(from: sourceRoot.appendingPathComponent(side), to: dest, fileManager: fileManager)
        }
    }

    /// Catalog uids that already have an edit file or a flattened TIFF on this server.
    static func editUIDs(root: URL, fileManager: FileManager = .default) -> Set<String> {
        let dir = root.appendingPathComponent(".zimage/edits", isDirectory: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        var uids = Set<String>()
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            guard MirrorDiff.sidecarExtensions.contains(ext) else { continue }
            let stem = (name as NSString).deletingPathExtension
            if safeUID(stem) { uids.insert(stem) }
        }
        return uids
    }

    static func copyEdits(mainUID: String, mirrorUID: String, from mainRoot: URL, to mirrorRoot: URL, fileManager: FileManager = .default) -> Int {
        guard safeUID(mainUID), safeUID(mirrorUID) else { return 0 }
        var copied = 0
        for ext in MirrorDiff.sidecarExtensions {
            let source = mainRoot.appendingPathComponent(".zimage/edits/\(mainUID).\(ext)")
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let dest = mirrorRoot.appendingPathComponent(".zimage/edits/\(mirrorUID).\(ext)")
            do {
                try copyItem(from: source, to: dest, fileManager: fileManager)
                copied += 1
            } catch {
                continue
            }
        }
        return copied
    }

    /// Copies this photo's edit files, including the flattened TIFF, and removes a sidecar the main server no longer has.
    static func syncEdits(mainUID: String, mirrorUID: String, from mainRoot: URL, to mirrorRoot: URL, fileManager: FileManager = .default) -> Int {
        guard safeUID(mainUID), safeUID(mirrorUID) else { return 0 }
        var copied = 0
        for ext in MirrorDiff.sidecarExtensions {
            let source = mainRoot.appendingPathComponent(".zimage/edits/\(mainUID).\(ext)")
            let dest = mirrorRoot.appendingPathComponent(".zimage/edits/\(mirrorUID).\(ext)")
            if fileManager.fileExists(atPath: source.path) {
                do {
                    try copyItem(from: source, to: dest, fileManager: fileManager)
                    copied += 1
                } catch {
                    continue
                }
            } else if fileManager.fileExists(atPath: dest.path) {
                try? fileManager.removeItem(at: dest)
            }
        }
        return copied
    }

    static func safeUID(_ uid: String) -> Bool {
        !uid.isEmpty && !uid.contains("/") && !uid.contains(".")
    }

    /// The folder thumbnail path the helper uses for this catalog id.
    static func thumbRelative(uid: String) -> String {
        guard safeUID(uid) else { return "" }
        let prefix = String(uid.prefix(2))
        return ".zimage/cache/thumbs/\(prefix)/\(uid).jpg"
    }

    /// Writes the folder preview JPEG for a catalog id. A readable JPEG is reduced to a long edge of 256.
    static func writeThumb(jpeg: Data, uid: String, root: URL, fileManager: FileManager = .default) {
        guard safeUID(uid), !jpeg.isEmpty, jpeg.count <= 2_000_000 else { return }
        let body = folderJPEG(jpeg) ?? jpeg
        guard !body.isEmpty, body.count <= 2_000_000 else { return }
        let relative = thumbRelative(uid: uid)
        guard relative.hasPrefix(".zimage/cache/thumbs/") else { return }
        let dest = root.appendingPathComponent(relative)
        do {
            try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: dest, options: .atomic)
        } catch {
            return
        }
    }

    /// A grid JPEG with a long edge of 256. Nil when `data` is not a readable image.
    static func folderJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let jpeg = out as Data
        guard !jpeg.isEmpty else { return nil }
        return jpeg
    }
}

/// Renames the main server has finished, waiting for the mirror. The list is first in, first out.
/// The file lives on the mirror share. A rename stays at the front until the mirror can do it.
/// File reads and writes stay off the main thread. `fileLock` keeps one list update at a time.
nonisolated enum MirrorQueue {
    static let file = "file"
    static let folder = "folder"
    static let pendingKey = "ZImageLibrary.mirrorOps"
    private static let opsName = ".zimage/mirror-ops.json"
    private static let fileLock = NSRecursiveLock()

    struct Op: Codable, Equatable, Sendable {
        var kind: String
        var from: String
        var to: String
    }

    enum Outcome: Equatable, Sendable {
        case applied
        case dropped
        case waiting
        case failed
    }

    private struct Document: Codable {
        var ops: [Op]
    }

    static func accepts(_ op: Op) -> Bool {
        guard op.kind == file || op.kind == folder, op.from != op.to else { return false }
        return photosPath(op.from) && photosPath(op.to)
    }

    /// The path a later copy should write, after every queued rename.
    static func destination(_ path: String, ops: [Op]) -> String {
        var current = path
        for op in ops {
            if op.kind == folder {
                if let shifted = FolderRename.shiftedRelative(current, from: op.from, to: op.to) {
                    current = shifted
                }
            } else if op.kind == file, current == op.from {
                current = op.to
            }
        }
        return current
    }

    /// The main file to read. A rename that already landed uses the new path.
    nonisolated static func sourceOnMain(listed: String, landed: String, mainRoot: URL, fileManager: FileManager = .default) -> String? {
        if fileManager.fileExists(atPath: mainRoot.appendingPathComponent(listed).path) { return listed }
        if landed != listed, fileManager.fileExists(atPath: mainRoot.appendingPathComponent(landed).path) {
            return landed
        }
        return nil
    }

    static func rescanFolders(_ op: Op) -> [String] {
        var seen: [String] = []
        for folder in [parent(op.from), parent(op.to)] where folder == "Photos" || folder.hasPrefix("Photos/") {
            if !seen.contains(folder) { seen.append(folder) }
        }
        return seen
    }

    static func load(root: URL, fileManager: FileManager = .default) -> [Op] {
        fileLock.lock()
        defer { fileLock.unlock() }
        let url = root.appendingPathComponent(opsName)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return document.ops
    }

    static func store(_ ops: [Op], root: URL, fileManager: FileManager = .default) throws {
        fileLock.lock()
        defer { fileLock.unlock() }
        let url = root.appendingPathComponent(opsName)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Document(ops: ops))
        try data.write(to: url, options: .atomic)
    }

    static func removeAll(root: URL, fileManager: FileManager = .default) {
        fileLock.lock()
        defer { fileLock.unlock() }
        try? fileManager.removeItem(at: root.appendingPathComponent(opsName))
    }

    static func enqueue(_ op: Op, mirrorRoot: URL?, defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        fileLock.lock()
        defer { fileLock.unlock() }
        guard accepts(op) else { return }
        if let mirrorRoot {
            flushPending(into: mirrorRoot, defaults: defaults, fileManager: fileManager)
            var ops = load(root: mirrorRoot, fileManager: fileManager)
            if ops.contains(op) { return }
            ops.append(op)
            if (try? store(ops, root: mirrorRoot, fileManager: fileManager)) != nil {
                clearPending(defaults: defaults)
                return
            }
        }
        var pending = loadPending(defaults: defaults)
        if pending.contains(op) { return }
        pending.append(op)
        savePending(pending, defaults: defaults)
    }

    static func flushPending(into root: URL, defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let pending = loadPending(defaults: defaults)
        guard !pending.isEmpty else { return }
        var ops = load(root: root, fileManager: fileManager)
        for item in pending where !ops.contains(item) {
            ops.append(item)
        }
        do {
            try store(ops, root: root, fileManager: fileManager)
            clearPending(defaults: defaults)
        } catch {
            return
        }
    }

    static func clearPending(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingKey)
    }

    /// Moves the head when its source is already on the mirror. The caller removes it from the list.
    static func apply(_ op: Op, root: URL, fileManager: FileManager = .default) -> Outcome {
        fileLock.lock()
        defer { fileLock.unlock() }
        guard accepts(op) else { return .dropped }
        let source = root.appendingPathComponent(op.from)
        let dest = root.appendingPathComponent(op.to)
        let sourceExists = fileManager.fileExists(atPath: source.path)
        let destExists = fileManager.fileExists(atPath: dest.path)
        if !sourceExists { return destExists ? .dropped : .waiting }
        if destExists { return .dropped }
        do {
            try moveItem(from: source, to: dest, fileManager: fileManager)
            if op.kind == file { moveSidecars(op, root: root, fileManager: fileManager) }
            return .applied
        } catch {
            return .failed
        }
    }

    static func commit(_ outcome: Outcome, head: Op, root: URL, fileManager: FileManager = .default) throws -> Bool {
        fileLock.lock()
        defer { fileLock.unlock() }
        var latest = load(root: root, fileManager: fileManager)
        guard latest.first == head else { return false }
        switch outcome {
        case .applied:
            latest.removeFirst()
            latest = rewrite(latest, after: head)
        case .dropped:
            latest.removeFirst()
            if rewritesAfterDrop(head, root: root, fileManager: fileManager) {
                latest = rewrite(latest, after: head)
            }
        case .waiting, .failed:
            return false
        }
        try store(latest, root: root, fileManager: fileManager)
        return true
    }

    /// Applies the front of the list once. Tests use this. The app applies the move off the main thread, then commits.
    static func advance(root: URL, defaults: UserDefaults = .standard, fileManager: FileManager = .default) -> Outcome {
        fileLock.lock()
        defer { fileLock.unlock() }
        flushPending(into: root, defaults: defaults, fileManager: fileManager)
        let ops = load(root: root, fileManager: fileManager)
        guard let head = ops.first else { return .waiting }
        let outcome = apply(head, root: root, fileManager: fileManager)
        if outcome == .applied || outcome == .dropped {
            _ = try? commit(outcome, head: head, root: root, fileManager: fileManager)
        }
        return outcome
    }

    static func rewrite(_ ops: [Op], after folder: Op) -> [Op] {
        guard folder.kind == Self.folder else { return ops }
        var next: [Op] = []
        for op in ops {
            var copy = op
            if let from = FolderRename.shiftedRelative(op.from, from: folder.from, to: folder.to) {
                copy.from = from
            }
            if let to = FolderRename.shiftedRelative(op.to, from: folder.from, to: folder.to) {
                copy.to = to
            }
            if copy.from != copy.to { next.append(copy) }
        }
        return next
    }

    static func rewritesAfterDrop(_ op: Op, root: URL, fileManager: FileManager = .default) -> Bool {
        fileLock.lock()
        defer { fileLock.unlock() }
        return op.kind == folder && !fileManager.fileExists(atPath: root.appendingPathComponent(op.from).path)
    }

    private static func photosPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return parts.first == "Photos" && parts.count >= 2 && parts.allSatisfy { $0 != "." && $0 != ".." }
    }

    private static func parent(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        if folder.isEmpty || folder == "." { return "Photos" }
        return folder
    }

    private static func sidecar(_ photo: String, ext: String) -> String {
        let folder = (photo as NSString).deletingLastPathComponent
        let stem = ((photo as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = stem + "." + ext
        if folder.isEmpty || folder == "." { return name }
        return folder + "/" + name
    }

    private static func moveSidecars(_ op: Op, root: URL, fileManager: FileManager) {
        for ext in MirrorDiff.sidecarExtensions {
            let from = sidecar(op.from, ext: ext)
            let to = sidecar(op.to, ext: ext)
            let source = root.appendingPathComponent(from)
            let dest = root.appendingPathComponent(to)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            if fileManager.fileExists(atPath: dest.path) { continue }
            try? moveItem(from: source, to: dest, fileManager: fileManager)
        }
    }

    private static func moveItem(from source: URL, to dest: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sameFolder = source.deletingLastPathComponent().path == dest.deletingLastPathComponent().path
        let caseOnly = sameFolder
            && source.lastPathComponent != dest.lastPathComponent
            && source.lastPathComponent.compare(dest.lastPathComponent, options: .caseInsensitive) == .orderedSame
        if caseOnly {
            let temp = source.deletingLastPathComponent().appendingPathComponent(".zimage-rename-\(UUID().uuidString)")
            try fileManager.moveItem(at: source, to: temp)
            do {
                try fileManager.moveItem(at: temp, to: dest)
            } catch {
                try? fileManager.moveItem(at: temp, to: source)
                throw error
            }
            return
        }
        try fileManager.moveItem(at: source, to: dest)
    }

    private static func loadPending(defaults: UserDefaults) -> [Op] {
        guard let data = defaults.data(forKey: pendingKey),
              let ops = try? JSONDecoder().decode([Op].self, from: data) else { return [] }
        return ops
    }

    private static func savePending(_ ops: [Op], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(ops) else { return }
        defaults.set(data, forKey: pendingKey)
    }
}
