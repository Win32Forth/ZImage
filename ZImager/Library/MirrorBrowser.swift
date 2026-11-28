import Foundation

/// Edit in Library either names the main server to open, or the sentence that says why it stayed.
struct MirrorLibraryOpen {
    var serverID: String?
    var message: String?
}

extension LibraryBrowser {
    /// The server on screen is the archive. Date, move, merge, rename, and save stay off. Delete ALL on Photos/_Removed stays on.
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

    /// Continues a linked pair after launch. A finished pass stays where it is.
    func resumeLinkedMirror() {
        guard !mirrorLaunchResumeDone else { return }
        mirrorLaunchResumeDone = true
        Task { await self.continueLinkedMirror() }
    }

    private func continueLinkedMirror() async {
        guard !mirrorBusy else { return }
        let servers = HelperServerList.load(defaults: .standard)
        guard let main = MirrorRoster.mainRow(in: servers),
              let mirror = MirrorRoster.mirrorRow(in: servers),
              let mirrorRoot = LibraryFolderBookmark.url(from: mirror.bookmark) else { return }
        let opened = mirrorRoot.startAccessingSecurityScopedResource()
        let place = await Task.detached(priority: .utility) {
            MirrorProgress.load(root: mirrorRoot)
        }.value
        if opened { mirrorRoot.stopAccessingSecurityScopedResource() }
        guard MirrorProgress.shouldContinue(place, mainID: main.id, mirrorID: mirror.id) else { return }
        await startMirroring()
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
        notice = "Reading the main library."
        let mounted = await Task.detached(priority: .utility) {
            let files = FileManager.default
            return files.isReadableFile(atPath: mainPhotos) && files.isReadableFile(atPath: mirrorPhotos)
        }.value
        guard mounted else {
            notice = "Mount both servers, then start mirroring again."
            return
        }
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
        var notes = await Task.detached(priority: .utility) {
            Self.mirrorRoleNotes(mainRoot: mainRoot, mirrorRoot: mirrorRoot)
        }.value
        await Task.detached(priority: .utility) {
            MirrorQueue.flushPending(into: mirrorRoot)
        }.value
        var pump = RenamePump()
        await pumpMirrorRenames(mirrorRoot: mirrorRoot, client: mirrorClient, generation: generation, pump: &pump)
        guard generation == mirrorGeneration else { return }
        var place = await Task.detached(priority: .utility) {
            MirrorProgress.restored(from: mirrorRoot, mainID: main.id, mirrorID: mirror.id)
        }.value
        let resumed = !place.folder.isEmpty
        if place.folder.isEmpty {
            notice = "Reading the main library."
        } else {
            notice = "Continuing the mirror from \(place.folder)."
        }
        var copied = 0
        var failed = 0
        var checked = 0
        var copiedPaths: [String] = []
        var stopped = false
        var unreadable = false
        var rescanBlocked = false
        let outcome = await copyMirrorTree(
            folder: "Photos",
            mainRoot: mainRoot,
            mirrorRoot: mirrorRoot,
            place: &place,
            generation: generation,
            client: mirrorClient,
            pump: &pump,
            copied: &copied,
            failed: &failed,
            checked: &checked,
            copiedPaths: &copiedPaths,
            rescanBlocked: &rescanBlocked
        )
        switch outcome {
        case .stopped:
            stopped = true
        case .unreadable:
            unreadable = true
        case .finished:
            place.folder = "Photos"
            place.file = ""
            place.filesDone = true
            place.subtreeDone = true
            place.finished = false
            await rememberMirrorPlace(place, root: mirrorRoot)
        }
        if outcome == .finished && !place.retry.isEmpty {
            let retryStopped = await retryMirrorFiles(
                paths: place.retry,
                mainRoot: mainRoot,
                mirrorRoot: mirrorRoot,
                place: &place,
                generation: generation,
                client: mirrorClient,
                pump: &pump,
                copied: &copied,
                failed: &failed,
                copiedPaths: &copiedPaths
            )
            if retryStopped { stopped = true }
        }
        if outcome == .finished && !resumed && checked == 0 && copied == 0 && failed == 0 {
            var text = "The main server's Photos folder had no files to copy."
            text += renameSentence(renamed: pump.renamed, failure: pump.failure)
            if !notes.isEmpty { text += " " + notes.joined(separator: " ") }
            noteMirrorResult(text)
            return
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
                for path in copiedPaths where mainIndex[path] != nil && mirrorIndex[path] == nil {
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
        if !stopped && !unreadable {
            place.finished = true
            await rememberMirrorPlace(place, root: mirrorRoot)
        }
        if unreadable {
            notes.append("A folder on the main server could not be read. Start mirroring again to continue from the saved place.")
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

    private enum MirrorPass {
        case finished
        case stopped
        case unreadable
    }

    /// Confirms one folder, then its child folders, off the main thread. The saved place skips folders already confirmed.
    private func copyMirrorTree(
        folder: String,
        mainRoot: URL,
        mirrorRoot: URL,
        place: inout MirrorProgress.Place,
        generation: Int,
        client: HelperClient?,
        pump: inout RenamePump,
        copied: inout Int,
        failed: inout Int,
        checked: inout Int,
        copiedPaths: inout [String],
        rescanBlocked: inout Bool
    ) async -> MirrorPass {
        if generation != mirrorGeneration { return .stopped }
        let action = MirrorProgress.step(folder: folder, place: place)
        if action == .skipTree { return .finished }
        let listed = await Task.detached(priority: .utility) {
            MirrorCopy.listFolder(folder, root: mainRoot)
        }.value
        guard listed.readable else { return .unreadable }
        if action != .skipFiles {
            await pumpMirrorRenames(mirrorRoot: mirrorRoot, client: client, generation: generation, pump: &pump)
            if generation != mirrorGeneration { return .stopped }
            let loaded = await Task.detached(priority: .utility) {
                MirrorQueue.load(root: mirrorRoot)
            }.value
            var queued = pump.done + loaded
            var fresh: [String] = []
            var sinceSave = 0
            for file in listed.files {
                if generation != mirrorGeneration {
                    await rememberMirrorPlace(place, root: mirrorRoot)
                    return .stopped
                }
                if MirrorProgress.skipFile(file.name, place: place, folder: folder) { continue }
                let path = folder + "/" + file.name
                let landed = MirrorQueue.destination(path, ops: queued)
                let decision = await Task.detached(priority: .utility) { () -> (source: String, write: Bool)? in
                    guard let sourceRel = MirrorQueue.sourceOnMain(listed: path, landed: landed, mainRoot: mainRoot) else {
                        return nil
                    }
                    return (sourceRel, MirrorCopy.needsCopy(relative: sourceRel, destRelative: landed, from: mainRoot, to: mirrorRoot))
                }.value
                guard let decision else {
                    failed += 1
                    place.folder = folder
                    place.file = file.name
                    place.filesDone = false
                    place.subtreeDone = false
                    continue
                }
                let sourceRel = decision.source
                checked += 1
                if decision.write {
                    await pumpMirrorRenames(mirrorRoot: mirrorRoot, client: client, generation: generation, pump: &pump)
                    if generation != mirrorGeneration {
                        await rememberMirrorPlace(place, root: mirrorRoot)
                        return .stopped
                    }
                    let loaded = await Task.detached(priority: .utility) {
                        MirrorQueue.load(root: mirrorRoot)
                    }.value
                    queued = pump.done + loaded
                    notice = "Copying \(file.name). Checked \(checked). Copied \(copied)."
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
                        copiedPaths.append(landed)
                        fresh.append(landed)
                        place.retry.removeAll { $0 == path }
                    } else {
                        failed += 1
                        if !place.retry.contains(path) { place.retry.append(path) }
                    }
                }
                place.folder = folder
                place.file = file.name
                place.filesDone = false
                place.subtreeDone = false
                sinceSave += 1
                if sinceSave >= 20 {
                    sinceSave = 0
                    await rememberMirrorPlace(place, root: mirrorRoot)
                    notice = "Checked \(checked). Copied \(copied). \(folder)"
                }
                await Task.yield()
            }
            place.filesDone = true
            place.file = ""
            await rememberMirrorPlace(place, root: mirrorRoot)
            if !rescanBlocked, !fresh.isEmpty, let client {
                let continued = await rescanCopiedPaths(fresh, client: client, generation: generation)
                if !continued { rescanBlocked = true }
            }
        }
        for child in listed.children {
            let childPass = await copyMirrorTree(
                folder: child,
                mainRoot: mainRoot,
                mirrorRoot: mirrorRoot,
                place: &place,
                generation: generation,
                client: client,
                pump: &pump,
                copied: &copied,
                failed: &failed,
                checked: &checked,
                copiedPaths: &copiedPaths,
                rescanBlocked: &rescanBlocked
            )
            if childPass != .finished { return childPass }
        }
        place.folder = folder
        place.file = ""
        place.filesDone = true
        place.subtreeDone = true
        await rememberMirrorPlace(place, root: mirrorRoot)
        return .finished
    }

    /// Tries files that failed earlier in this pass. A stop leaves the rest of the list saved.
    private func retryMirrorFiles(
        paths: [String],
        mainRoot: URL,
        mirrorRoot: URL,
        place: inout MirrorProgress.Place,
        generation: Int,
        client: HelperClient?,
        pump: inout RenamePump,
        copied: inout Int,
        failed: inout Int,
        copiedPaths: inout [String]
    ) async -> Bool {
        var still: [String] = []
        for (index, path) in paths.enumerated() {
            if generation != mirrorGeneration {
                still.append(contentsOf: paths[index...])
                place.retry = still
                await rememberMirrorPlace(place, root: mirrorRoot)
                return true
            }
            await pumpMirrorRenames(mirrorRoot: mirrorRoot, client: client, generation: generation, pump: &pump)
            let loaded = await Task.detached(priority: .utility) {
                MirrorQueue.load(root: mirrorRoot)
            }.value
            let queued = pump.done + loaded
            let landed = MirrorQueue.destination(path, ops: queued)
            let decision = await Task.detached(priority: .utility) { () -> (source: String, write: Bool)? in
                guard let sourceRel = MirrorQueue.sourceOnMain(listed: path, landed: landed, mainRoot: mainRoot) else {
                    return nil
                }
                return (sourceRel, MirrorCopy.needsCopy(relative: sourceRel, destRelative: landed, from: mainRoot, to: mirrorRoot))
            }.value
            guard let decision else { continue }
            let sourceRel = decision.source
            if !decision.write { continue }
            notice = "Copying \( (path as NSString).lastPathComponent ) again."
            let ok = await Task.detached(priority: .utility) {
                do {
                    try MirrorCopy.copyFile(relative: sourceRel, from: mainRoot, to: mirrorRoot, destRelative: landed)
                    return true
                } catch {
                    return false
                }
            }.value
            if ok {
                copied += 1
                if failed > 0 { failed -= 1 }
                copiedPaths.append(path)
            } else {
                still.append(path)
            }
            await Task.yield()
        }
        place.retry = still
        await rememberMirrorPlace(place, root: mirrorRoot)
        return false
    }

    private func rememberMirrorPlace(_ place: MirrorProgress.Place, root: URL) async {
        let saved = place
        await Task.detached(priority: .utility) {
            MirrorProgress.store(saved, root: root)
        }.value
    }

    /// Leaves an unlink message in place when the pair was cleared during the copy.
    private func noteMirrorResult(_ text: String) {
        guard MirrorRoster.mirrorRow(in: HelperServerList.load(defaults: .standard)) != nil else { return }
        notice = text
    }

    /// Leaves the mirror and opens this photo on the main server, in that photo's folder.
    /// A recovered copy uses the beside name the ledger stored.
    /// An orphan that was never recovered stays on the mirror.
    /// `switched` runs as soon as the active server becomes the main server, before the folder read.
    func editOpenPhotoOnMain(
        relative: String?,
        switched: (@MainActor (String) -> Void)? = nil
    ) async -> MirrorLibraryOpen {
        guard isMirror else { return MirrorLibraryOpen() }
        guard let relative, relative.hasPrefix("Photos/"), !relative.contains("..") else {
            return refused("Open a photo, then edit it in the library.")
        }
        let servers = HelperServerList.load(defaults: .standard)
        guard let main = MirrorRoster.mainRow(in: servers) else {
            return refused("Choose a main server, then edit this photo in the library.")
        }
        guard let root = LibraryFolderBookmark.url(from: main.bookmark) else {
            return refused("Mount the main server, then edit this photo in the library.")
        }
        let recovered = MirrorLedger.load()
        let opened = root.startAccessingSecurityScopedResource()
        let landed = await Task.detached(priority: .utility) {
            MirrorDiff.mainPath(mirror: relative, root: root, recovered: recovered)
        }.value
        if opened { root.stopAccessingSecurityScopedResource() }
        guard let landed else {
            return refused("This image is not in the main library.")
        }
        guard HelperServerList.select(main.id, defaults: .standard) != nil,
              let url = LibraryFolderBookmark.resolve(defaults: .standard) else {
            return refused("ZImager could not open the main server's folder.")
        }
        switched?(main.id)
        adoptLibraryRoot(url)
        connect(LibraryHost.client())
        // connect() puts the grid back on Photos. This read puts the photo's folder back and selects it.
        librarySection = "Photos"
        let parent = (landed as NSString).deletingLastPathComponent
        let folder = LibrarySwitch.folderToKeep(parent.isEmpty ? DisplayFolder.root : parent) ?? DisplayFolder.root
        await keepLibraryPlace(folder: folder, paths: [landed], primary: landed, opening: true)
        if switchNeedsFolderView {
            return MirrorLibraryOpen(message: notice)
        }
        let listed = rows.contains { $0.relPath?.caseInsensitiveCompare(landed) == .orderedSame }
        if listed {
            if notice == nil {
                notice = "Editing this photo on \(main.name)."
            }
        } else {
            notice = "This photo is on the main server. The catalog has not listed it yet."
        }
        return MirrorLibraryOpen(serverID: main.id, message: notice)
    }

    /// Copies this orphan beside the same name on the main server, then opens that copy.
    /// A file that is already on the main server opens without another copy.
    func recoverAndEditOpen(
        relative: String?,
        sourceUID: String?,
        switched: (@MainActor (String) -> Void)? = nil
    ) async -> MirrorLibraryOpen {
        guard isMirror else { return MirrorLibraryOpen() }
        guard let relative, relative.hasPrefix("Photos/"), !relative.contains("..") else {
            return refused("Open a photo, then edit it in the library.")
        }
        guard !removalBusy else {
            return refused("A recover is already running.")
        }
        let servers = HelperServerList.load(defaults: .standard)
        guard let main = MirrorRoster.mainRow(in: servers),
              let mirror = MirrorRoster.mirrorRow(in: servers),
              let mainRoot = LibraryFolderBookmark.url(from: main.bookmark),
              let mirrorRoot = LibraryFolderBookmark.url(from: mirror.bookmark) else {
            return refused("Mount both servers, then recover again.")
        }
        let files = FileManager.default
        guard files.isReadableFile(atPath: mainRoot.appendingPathComponent("Photos").path),
              files.isReadableFile(atPath: mirrorRoot.appendingPathComponent("Photos").path) else {
            return refused("Mount both servers, then recover again.")
        }
        guard let mainClient = pinnedClient(host: main.host) else {
            return refused("Pair with the main server, then recover again.")
        }
        let recovered = MirrorLedger.load()
        let mainOpen = mainRoot.startAccessingSecurityScopedResource()
        let mirrorOpen = mirrorRoot.startAccessingSecurityScopedResource()
        let existing = await Task.detached(priority: .utility) {
            MirrorDiff.mainPath(mirror: relative, root: mainRoot, recovered: recovered)
        }.value
        let copied: String?
        if existing == nil {
            notice = "Recovering this photo."
            let uid = sourceUID ?? rows.first { $0.relPath == relative }?.uid
            copied = await recoverOne(
                relative: relative,
                sourceUID: uid,
                mainRoot: mainRoot,
                mirrorRoot: mirrorRoot,
                mainClient: mainClient
            )
        } else {
            copied = existing
        }
        if mainOpen { mainRoot.stopAccessingSecurityScopedResource() }
        if mirrorOpen { mirrorRoot.stopAccessingSecurityScopedResource() }
        guard copied != nil else {
            return refused("This photo could not be copied onto the main server.")
        }
        if existing == nil {
            refreshMirrorMarks()
        }
        return await editOpenPhotoOnMain(relative: relative, switched: switched)
    }

    /// Keeps the mirror on screen and records the sentence Image view shows under Edit in Library.
    private func refused(_ message: String) -> MirrorLibraryOpen {
        notice = message
        return MirrorLibraryOpen(message: message)
    }

    /// Copies the selection onto the main server under a new name. The mirror file stays.
    func recoverMirrorSelection() async {
        guard isMirror, !removalBusy else { return }
        let assets = selectedOrphans()
        guard !assets.isEmpty else {
            notice = "Select an orphaned photo to recover."
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
            if await recoverOne(
                relative: relative,
                sourceUID: asset.uid,
                mainRoot: mainRoot,
                mirrorRoot: mirrorRoot,
                mainClient: mainClient
            ) != nil {
                landed += 1
            } else {
                failed += 1
            }
            await Task.yield()
        }
        refreshMirrorMarks()
        if failed == 0 {
            notice = landed == 1
                ? "Recovered 1 photo onto the main server."
                : "Recovered \(landed) photos onto the main server."
        } else {
            notice = "Recovered \(landed) \(landed == 1 ? "photo" : "photos"). \(failed) could not be copied."
        }
    }

    /// Copies one mirror photo onto the main server. The name stays the same when it is free.
    /// The landed path is stored for Edit in Library.
    private func recoverOne(
        relative: String,
        sourceUID: String?,
        mainRoot: URL,
        mirrorRoot: URL,
        mainClient: HelperClient
    ) async -> String? {
        let destRel = await Task.detached(priority: .utility) { () -> String? in
            do {
                let dest = try MirrorCopy.copyBeside(relative: relative, from: mirrorRoot, to: mainRoot)
                MirrorCopy.copyRecoverSidecars(photoSource: relative, photoDest: dest, from: mirrorRoot, to: mainRoot)
                return dest
            } catch {
                return nil
            }
        }.value
        guard let destRel else { return nil }
        MirrorLedger.remember(mirror: relative, main: destRel)
        _ = await rescanCopiedPaths([destRel], client: mainClient, generation: mirrorGeneration)
        if let sourceUID, let newUID = await uid(for: destRel, client: mainClient) {
            _ = await Task.detached(priority: .utility) {
                MirrorCopy.copyEdits(mainUID: sourceUID, mirrorUID: newUID, from: mirrorRoot, to: mainRoot)
            }.value
        }
        return destRel
    }

    /// What happened to the mirror copy of a file removed on the main server.
    enum MirrorPark: Equatable {
        case none
        case parked
        case stayed
    }

    /// Moves the matching mirror file into Photos/_Removed. A recovered beside-name parks the mirror original.
    func parkMirrorCopy(of relative: String) async -> MirrorPark {
        let recovered = MirrorLedger.load()
        let paths = MirrorLedger.pathsToPark(main: relative, recovered: recovered)
        guard !paths.isEmpty else { return .none }
        let servers = HelperServerList.load(defaults: .standard)
        guard let mirror = MirrorRoster.mirrorRow(in: servers) else { return .none }
        defer { MirrorLedger.forget(main: relative) }
        guard let client = pinnedClient(host: mirror.host) else { return .stayed }
        var parked = 0
        var missed = 0
        for path in paths {
            do {
                let page = try await client.assets(matching: path)
                guard let uid = page.rows.first(where: { $0.relPath?.caseInsensitiveCompare(path) == .orderedSame })?.uid else {
                    continue
                }
                let reply = try await client.removeFromLibrary(uid: uid)
                if reply.error != nil {
                    missed += 1
                } else {
                    parked += 1
                }
            } catch {
                missed += 1
            }
        }
        if missed > 0 { return .stayed }
        if parked > 0 { return .parked }
        return .none
    }

    /// Orphaned photos on the page now on screen.
    func pageOrphans() -> [LibraryAsset] {
        rows.filter { asset in
            guard let rel = asset.relPath else { return false }
            return mirrorMissing.contains(rel) && rel.hasPrefix("Photos/") && !parkedInLibrary(asset)
        }
    }

    /// The selected orphans on this page.
    func selectedOrphans() -> [LibraryAsset] {
        var chosen = rows.filter { selectedUIDs.contains($0.uid) }
        if chosen.isEmpty, let selectedUID, let one = rows.first(where: { $0.uid == selectedUID }) {
            chosen = [one]
        }
        return chosen.filter { asset in
            guard let rel = asset.relPath else { return false }
            return mirrorMissing.contains(rel) && rel.hasPrefix("Photos/") && !parkedInLibrary(asset)
        }
    }

    /// Moves every orphan on this page to Photos/_Removed.
    func discardPageOrphans() async {
        let assets = pageOrphans()
        guard !assets.isEmpty else {
            notice = "This page has no orphaned photos."
            return
        }
        await removeFromLibrary(assets)
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
            MirrorProgress.remove(root: root)
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

    nonisolated private static func mirrorRoleNotes(mainRoot: URL, mirrorRoot: URL) -> [String] {
        var notes: [String] = []
        switch MirrorConfigFile.apply(role: MirrorRoster.mirror, libraryRoot: mirrorRoot) {
        case .updated:
            notes.append("Restart the mirror helper so it refuses edits.")
        case .skippedOldHelper:
            notes.append("The mirror screen is read-only. Update the mirror helper to \(HelperRelease.version) and restart it so the server also refuses edits.")
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
        if stopped {
            parts.append("Mirroring stopped.")
            parts.append("Start mirroring again to continue from the saved place.")
        }
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

    /// Copies the edit files just saved on the main server, including a flattened TIFF, onto the mirror.
    /// A photograph the mirror catalog does not list yet is listed before those edit files are copied.
    /// Another photo's copy does not hold this one. A newer save for this photo replaces an older one.
    func mirrorSavedEdits(uid: String, relative: String) {
        guard MirrorCopy.safeUID(uid), relative.hasPrefix("Photos/"), !relative.contains("..") else { return }
        guard let pair = mirrorPairRoots(), let client = pinnedClient(host: pair.mirrorHost) else { return }
        let epoch = (mirrorEditEpoch[relative] ?? 0) + 1
        mirrorEditEpoch[relative] = epoch
        let mainRoot = pair.main
        let mirrorRoot = pair.mirror
        let folder = (relative as NSString).deletingLastPathComponent
        let task = Task(priority: .userInitiated) { @MainActor in
            defer {
                if self.mirrorEditEpoch[relative] == epoch {
                    self.mirrorEditDone[relative] = epoch
                }
            }
            if let writing = self.mirrorEditWrite[relative] {
                await writing.value
            }
            guard self.mirrorEditEpoch[relative] == epoch else { return }
            let mainOpen = mainRoot.startAccessingSecurityScopedResource()
            let mirrorOpen = mirrorRoot.startAccessingSecurityScopedResource()
            defer {
                if mainOpen { mainRoot.stopAccessingSecurityScopedResource() }
                if mirrorOpen { mirrorRoot.stopAccessingSecurityScopedResource() }
            }
            var mirrorUID = self.mirrorUIDByPath[relative]
            if mirrorUID == nil || !MirrorCopy.safeUID(mirrorUID ?? "") {
                mirrorUID = await self.mirrorUID(matching: relative, client: client)
            }
            guard self.mirrorEditEpoch[relative] == epoch else { return }
            if mirrorUID == nil, !folder.isEmpty {
                _ = await Task.detached(priority: .userInitiated) {
                    try? MirrorCopy.copyFile(relative: relative, from: mainRoot, to: mirrorRoot, replacing: false)
                }.value
                guard self.mirrorEditEpoch[relative] == epoch else { return }
                _ = await self.rescanCopiedPaths([relative], client: client, generation: self.mirrorGeneration)
                guard self.mirrorEditEpoch[relative] == epoch else { return }
                mirrorUID = await self.mirrorUID(matching: relative, client: client)
            }
            guard let mirrorUID, MirrorCopy.safeUID(mirrorUID) else { return }
            guard self.mirrorEditEpoch[relative] == epoch else { return }
            self.mirrorUIDByPath[relative] = mirrorUID
            let write = Task.detached(priority: .userInitiated) {
                _ = MirrorCopy.syncEdits(mainUID: uid, mirrorUID: mirrorUID, from: mainRoot, to: mirrorRoot)
            }
            self.mirrorEditWrite[relative] = write
            _ = await write.value
            if self.mirrorEditEpoch[relative] == epoch {
                self.mirrorEditWrite[relative] = nil
            }
        }
        mirrorEditTask[relative] = task
    }

    /// True while this photo's edit files are still being copied to the mirror.
    func mirrorEditPending(relative: String) -> Bool {
        guard let epoch = mirrorEditEpoch[relative] else { return false }
        return mirrorEditDone[relative] != epoch
    }

    /// Waits until the newest edit copy for this Photos path has finished.
    func mirrorEditsReady(relative: String) async {
        while true {
            let epoch = mirrorEditEpoch[relative] ?? 0
            let task = mirrorEditTask[relative]
            await task?.value
            if (mirrorEditEpoch[relative] ?? 0) == epoch {
                return
            }
        }
    }

    /// Copies one photograph that was just written on the main server, such as a duplicate or a merge.
    /// A same-size file is replaced. The mirror catalog is asked to list that one path.
    /// `previewJPEG` is stored as the folder thumbnail for the mirror's catalog id.
    func mirrorCopiedPhoto(relative: String, previewJPEG: Data? = nil) {
        guard relative.hasPrefix("Photos/"), !relative.contains("..") else { return }
        guard let pair = mirrorPairRoots() else { return }
        let mainRoot = pair.main
        let mirrorRoot = pair.mirror
        let client = pinnedClient(host: pair.mirrorHost)
        let folder = (relative as NSString).deletingLastPathComponent
        let jpeg = previewJPEG
        enqueueMirrorFollowUp {
            let mainOpen = mainRoot.startAccessingSecurityScopedResource()
            let mirrorOpen = mirrorRoot.startAccessingSecurityScopedResource()
            defer {
                if mainOpen { mainRoot.stopAccessingSecurityScopedResource() }
                if mirrorOpen { mirrorRoot.stopAccessingSecurityScopedResource() }
            }
            let generation = self.mirrorGeneration
            let copied = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try MirrorCopy.copyFile(relative: relative, from: mainRoot, to: mirrorRoot, replacing: true)
                    return true
                } catch {
                    return false
                }
            }.value
            guard copied, let client, !folder.isEmpty, generation == self.mirrorGeneration else { return }
            _ = await self.rescanCopiedPaths([relative], client: client, generation: generation)
            guard generation == self.mirrorGeneration, let jpeg, !jpeg.isEmpty else { return }
            guard let uid = await self.mirrorUID(matching: relative, client: client), MirrorCopy.safeUID(uid) else { return }
            guard generation == self.mirrorGeneration else { return }
            self.mirrorUIDByPath[relative] = uid
            let root = mirrorRoot
            await Task.detached(priority: .userInitiated) {
                MirrorCopy.writeThumb(jpeg: jpeg, uid: uid, root: root)
            }.value
        }
    }

    /// The main library is on screen and a mirror is linked. File copies wait their turn.
    private func enqueueMirrorFollowUp(_ work: @escaping @MainActor () async -> Void) {
        let follow = mirrorFollowUp
        let job = Task { @MainActor in
            await follow?.value
            await work()
        }
        mirrorFollowUp = job
    }

    private func mirrorPairRoots() -> (main: URL, mirror: URL, mirrorHost: String)? {
        guard renameFeedsMirror() else { return nil }
        let servers = HelperServerList.load(defaults: .standard)
        guard let main = MirrorRoster.mainRow(in: servers),
              let mirror = MirrorRoster.mirrorRow(in: servers),
              let mainRoot = LibraryFolderBookmark.url(from: main.bookmark),
              let mirrorRoot = LibraryFolderBookmark.url(from: mirror.bookmark),
              mainRoot.standardizedFileURL.path != mirrorRoot.standardizedFileURL.path,
              HelperClient.isIPv4(mirror.host) else { return nil }
        return (mainRoot, mirrorRoot, mirror.host)
    }

    /// One catalog query for this photo's path. The mirror's uid is not the main server's uid.
    private func mirrorUID(matching relative: String, client: HelperClient) async -> String? {
        guard let page = try? await client.assets(matching: relative) else { return nil }
        return page.rows.first { $0.relPath?.caseInsensitiveCompare(relative) == .orderedSame }?.uid
    }

    /// Records one rename that already landed on the main server. The mirror applies it later, in order.
    func passMainRename(kind: String, from: String, to: String) {
        let op = MirrorQueue.Op(kind: kind, from: from, to: to)
        guard MirrorQueue.accepts(op), renameFeedsMirror() else { return }
        let root = mirrorShareRoot()
        let opened = root?.startAccessingSecurityScopedResource() ?? false
        guard !mirrorBusy else {
            Task.detached(priority: .utility) {
                defer { if let root, opened { root.stopAccessingSecurityScopedResource() } }
                MirrorQueue.enqueue(op, mirrorRoot: root)
            }
            return
        }
        mirrorBusy = true
        Task {
            await Task.detached(priority: .utility) {
                defer { if let root, opened { root.stopAccessingSecurityScopedResource() } }
                MirrorQueue.enqueue(op, mirrorRoot: root)
            }.value
            await self.runMirrorRenames()
        }
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
            let step = await Task.detached(priority: .utility) { () -> (op: MirrorQueue.Op, outcome: MirrorQueue.Outcome, sourceExists: Bool)? in
                let ops = MirrorQueue.load(root: mirrorRoot)
                guard let head = ops.first else { return nil }
                let sourceExists = FileManager.default.fileExists(atPath: mirrorRoot.appendingPathComponent(head.from).path)
                let outcome = MirrorQueue.apply(head, root: mirrorRoot)
                return (head, outcome, sourceExists)
            }.value
            guard let step else { return }
            let head = step.op
            let outcome = step.outcome
            if generation != mirrorGeneration { return }
            if outcome == .applied || (outcome == .dropped && !step.sourceExists) {
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
                let wrote: Bool
                do {
                    wrote = try await Task.detached(priority: .utility) {
                        try MirrorQueue.commit(outcome, head: head, root: mirrorRoot)
                    }.value
                } catch {
                    pump.hold = true
                    pump.failure = (head.to as NSString).lastPathComponent
                    return
                }
                if !wrote { return }
                if outcome == .applied {
                    pump.renamed += 1
                    if let client {
                        if head.kind == MirrorQueue.file {
                            _ = await rescanCopiedPaths([head.from, head.to], client: client, generation: generation)
                        } else {
                            for folder in MirrorQueue.rescanFolders(head) {
                                let continued = await rescanCopiedFolder(folder, client: client, generation: generation)
                                if !continued { break }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Lists the files just copied. A whole-folder walk is not started, so Photos is not rescanned to record one file.
    /// False when the mirror helper is already walking and further rescans should wait.
    private func rescanCopiedPaths(_ paths: [String], client: HelperClient, generation: Int) async -> Bool {
        var byFolder: [String: [String]] = [:]
        var order: [String] = []
        for path in paths {
            let parent = (path as NSString).deletingLastPathComponent
            guard parent == "Photos" || parent.hasPrefix("Photos/"), path.hasPrefix(parent + "/") else { continue }
            if byFolder[parent] == nil { order.append(parent) }
            byFolder[parent, default: []].append(path)
        }
        for folder in order {
            let batch = byFolder[folder] ?? []
            var index = 0
            while index < batch.count {
                if generation != mirrorGeneration { return true }
                let end = min(index + FolderScanLimit.cap, batch.count)
                let slice = Array(batch[index..<end])
                index = end
                switch await client.startFolderPageRescan(prefix: folder, paths: slice) {
                case .busy:
                    return false
                case .status(let status):
                    if status.applied {
                        if status.runState == "failed" { return false }
                    } else if status.runState == "failed" {
                        return false
                    } else if status.runState == "running" {
                        await waitForFolderScan(client, generation: generation)
                    }
                default:
                    break
                }
            }
        }
        return true
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
