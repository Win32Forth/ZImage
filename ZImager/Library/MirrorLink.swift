import Foundation

/// One main library and one mirror. The mirror copies the main server's folders and file names.
enum MirrorRoster {
    static let main = "main"
    static let mirror = "mirror"
    static let dutyKey = "ZImageLibrary.serverDuty"

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

/// Which mirror files are missing on the main server, and which main files the mirror still needs.
enum MirrorDiff {
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

    /// `photo.jpg` becomes `photo-2.jpg`, then `photo-3.jpg`, in the same folder.
    static func besidePath(_ relative: String, taken: Set<String>) -> String? {
        let file = (relative as NSString).lastPathComponent
        let folder = (relative as NSString).deletingLastPathComponent
        guard let name = besideName(file, taken: takenNames(in: folder, paths: taken)) else { return nil }
        if folder.isEmpty || folder == "." { return name }
        return folder + "/" + name
    }

    static func besideName(_ fileName: String, taken: Set<String>) -> String? {
        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }
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
}

/// Adds or removes `role: "mirror"` without changing the rest of the helper config.
enum MirrorConfigText {
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
enum MirrorConfigFile {
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

/// File copies for the mirror. Call these off the main thread. They do not open the catalog.
enum MirrorCopy {
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
        fileManager: FileManager = .default
    ) throws {
        let destRel = destRelative ?? relative
        guard relative.hasPrefix("Photos/"), destRel.hasPrefix("Photos/"),
              !relative.contains(".."), !destRel.contains("..") else { return }
        let source = sourceRoot.appendingPathComponent(relative)
        let dest = destRoot.appendingPathComponent(destRel)
        if fileManager.fileExists(atPath: dest.path) {
            if sameByteCount(source, dest, fileManager: fileManager) { return }
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

    /// Copies one photo beside the file of the same name. The new relative path is returned.
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

    static func safeUID(_ uid: String) -> Bool {
        !uid.isEmpty && !uid.contains("/") && !uid.contains(".")
    }
}

/// Renames the main server has finished, waiting for the mirror. The list is first in, first out.
/// The file lives on the mirror share. A rename stays at the front until the mirror can do it.
enum MirrorQueue {
    static let file = "file"
    static let folder = "folder"
    static let pendingKey = "ZImageLibrary.mirrorOps"
    private static let opsName = ".zimage/mirror-ops.json"

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
    static func sourceOnMain(listed: String, landed: String, mainRoot: URL, fileManager: FileManager = .default) -> String? {
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
        let url = root.appendingPathComponent(opsName)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return document.ops
    }

    static func store(_ ops: [Op], root: URL, fileManager: FileManager = .default) throws {
        let url = root.appendingPathComponent(opsName)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Document(ops: ops))
        try data.write(to: url, options: .atomic)
    }

    static func removeAll(root: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: root.appendingPathComponent(opsName))
    }

    static func enqueue(_ op: Op, mirrorRoot: URL?, defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
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
        op.kind == folder && !fileManager.fileExists(atPath: root.appendingPathComponent(op.from).path)
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
