import Foundation

extension LibraryBrowser {
    /// The server on screen is the archive. Date, move, merge, rename, and save stay off.
    var isMirror: Bool {
        MirrorRoster.locked()
    }

    /// Stops a copy between folders. The file already being copied finishes.
    func stopMirroring() {
        mirrorGeneration += 1
    }

    /// Red borders for this page. A path that exists on the main server, or whose recovery still exists, is clear.
    func refreshMirrorMarks() {
        mirrorMarkGeneration += 1
        let generation = mirrorMarkGeneration
        guard isMirror else {
            mirrorMissing = []
            return
        }
        let paths = rows.compactMap(\.relPath).filter { $0.hasPrefix("Photos/") }
        let servers = HelperServerList.load(defaults: .standard)
        guard let main = MirrorRoster.mainRow(in: servers),
              let root = LibraryFolderBookmark.url(from: main.bookmark) else {
            mirrorMissing = []
            return
        }
        let recovered = MirrorLedger.load()
        let opened = root.startAccessingSecurityScopedResource()
        Task {
            let missing = await Task.detached(priority: .utility) {
                MirrorDiff.missingPaths(paths, mainRoot: root, recovered: recovered)
            }.value
            if opened { root.stopAccessingSecurityScopedResource() }
            guard generation == self.mirrorMarkGeneration else { return }
            self.mirrorMissing = self.isMirror ? missing : []
        }
    }

    /// Copies the main server onto the mirror, one file at a time. Mirror-only files stay.
    func startMirroring() async {
        guard !mirrorBusy else {
            notice = "The mirror is still working through its list."
            return
        }
        let servers = HelperServerList.load(defaults: .standard)
        guard let main = MirrorRoster.mainRow(in: servers),
              let mirror = MirrorRoster.mirrorRow(in: servers),
              let mainRoot = LibraryFolderBookmark.url(from: main.bookmark),
              let mirrorRoot = LibraryFolderBookmark.url(from: mirror.bookmark) else {
            notice = "Choose a main server and a mirror, then start mirroring."
            return
        }
        let mainPath = mainRoot.standardizedFileURL.path
        let mirrorPath = mirrorRoot.standardizedFileURL.path
        guard mainPath != mirrorPath else {
            notice = "Choose two different servers."
            return
        }
        let mainPhotos = mainRoot.appendingPathComponent("Photos").path
        let mirrorPhotos = mirrorRoot.appendingPathComponent("Photos").path
        let files = FileManager.default
        guard files.isReadableFile(atPath: mainPhotos), files.isReadableFile(atPath: mirrorPhotos) else {
            notice = "Mount both servers, then start mirroring again."
            return
        }
        let notes = mirrorRoleNotes(mainRoot: mainRoot, mirrorRoot: mirrorRoot)
        mirrorGeneration += 1
        let generation = mirrorGeneration
        mirrorBusy = true
        defer { mirrorBusy = false }
        let mainOpen = mainRoot.startAccessingSecurityScopedResource()
        let mirrorOpen = mirrorRoot.startAccessingSecurityScopedResource()
        defer {
            if mainOpen { mainRoot.stopAccessingSecurityScopedResource() }
            if mirrorOpen { mirrorRoot.stopAccessingSecurityScopedResource() }
        }
        refreshMirrorMarks()
        let mirrorClient = pinnedClient(host: mirror.host)
        let mainClient = pinnedClient(host: main.host)
        MirrorQueue.flushPending(into: mirrorRoot)
        var pump = RenamePump()
        await pumpMirrorRenames(mirrorRoot: mirrorRoot, client: mirrorClient, generation: generation, pump: &pump)
        guard generation == mirrorGeneration else { return }
        notice = "Reading both libraries."
        let sizes = await Task.detached(priority: .utility) { () -> (main: [String: Int64], mirror: [String: Int64]) in
            (MirrorCopy.photoFiles(root: mainRoot), MirrorCopy.photoFiles(root: mirrorRoot))
        }.value
        guard generation == mirrorGeneration else { return }
        if sizes.main.isEmpty {
            var text = "The main server's Photos folder had no files to copy."
            text += renameSentence(renamed: pump.renamed, failure: pump.failure)
            if !notes.isEmpty { text += " " + notes.joined(separator: " ") }
            noteMirrorResult(text)
            return
        }
        let needed = MirrorDiff.filesToCopy(mainBytes: sizes.main, mirrorBytes: sizes.mirror)
        var byFolder: [String: [String]] = [:]
        for path in needed {
            let folder = (path as NSString).deletingLastPathComponent
            byFolder[folder, default: []].append(path)
        }
        var copied = 0
        var failed = 0
        var stopped = false
        var rescanBlocked = false
        let total = needed.count
        for folder in byFolder.keys.sorted() {
            if generation != mirrorGeneration {
                stopped = true
                break
            }
            var landedFolders: [String] = []
            for path in byFolder[folder] ?? [] {
                if generation != mirrorGeneration {
                    stopped = true
                    break
                }
                await pumpMirrorRenames(mirrorRoot: mirrorRoot, client: mirrorClient, generation: generation, pump: &pump)
                if generation != mirrorGeneration {
                    stopped = true
                    break
                }
                let queued = pump.done + MirrorQueue.load(root: mirrorRoot)
                let landed = MirrorQueue.destination(path, ops: queued)
                guard let sourceRel = MirrorQueue.sourceOnMain(listed: path, landed: landed, mainRoot: mainRoot) else {
                    failed += 1
                    continue
                }
                notice = "Copying \(copied + failed + 1) of \(total)."
                let ok = await Task.detached(priority: .utility) {
                    do {
                        try MirrorCopy.copyFile(
                            relative: sourceRel,
                            from: mainRoot,
                            to: mirrorRoot,
                            destRelative: landed
                        )
                        return true
                    } catch {
                        return false
                    }
                }.value
                if ok {
                    copied += 1
                    let landedFolder = (landed as NSString).deletingLastPathComponent
                    if landedFolder != folder, !landedFolders.contains(landedFolder) {
                        landedFolders.append(landedFolder)
                    }
                } else {
                    failed += 1
                }
                await Task.yield()
            }
            if stopped { break }
            if !rescanBlocked, let mirrorClient {
                let continued = await rescanCopiedFolder(folder, client: mirrorClient, generation: generation)
                if !continued { rescanBlocked = true }
                if !rescanBlocked {
                    for landedFolder in landedFolders {
                        let continued = await rescanCopiedFolder(landedFolder, client: mirrorClient, generation: generation)
                        if !continued {
                            rescanBlocked = true
                            break
                        }
                    }
                }
            }
        }
        if !stopped {
            await pumpMirrorRenames(mirrorRoot: mirrorRoot, client: mirrorClient, generation: generation, pump: &pump)
            if generation != mirrorGeneration { stopped = true }
        }
        var editCount = 0
        var waiting = 0
        var pairNote = ""
        if stopped {
            // The file in hand finished. Leave the rest of the main server where it is.
        } else if let mainClient, let mirrorClient {
            notice = "Reading the catalogs."
            let mainIndex = await pathIndex(on: mainClient, generation: generation)
            let mirrorIndex = await pathIndex(on: mirrorClient, generation: generation)
            if generation != mirrorGeneration {
                stopped = true
            } else {
                let edited = await Task.detached(priority: .utility) {
                    MirrorCopy.editUIDs(root: mainRoot)
                }.value
                var pairs: [(String, String)] = []
                for (path, mainUID) in mainIndex {
                    guard edited.contains(mainUID), let mirrorUID = mirrorIndex[path] else { continue }
                    pairs.append((mainUID, mirrorUID))
                }
                for path in needed where mainIndex[path] != nil && mirrorIndex[path] == nil {
                    waiting += 1
                }
                notice = "Copying edit files."
                editCount = await Task.detached(priority: .utility) {
                    var count = 0
                    for pair in pairs {
                        count += MirrorCopy.copyEdits(mainUID: pair.0, mirrorUID: pair.1, from: mainRoot, to: mirrorRoot)
                    }
                    return count
                }.value
            }
        } else {
            pairNote = "Pair both servers so the edit files can be copied."
        }
        if libraryRoot.standardizedFileURL.path == mirrorPath {
            await reload(media: "photo")
        }
        refreshMirrorMarks()
        noteMirrorResult(finishedMirror(
            copied: copied,
            failed: failed,
            edits: editCount,
            waiting: waiting,
            stopped: stopped,
            pairNote: pairNote,
            roleNotes: notes,
            renamed: pump.renamed,
            renameFailure: pump.failure
        ))
    }

    /// Leaves an unlink message in place when the pair was cleared during the copy.
    private func noteMirrorResult(_ text: String) {
        guard MirrorRoster.mirrorRow(in: HelperServerList.load(defaults: .standard)) != nil else { return }
        notice = text
    }

    /// Copies the selection onto the main server under a new name. The mirror file stays.
    func recoverMirrorSelection() async {
        guard isMirror, !removalBusy else { return }
        guard !mirrorBusy else {
            notice = "The mirror is still working through its list."
            return
        }
        let assets = recoverTargets()
        guard !assets.isEmpty else {
            notice = "Select a photo to recover."
            return
        }
        let servers = HelperServerList.load(defaults: .standard)
        guard let main = MirrorRoster.mainRow(in: servers),
              let mirror = MirrorRoster.mirrorRow(in: servers),
              let mainRoot = LibraryFolderBookmark.url(from: main.bookmark),
              let mirrorRoot = LibraryFolderBookmark.url(from: mirror.bookmark) else {
            notice = "Mount both servers, then recover again."
            return
        }
        let files = FileManager.default
        guard files.isReadableFile(atPath: mainRoot.appendingPathComponent("Photos").path),
              files.isReadableFile(atPath: mirrorRoot.appendingPathComponent("Photos").path) else {
            notice = "Mount both servers, then recover again."
            return
        }
        guard let mainClient = pinnedClient(host: main.host) else {
            notice = "Pair with the main server, then recover again."
            return
        }
        let mainOpen = mainRoot.startAccessingSecurityScopedResource()
        let mirrorOpen = mirrorRoot.startAccessingSecurityScopedResource()
        defer {
            if mainOpen { mainRoot.stopAccessingSecurityScopedResource() }
            if mirrorOpen { mirrorRoot.stopAccessingSecurityScopedResource() }
        }
        mirrorBusy = true
        defer { mirrorBusy = false }
        var landed = 0
        var failed = 0
        for asset in assets {
            guard let relative = asset.relPath, relative.hasPrefix("Photos/"), !relative.contains("..") else {
                failed += 1
                continue
            }
            notice = "Recovering \(landed + failed + 1) of \(assets.count)."
            let sourceUID = asset.uid
            let destRel = await Task.detached(priority: .utility) { () -> String? in
                do {
                    let dest = try MirrorCopy.copyBeside(relative: relative, from: mirrorRoot, to: mainRoot)
                    MirrorCopy.copyRecoverSidecars(photoSource: relative, photoDest: dest, from: mirrorRoot, to: mainRoot)
                    return dest
                } catch {
                    return nil
                }
            }.value
            guard let destRel else {
                failed += 1
                continue
            }
            MirrorLedger.remember(mirror: relative, main: destRel)
            let folder = (destRel as NSString).deletingLastPathComponent
            _ = await rescanCopiedFolder(folder, client: mainClient, generation: mirrorGeneration)
            if let newUID = await uid(for: destRel, client: mainClient) {
                _ = await Task.detached(priority: .utility) {
                    MirrorCopy.copyEdits(mainUID: sourceUID, mirrorUID: newUID, from: mirrorRoot, to: mainRoot)
                }.value
            }
            landed += 1
            await Task.yield()
        }
        refreshMirrorMarks()
        if failed == 0 {
            notice = landed == 1
                ? "Recovered 1 photo beside the file on the main server."
                : "Recovered \(landed) photos beside the files on the main server."
        } else {
            notice = "Recovered \(landed) \(landed == 1 ? "photo" : "photos"). \(failed) could not be copied."
        }
    }

    /// The selected files on this page that can move back to the main server or into Photos/_Removed.
    func recoverTargets() -> [LibraryAsset] {
        var chosen = rows.filter { selectedUIDs.contains($0.uid) }
        if chosen.isEmpty, let selectedUID, let one = rows.first(where: { $0.uid == selectedUID }) {
            chosen = [one]
        }
        return chosen.filter { asset in
            guard let rel = asset.relPath else { return false }
            return rel.hasPrefix("Photos/") && !parkedInLibrary(asset)
        }
    }

    /// Clears the pair so the mirror can be used as the main server. Photos stay where they are.
    func unlinkMirrors() {
        stopMirroring()
        let servers = HelperServerList.load(defaults: .standard)
        var restart = false
        var oldHelper = false
        if let mirror = MirrorRoster.mirrorRow(in: servers),
           let root = LibraryFolderBookmark.url(from: mirror.bookmark) {
            let opened = root.startAccessingSecurityScopedResource()
            defer { if opened { root.stopAccessingSecurityScopedResource() } }
            switch MirrorConfigFile.apply(role: "", libraryRoot: root) {
            case .updated:
                restart = true
            case .skippedOldHelper:
                oldHelper = true
            default:
                break
            }
            MirrorQueue.removeAll(root: root)
        }
        MirrorQueue.clearPending()
        HelperServerList.store(MirrorRoster.unlink(servers), defaults: .standard)
        mirrorMissing = []
        mirrorMarkGeneration += 1
        if restart {
            notice = "The servers are unlinked. Restart that helper before editing it."
        } else if oldHelper {
            notice = "The servers are unlinked. This mirror can be the main server."
        } else {
            notice = "The servers are unlinked. This mirror can be the main server."
        }
    }

    private func mirrorRoleNotes(mainRoot: URL, mirrorRoot: URL) -> [String] {
        var notes: [String] = []
        switch MirrorConfigFile.apply(role: MirrorRoster.mirror, libraryRoot: mirrorRoot) {
        case .updated:
            notes.append("Restart the mirror helper so it refuses edits.")
        case .skippedOldHelper:
            notes.append("The mirror screen is read-only. Update the mirror helper to 1.9.0 and restart it so the server also refuses edits.")
        case .unreadable:
            notes.append("The mirror helper config was left as it is.")
        case .unchanged:
            break
        }
        if MirrorConfigFile.apply(role: "", libraryRoot: mainRoot) == .updated {
            notes.append("Restart the main helper so it accepts edits.")
        }
        return notes
    }

    private func finishedMirror(
        copied: Int,
        failed: Int,
        edits: Int,
        waiting: Int,
        stopped: Bool,
        pairNote: String,
        roleNotes: [String],
        renamed: Int,
        renameFailure: String?
    ) -> String {
        var parts: [String] = []
        if stopped { parts.append("Mirroring stopped.") }
        let renameNote = renameSentence(renamed: renamed, failure: renameFailure)
        if copied == 0 && failed == 0 && edits == 0 && waiting == 0 && pairNote.isEmpty && renameNote.isEmpty && !stopped {
            parts.append("The mirror matches the main server.")
        } else {
            if !renameNote.isEmpty { parts.append(renameNote.trimmingCharacters(in: .whitespaces)) }
            if copied > 0 { parts.append(copied == 1 ? "Copied 1 file." : "Copied \(copied) files.") }
            if edits > 0 { parts.append(edits == 1 ? "Copied 1 edit file." : "Copied \(edits) edit files.") }
            if failed > 0 { parts.append(failed == 1 ? "1 file could not be copied." : "\(failed) files could not be copied.") }
            if waiting > 0 {
                parts.append(waiting == 1
                    ? "1 new file is waiting for the mirror catalog. Run mirroring again after that helper finishes its walk."
                    : "\(waiting) new files are waiting for the mirror catalog. Run mirroring again after that helper finishes its walk.")
            }
        }
        if !pairNote.isEmpty { parts.append(pairNote) }
        parts.append(contentsOf: roleNotes)
        if parts.isEmpty { parts.append("The mirror matches the main server.") }
        return parts.joined(separator: " ")
    }

    /// Records one rename that already landed on the main server. The mirror applies it later, in order.
    func passMainRename(kind: String, from: String, to: String) {
        let op = MirrorQueue.Op(kind: kind, from: from, to: to)
        guard MirrorQueue.accepts(op), renameFeedsMirror() else { return }
        let root = mirrorShareRoot()
        let opened = root?.startAccessingSecurityScopedResource() ?? false
        defer { if let root, opened { root.stopAccessingSecurityScopedResource() } }
        MirrorQueue.enqueue(op, mirrorRoot: root)
        guard !mirrorBusy else { return }
        mirrorBusy = true
        Task { await self.runMirrorRenames() }
    }

    private func renameFeedsMirror() -> Bool {
        let servers = HelperServerList.load(defaults: .standard)
        guard let main = MirrorRoster.mainRow(in: servers),
              MirrorRoster.mirrorRow(in: servers) != nil,
              let root = LibraryFolderBookmark.url(from: main.bookmark) else { return false }
        return root.standardizedFileURL.path == libraryRoot.standardizedFileURL.path
    }

    private func mirrorShareRoot() -> URL? {
        let servers = HelperServerList.load(defaults: .standard)
        guard let mirror = MirrorRoster.mirrorRow(in: servers) else { return nil }
        return LibraryFolderBookmark.url(from: mirror.bookmark)
    }

    private struct RenamePump {
        var renamed = 0
        var failure: String?
        var hold = false
        /// Renames already taken off the list during this pass. Later copies still follow them.
        var done: [MirrorQueue.Op] = []
    }

    private func renameSentence(renamed: Int, failure: String?) -> String {
        var text = ""
        if renamed == 1 {
            text += " Renamed 1 item on the mirror."
        } else if renamed > 1 {
            text += " Renamed \(renamed) items on the mirror."
        }
        if let failure {
            text += " The mirror could not rename \(failure). That rename stays first in the mirror's list."
        }
        return text
    }

    /// Applies queued renames until one has to wait. `mirrorBusy` is already set.
    private func runMirrorRenames() async {
        defer { mirrorBusy = false }
        let generation = mirrorGeneration
        guard let mirrorRoot = mirrorShareRoot() else { return }
        let opened = mirrorRoot.startAccessingSecurityScopedResource()
        defer { if opened { mirrorRoot.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: mirrorRoot.appendingPathComponent("Photos").path) else { return }
        let host = MirrorRoster.mirrorRow(in: HelperServerList.load(defaults: .standard))?.host ?? ""
        let client = pinnedClient(host: host)
        var pump = RenamePump()
        await pumpMirrorRenames(mirrorRoot: mirrorRoot, client: client, generation: generation, pump: &pump)
        guard generation == mirrorGeneration else { return }
        guard MirrorRoster.mirrorRow(in: HelperServerList.load(defaults: .standard)) != nil else { return }
        let sentence = renameSentence(renamed: pump.renamed, failure: pump.failure)
        if !sentence.isEmpty { notice = sentence.trimmingCharacters(in: .whitespaces) }
    }

    /// One rename at a time. A file that is not on the mirror yet stays at the front.
    private func pumpMirrorRenames(
        mirrorRoot: URL,
        client: HelperClient?,
        generation: Int,
        pump: inout RenamePump
    ) async {
        guard !pump.hold else { return }
        var steps = 0
        while generation == mirrorGeneration {
            steps += 1
            if steps > 10000 {
                pump.hold = true
                return
            }
            let ops = MirrorQueue.load(root: mirrorRoot)
            guard let head = ops.first else { return }
            let sourceExists = FileManager.default.fileExists(atPath: mirrorRoot.appendingPathComponent(head.from).path)
            let outcome = await Task.detached(priority: .utility) {
                MirrorQueue.apply(head, root: mirrorRoot)
            }.value
            if generation != mirrorGeneration { return }
            if outcome == .applied || (outcome == .dropped && !sourceExists) {
                pump.done.append(head)
            }
            switch outcome {
            case .waiting:
                return
            case .failed:
                pump.hold = true
                pump.failure = (head.to as NSString).lastPathComponent
                return
            case .applied, .dropped:
                do {
                    let wrote = try MirrorQueue.commit(outcome, head: head, root: mirrorRoot)
                    if !wrote { return }
                } catch {
                    pump.hold = true
                    pump.failure = (head.to as NSString).lastPathComponent
                    return
                }
                if outcome == .applied {
                    pump.renamed += 1
                    if let client {
                        for folder in MirrorQueue.rescanFolders(head) {
                            let continued = await rescanCopiedFolder(folder, client: client, generation: generation)
                            if !continued { break }
                        }
                    }
                }
            }
        }
    }

    /// False when the mirror helper is already walking and further rescans should wait.
    private func rescanCopiedFolder(_ folder: String, client: HelperClient, generation: Int) async -> Bool {
        guard folder == "Photos" || folder.hasPrefix("Photos/") else { return true }
        if generation != mirrorGeneration { return true }
        switch await client.startFolderRescan(prefix: folder) {
        case .busy:
            return false
        case .status:
            await waitForFolderScan(client, generation: generation)
            return true
        default:
            return true
        }
    }

    private func waitForFolderScan(_ client: HelperClient, generation: Int) async {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if generation != mirrorGeneration { return }
            switch await client.folderRescanStatus() {
            case .status(let status):
                switch status.runState {
                case "", "idle", "completed", "failed":
                    return
                default:
                    break
                }
            default:
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func pathIndex(on client: HelperClient, generation: Int) async -> [String: String] {
        var index: [String: String] = [:]
        var cursor: String?
        var seen = Set<String>()
        for _ in 0..<5000 {
            if generation != mirrorGeneration { break }
            let page: LibraryPage
            do {
                page = try await client.assets(media: nil, under: "Photos", cursor: cursor)
            } catch {
                break
            }
            for row in page.rows {
                if let rel = row.relPath, rel.hasPrefix("Photos/") {
                    index[rel] = row.uid
                }
            }
            let next = page.nextCursor
            if next.isEmpty || page.rows.isEmpty || !seen.insert(next).inserted { break }
            cursor = next
        }
        return index
    }

    private func uid(for relative: String, client: HelperClient) async -> String? {
        let folder = (relative as NSString).deletingLastPathComponent
        var cursor: String?
        var seen = Set<String>()
        for _ in 0..<500 {
            let page: LibraryPage
            do {
                page = try await client.assets(media: nil, under: folder, cursor: cursor)
            } catch {
                return nil
            }
            if let row = page.rows.first(where: { $0.relPath == relative }) {
                return row.uid
            }
            let next = page.nextCursor
            if next.isEmpty || page.rows.isEmpty || !seen.insert(next).inserted { return nil }
            cursor = next
        }
        return nil
    }

    private func pinnedClient(host: String) -> HelperClient? {
        guard HelperClient.isIPv4(host),
              let secret = try? KeychainTokenStore.load(host: host),
              let pin = Data(base64Encoded: secret.pinBase64) else { return nil }
        let pinned = PinnedHelperSession(pin: pin)
        return HelperClient(
            credentials: HelperCredentials(host: host, pin: pin, token: secret.token),
            send: { request in
                try await pinned.send(request)
            }
        )
    }
}
