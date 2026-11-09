import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class EditorModel {
    var log = HistoryLog()
    var proxy: ProxyImage?
    var openedFileName: String?
    var canvasMessage: String?
    var draftTone = ToneState.identity
    var draftGeometry = GeometryState.identity
    var folderURL: URL?
    /// The folder chosen with Open Folder. The tree stays rooted here while a subfolder is selected.
    var browseRoot: URL?
    var folderEntries: [FolderEntry] = []
    /// The file chosen in the Disk folder grid. The details column reads this.
    var selectedFolderKey: String?
    /// Shift-click fills this from the anchor. Control-click or Command-click toggles one photo.
    var selectedFolderKeys: Set<String> = []
    var folderSelectionAnchor: String?
    var folderRotateBusy = false
    var folderRotateNote: String?
    var folderListingReady = false
    var folderMessage: String?
    var showsFolderGrid = false
    /// When on, the Folder view lists images and videos found in subfolders.
    var scanSubfolders = false
    var previewPoints = PreviewSize.defaultPoints
    var zoom = ZoomController()
    var canvasTool: CanvasTool = .zoom
    /// Rectangle drawn with Select, in the coordinates of the image on screen.
    var cropSelection: NormRect?
    var eyedropperMode: EyedropperMode = .white
    var skinPresetID = "light"
    var previewBanner: String?
    var decodeSupport: DecodeSupport?
    var editBase: EditBase?
    var showsPDFPicker = false
    var showsExportPanel = false
    /// The format panel is writing the folder selection, not the one open photo.
    private var folderExportSelection = false
    private var folderExportFiles: [URL] = []
    private(set) var helperUp = false
    private(set) var catalogAssetUID: String?
    var pdfDocument: PDFDocument?
    var pdfPageIndex = PDFImport.defaultPageIndex
    var canvasSize: CGSize = .zero
    private(set) var preview: CGImage?
    private(set) var securityScopedBookmark: Data?
    private(set) var documentURL: URL?
    /// BLAKE3 of the original bytes captured when the photo was opened.
    private var sourceFileURL: URL?
    private var sourceDigest: String?
    private var sourceByteCount: Int?
    private var sourceUTI: String?
    private var documentBookmark: Data?
    /// Set only while a `.zimg` open is waiting for its original to decode.
    private var pendingLoadedLog: HistoryLog?
    private var previewJPEGByPath: [String: URL] = [:]
    /// Folder JPEG of the edited photo, preferred over the original thumbnail.
    private var editedPreviewData: [String: Data] = [:]
    /// The library grid replaces its helper thumbnail when this runs.
    @ObservationIgnored
    var onEditedFolderPreview: ((URL, Data?) -> Void)?
    /// Left and right arrows while Image is showing. Returns true when the key is consumed.
    @ObservationIgnored
    var imageStep: ((Int) -> Bool)?
    /// The file the arrows step from. Set when an open starts, before its decode finishes.
    private var pendingOpenURL: URL?
    /// The file on the canvas, or the file an open has started.
    var openedFileURL: URL? { pendingOpenURL ?? sourceFileURL }
    /// A newer open ignores a decode that finished late.
    private var openGeneration = 0
    /// True while an arrow key is being handed to a slider or a text field.
    private var forwardingArrow = false
    /// The newest save requested for each photo. An older save does not overwrite it.
    @ObservationIgnored
    private var editSaveToken: [String: Int] = [:]
    private var folderGeneration = 0
    private var folderScopeURL: URL?
    private var fileScopeURL: URL?
    /// Set as soon as a still, PDF, or `.zimg` starts opening, before its decode finishes.
    private var fileOpenStarted = false
    /// Tests point this at a private suite. A test run otherwise leaves the saved folder alone.
    var folderBookmarkDefaults: UserDefaults?
    private var baseCI: CIImage?
    private var toneDragActive = false
    private var pendingToneLabel = "Tone"
    private var toneIdle: Task<Void, Never>?
    private var geometryDragActive = false
    private var pendingGeometryLabel = "Geometry"
    private var geometryIdle: Task<Void, Never>?
    private var horizonClicks: [NormPoint] = []
    /// Diameter of the Spot and Scratch circle, in preview pixels.
    var touchupBrushDiameter: Double = 48
    var touchupBusy = false
    /// Display-tone histogram behind the Spectrum handles. Empty until a photograph is open.
    var spectrumBins: [Int] = []
    private var spectrumDragActive = false
    private var touchupGeneration = 0
    /// The generation that currently owns `touchupBusy`. A finished older job does not clear a newer one.
    private var touchupBusyGeneration = 0
    private var dustStrengthOverride: Double?
    private var scratchStrengthOverride: Double?
    private var touchupDragID: UUID?
    private var touchupDragModelID: String?
    private var touchupDragLabel = "Dust amount"
    private let toneContext = TonePipeline.makeContext()
    private(set) var proxyRenderCount = 0
    private(set) var tileRequestCount = 0
    private var catalogRelPath: String?
    private var editorHelper: HelperClient?
    private var catalogGeneration = 0
    /// Edits for photos already opened in this session, including a return to identity.
    @ObservationIgnored
    private var editsBySource: [String: PhotoEdits] = [:]

    private struct PhotoEdits {
        var log: HistoryLog
        var documentURL: URL?
        var documentBookmark: Data?
        /// Canvas for these edits. Returning to the photo shows this instead of rerunning dust.
        var display: CGImage?
    }
    /// Preview to show for the photo currently being opened. Dust is not run again until an edit.
    private var savedCanvas: CGImage?
    private var pendingPreviewJPEG: Data?
    private var pendingFit = false
    private var tileGeneration = 0
    private var tileTask: Task<Void, Never>?
    private var pinchStartMagnification = 1.0
    private var panOrigin = CGSize.zero
    var spaceDown = false
    private var keyMonitor: Any?
    /// Space pans only while Select is off. Select keeps the drag for the crop handles.
    var handIsActive: Bool { canvasTool != .select && (canvasTool == .hand || spaceDown) }

    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types = ProxyRenderer.openableContentTypes + [.pdf]
        if let zimg = UTType(ZImgRaw.contentTypeIdentifier) ?? UTType(filenameExtension: "zimg") {
            types.append(zimg)
        }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openSecurityScopedFile(at: url)
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Open"
        panel.directoryURL = browseRoot ?? folderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolder(at: url)
    }

    /// Sets the tree root and shows that folder's stills. The previous folder scope is released.
    func openFolder(at url: URL) {
        releaseFolderScope()
        if url.startAccessingSecurityScopedResource() {
            folderScopeURL = url
        }
        browseRoot = url
        folderURL = url
        showsFolderGrid = true
        folderEntries = []
        folderListingReady = false
        folderMessage = nil
        previewJPEGByPath = [:]
        reloadFolderListing()
        rememberBrowseFolder()
    }

    /// Shows stills in one folder under the open tree. Subfolders stay in the tree.
    func selectBrowseFolder(_ url: URL) {
        guard isInsideFolderScope(url) else { return }
        folderURL = url
        showsFolderGrid = true
        folderEntries = []
        folderListingReady = false
        folderMessage = nil
        previewJPEGByPath = [:]
        reloadFolderListing()
        rememberBrowseFolder()
    }

    /// Opens the folder tree from the last session. An image already opening stays on screen.
    func restoreLastFolder() {
        guard browseRoot == nil, let defaults = folderBookmarkStore() else { return }
        guard let restored = EditorFolderBookmark.resolve(defaults: defaults) else {
            if EditorFolderBookmark.hasStoredRoot(defaults: defaults), !fileOpenStarted, !ExternalFileOpen.hasPending {
                folderMessage = EditorFolderBookmark.unavailableMessage
                showsFolderGrid = true
            }
            return
        }
        releaseFolderScope()
        if restored.root.startAccessingSecurityScopedResource() {
            folderScopeURL = restored.root
        }
        browseRoot = restored.root
        folderURL = restored.selection
        showsFolderGrid = !fileOpenStarted && !ExternalFileOpen.hasPending
        folderEntries = []
        folderListingReady = false
        folderMessage = nil
        previewJPEGByPath = [:]
        reloadFolderListing()
        if restored.stale {
            rememberBrowseFolder()
        }
    }

    /// Path of the selected folder relative to the tree root, for the folder tab.
    var folderTitle: String {
        guard let folderURL else { return "No folder" }
        guard let browseRoot else { return folderURL.lastPathComponent }
        let rootPath = FolderEntry.cacheKey(for: browseRoot)
        let path = FolderEntry.cacheKey(for: folderURL)
        if path == rootPath { return folderURL.lastPathComponent }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return folderURL.lastPathComponent
    }

    func openListedEntry(_ entry: FolderEntry) {
        if entry.isVideo {
            openInQuickTime(entry)
            return
        }
        if entry.isDirectory {
            if isInsideFolderScope(entry.url) {
                selectBrowseFolder(entry.url)
            } else {
                openFolder(at: entry.url)
            }
            return
        }
        openSecurityScopedFile(at: entry.url)
    }

    /// Stills in the folder grid, in the order the grid shows them. Videos stay put.
    private var listedFolderImages: [FolderEntry] {
        folderEntries.filter { !$0.isDirectory && !$0.isVideo }
    }

    func canStepListedImage(by delta: Int) -> Bool {
        guard proxy != nil, !showsPDFPicker, let openedFileURL else { return false }
        let images = listedFolderImages
        guard let index = images.firstIndex(where: { FolderEntry.cacheKey(for: $0.url) == FolderEntry.cacheKey(for: openedFileURL) }) else { return false }
        return images.indices.contains(index + delta)
    }

    /// Opens the still delta places away in this folder and selects it in the grid.
    func stepListedImage(by delta: Int) {
        guard canStepListedImage(by: delta), let openedFileURL else { return }
        let images = listedFolderImages
        guard let index = images.firstIndex(where: { FolderEntry.cacheKey(for: $0.url) == FolderEntry.cacheKey(for: openedFileURL) }) else { return }
        let entry = images[index + delta]
        selectFolderEntry(entry, shift: false)
        openListedEntry(entry)
    }

    func showInFinder(_ entry: FolderEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    /// File size for the folder menu, in Finder's decimal megabytes.
    func sizeLabel(for entry: FolderEntry) -> String {
        let bytes = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return LibraryItemMenu.sizeLabel(bytes: bytes)
    }

    /// Opens the video in QuickTime Player and leaves the folder grid in place.
    func openInQuickTime(_ entry: FolderEntry) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let quickTime = NSWorkspace.shared.urlForApplication(withBundleIdentifier: LibraryItemMenu.quickTimeBundleID) {
            NSWorkspace.shared.open([entry.url], withApplicationAt: quickTime, configuration: configuration)
            return
        }
        NSWorkspace.shared.open(entry.url)
    }

    /// Applications that can open this still. ZImage is listed first.
    func imageApplications(for entry: FolderEntry) -> [LibraryOpenTarget] {
        let others = NSWorkspace.shared.urlsForApplications(toOpen: entry.url)
        let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: EditorHandoff.editorBundleID)
        return LibraryItemMenu.applications(zimage: editor, others: others) { url in
            FileManager.default.displayName(atPath: url.path)
        }
    }

    /// Video players that can open this file. QuickTime Player is listed first.
    func videoApplications(for entry: FolderEntry) -> [LibraryOpenTarget] {
        let others = NSWorkspace.shared.urlsForApplications(toOpen: entry.url)
        let quickTime = NSWorkspace.shared.urlForApplication(withBundleIdentifier: LibraryItemMenu.quickTimeBundleID)
        let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: EditorHandoff.editorBundleID)
        return LibraryItemMenu.videoApplications(quickTime: quickTime, others: others, editor: editor) { url in
            FileManager.default.displayName(atPath: url.path)
        }
    }

    /// Opens the still in another application. Choosing ZImage edits it in this window.
    func open(_ entry: FolderEntry, with application: URL) {
        if EditorImageMenu.isEditor(application) {
            openListedEntry(entry)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([entry.url], withApplicationAt: application, configuration: configuration)
    }

    func returnToFolderGrid() {
        guard folderURL != nil else { return }
        showsFolderGrid = true
    }

    func previewJPEG(for entry: FolderEntry) -> URL? {
        previewJPEGByPath[FolderEntry.cacheKey(for: entry.url)]
    }

    func editedPreviewData(for entry: FolderEntry) -> Data? {
        editedPreviewData[entry.id]
    }

    func selectFolderEntry(_ entry: FolderEntry, shift: Bool, extend: Bool = false) {
        let order = folderEntries.filter { !$0.isDirectory }.map(\.id)
        let choice = GridSelection.choose(
            order: order,
            anchor: folderSelectionAnchor,
            clicked: entry.id,
            shift: shift,
            extend: extend,
            existing: selectedFolderKeys
        )
        selectedFolderKeys = choice.keys
        folderSelectionAnchor = choice.anchor
        selectedFolderKey = choice.primary
    }

    var canRotateFolderSelection: Bool {
        guard !folderRotateBusy else { return false }
        return folderEntries.contains { selectedFolderKeys.contains($0.id) && !$0.isDirectory && !$0.isVideo }
    }

    /// Quarter-turns each selected still, saves its settings, and rebuilds its folder preview.
    func rotateFolderSelection(clockwise: Bool) {
        let files = folderEntries
            .filter { selectedFolderKeys.contains($0.id) && !$0.isDirectory && !$0.isVideo }
            .map(\.url)
        rotate(files: files, clockwise: clockwise, catalog: [:])
    }

    /// Selected stills in the Disk folder grid. Videos stay out of rotate, paste, and export.
    func exportableFolderFiles() -> [URL] {
        folderEntries
            .filter { selectedFolderKeys.contains($0.id) && !$0.isDirectory && !$0.isVideo }
            .map(\.url)
    }

    /// The clicked still, or every selected still when that click is inside the selection.
    func folderPasteTargets(clicked: FolderEntry) -> [URL] {
        if selectedFolderKeys.contains(clicked.id) {
            return folderEntries
                .filter { selectedFolderKeys.contains($0.id) && !$0.isDirectory && !$0.isVideo }
                .map(\.url)
        }
        guard !clicked.isDirectory, !clicked.isVideo else { return [] }
        return [clicked.url]
    }

    /// The still the details column is showing. Copy settings reads this one photo.
    func primaryFolderStillURL() -> URL? {
        guard let key = selectedFolderKey,
              let entry = folderEntries.first(where: { $0.id == key }),
              !entry.isDirectory, !entry.isVideo else { return nil }
        return entry.url
    }

    /// Applies the copied Tone and Geometry to each selected still, then saves and rebuilds it.
    func pasteFolderSelection() {
        guard hasCopiedSettings else { return }
        let files = folderEntries
            .filter { selectedFolderKeys.contains($0.id) && !$0.isDirectory && !$0.isVideo }
            .map(\.url)
        paste(files: files, catalog: [:])
    }

    func rotate(files: [URL], clockwise: Bool, catalog: [String: CatalogEditTarget]) {
        guard !folderRotateBusy, !files.isEmpty else { return }
        folderRotateBusy = true
        folderRotateNote = nil
        let total = files.count
        Task {
            var failed = 0
            for (index, url) in files.enumerated() {
                self.folderRotateNote = "Rotating \(index + 1) of \(total)."
                let hint = catalog[FolderEntry.cacheKey(for: url)]
                let saved = await self.rotateOne(url, clockwise: clockwise, catalog: hint)
                if !saved { failed += 1 }
            }
            self.folderRotateBusy = false
            if failed == 0 {
                self.folderRotateNote = nil
            } else if failed == 1 {
                self.folderRotateNote = "One photo could not be rotated."
            } else {
                self.folderRotateNote = "\(failed) photos could not be rotated."
            }
        }
    }

    /// The open photo turns on the canvas. Every other photo is saved without changing the canvas.
    private func rotateOne(_ url: URL, clockwise: Bool, catalog: CatalogEditTarget?) async -> Bool {
        let key = sourceKey(url)
        if let sourceFileURL, sourceKey(sourceFileURL) == key {
            if catalogAssetUID == nil, let catalog {
                catalogAssetUID = catalog.uid
                catalogRelPath = catalog.relativePath
            }
            if clockwise {
                rotateClockwise()
            } else {
                rotateCounterclockwise()
            }
            return true
        }
        let session = editsBySource[key]?.log
        let outcome = await Task.detached {
            FolderTurnWorker.rotate(file: url, clockwise: clockwise, session: session)
        }.value
        switch outcome {
        case .failure:
            return false
        case .success(let turned):
            await storeTurned(url, turned, catalog: catalog)
            return true
        }
    }

    func pasteLibraryStills(_ assets: [LibraryAsset], fileURL: (LibraryAsset) -> URL?) {
        guard hasCopiedSettings else { return }
        var files: [URL] = []
        var catalog: [String: CatalogEditTarget] = [:]
        for asset in assets {
            guard let url = fileURL(asset), let relativePath = asset.relPath else { continue }
            files.append(url)
            catalog[FolderEntry.cacheKey(for: url)] = CatalogEditTarget(uid: asset.uid, relativePath: relativePath)
        }
        paste(files: files, catalog: catalog)
    }

    func paste(files: [URL], catalog: [String: CatalogEditTarget]) {
        guard hasCopiedSettings, !folderRotateBusy, !files.isEmpty else { return }
        folderRotateBusy = true
        folderRotateNote = nil
        let total = files.count
        let tone = copiedTone
        let geometry = copiedGeometry
        Task {
            var failed = 0
            for (index, url) in files.enumerated() {
                self.folderRotateNote = "Pasting \(index + 1) of \(total)."
                let hint = catalog[FolderEntry.cacheKey(for: url)]
                let saved = await self.pasteOne(url, tone: tone, geometry: geometry, catalog: hint)
                if !saved { failed += 1 }
            }
            self.folderRotateBusy = false
            if failed == 0 {
                self.folderRotateNote = nil
            } else if failed == 1 {
                self.folderRotateNote = "One photo could not be updated."
            } else {
                self.folderRotateNote = "\(failed) photos could not be updated."
            }
        }
    }

    /// The open photo changes on the canvas. Every other photo is saved without changing the canvas.
    private func pasteOne(
        _ url: URL,
        tone: ToneState,
        geometry: GeometryState,
        catalog: CatalogEditTarget?
    ) async -> Bool {
        let key = sourceKey(url)
        if let sourceFileURL, sourceKey(sourceFileURL) == key, proxy != nil {
            if catalogAssetUID == nil, let catalog {
                catalogAssetUID = catalog.uid
                catalogRelPath = catalog.relativePath
            }
            pasteCopied(tone: tone, geometry: geometry)
            return true
        }
        let session = editsBySource[key]?.log
        let outcome = await Task.detached {
            FolderTurnWorker.paste(file: url, tone: tone, geometry: geometry, session: session)
        }.value
        switch outcome {
        case .failure:
            return false
        case .success(let turned):
            await storeTurned(url, turned, catalog: catalog)
            return true
        }
    }

    private func pasteCopied(tone: ToneState, geometry: GeometryState) {
        commitOpenDrafts()
        guard draftTone != tone || draftGeometry != geometry else {
            publishOpenPreview()
            return
        }
        log.commit(.pasteSettings(tone: tone, geometry: geometry))
        syncDraftsFromLog()
        refreshPreview()
        publishOpenPreview()
    }

    private func storeTurned(_ url: URL, _ turned: FolderTurnWorker.Outcome, catalog: CatalogEditTarget?) async {
        let key = sourceKey(url)
        let local = try? LocalEditStore.fileURL(digest: turned.digest)
        editsBySource[key] = PhotoEdits(
            log: turned.log,
            documentURL: local,
            documentBookmark: turned.documentBookmark,
            display: nil
        )
        if let bookmark = turned.documentBookmark {
            SavedEditBookmarks.store(bookmark, for: turned.digest)
        }
        storeFolderPreview(url, renderedJPEG: turned.previewJPEG, identity: turned.log.state == .identity)
        if let catalog {
            await putCatalogEdits(
                catalog,
                log: turned.log,
                previewJPEG: turned.previewJPEG,
                digest: turned.digest,
                count: turned.byteCount,
                uti: turned.uti
            )
        }
    }

    /// Writes the open photo's current render into the folder grid and saves those settings.
    func publishFolderPreviewFromImage() {
        commitOpenDrafts()
        publishOpenPreview()
    }

    private func publishOpenPreview() {
        guard let url = sourceFileURL, let preview else { return }
        let identity = log.state == .identity && log.commands.isEmpty
        if log.state == .identity {
            storeFolderPreview(url, renderedJPEG: nil, identity: true)
        } else if let jpeg = ZImgRaw.jpegPreview(from: preview, maxLongEdge: FolderPreviewCache.maxLongEdge) {
            editedPreviewData[sourceKey(url)] = jpeg
            try? FolderPreviewCache.writeEditedJPEG(jpeg, for: url)
            onEditedFolderPreview?(url, jpeg)
        }
        guard !identity || documentURL != nil else { return }
        scheduleEditSave()
    }

    private func nextEditToken(for key: String) -> Int {
        let token = (editSaveToken[key] ?? 0) + 1
        editSaveToken[key] = token
        return token
    }

    private func storeFolderPreview(_ url: URL, renderedJPEG: Data?, identity: Bool) {
        let key = sourceKey(url)
        if identity {
            editedPreviewData.removeValue(forKey: key)
            FolderPreviewCache.removeEditedJPEG(for: url)
            onEditedFolderPreview?(url, nil)
            return
        }
        guard let renderedJPEG, let image = image(fromPreviewJPEG: renderedJPEG),
              let small = ZImgRaw.jpegPreview(from: image, maxLongEdge: FolderPreviewCache.maxLongEdge) else {
            return
        }
        editedPreviewData[key] = small
        try? FolderPreviewCache.writeEditedJPEG(small, for: url)
        onEditedFolderPreview?(url, small)
    }

    private func scheduleEditSave() {
        guard let key = sourceFileURL.map(sourceKey) else { return }
        let token = nextEditToken(for: key)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.editSaveToken[key] == token else { return }
            self.writeOpenEdit(key: key, token: token)
        }
    }

    private func putCatalogEdits(
        _ catalog: CatalogEditTarget,
        log: HistoryLog,
        previewJPEG: Data,
        digest: String,
        count: Int,
        uti: String
    ) async {
        guard let client = editorHelper ?? EditorHelper.client() else { return }
        editorHelper = client
        let body: Data
        do {
            body = try SaveEdits.catalogBytes(
                log: log,
                blake3: digest,
                byteSize: count,
                uti: uti,
                assetUID: catalog.uid,
                relativePathHint: catalog.relativePath,
                previewJPEG: previewJPEG
            )
        } catch {
            return
        }
        do {
            try await client.putEdits(uid: catalog.uid, body: body)
            helperUp = true
        } catch {
            return
        }
    }

    func openSecurityScopedFile(at url: URL, keepLoadedLog: Bool = false, switchToImageTab: Bool = true) {
        fileOpenStarted = true
        openGeneration += 1
        let generation = openGeneration
        if switchToImageTab {
            showsFolderGrid = false
        }
        showsPDFPicker = false
        pdfDocument = nil
        if !keepLoadedLog {
            rememberCurrentEdits()
            clearDocumentLink()
        }
        pendingOpenURL = url
        releaseFileScope()
        if url.startAccessingSecurityScopedResource() {
            fileScopeURL = url
        }
        let ext = url.pathExtension.lowercased()
        if ext == "zimg" {
            openZimg(at: url, generation: generation)
            return
        }
        if ext == "x3f" {
            openX3F(at: url, generation: generation)
            return
        }
        if ext == "pdf" {
            openPDF(at: url)
            return
        }
        openProxy(at: url, generation: generation)
    }

    /// The `.zimg` for this photo in ZImage's own folder. The photo folder is not used.
    func localEditFile() -> URL? {
        guard let sourceDigest else { return nil }
        return try? LocalEditStore.fileURL(digest: sourceDigest)
    }

    /// Writes the current log into ZImage's folder. The photo folder is left unchanged.
    func save() {
        commitOpenDrafts()
        guard let target = localEditFile() else {
            presentAlert("The edits could not be saved.")
            return
        }
        writeDocument(to: target, releaseAccess: false)
    }

    func saveAs() {
        commitOpenDrafts()
        let panel = NSSavePanel()
        if let zimg = UTType(ZImgRaw.contentTypeIdentifier) ?? UTType(filenameExtension: "zimg") {
            panel.allowedContentTypes = [zimg]
        }
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.directoryURL = try? LocalEditStore.folder()
        panel.nameFieldStringValue = suggestedDocumentName()
        panel.message = "The photo folder is read-only. Choose another folder, or use Save to keep the edits on this Mac."
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let started = url.startAccessingSecurityScopedResource()
        writeDocument(to: url, releaseAccess: started)
    }

    /// Asks the helper whether Save edits can be offered. A missing pin leaves it off.
    func refreshHelper() async {
        guard let client = EditorHelper.client() else {
            helperUp = false
            editorHelper = nil
            return
        }
        editorHelper = client
        do {
            _ = try await client.health()
            helperUp = true
        } catch {
            helperUp = false
        }
    }

    /// Puts a `catalogRef` sidecar at `.zimage/edits/<uid>.zimg`. Save As stays `fileRef`.
    func saveEdits() {
        guard SaveEdits.isEnabled(helperUp: helperUp, assetUID: catalogAssetUID),
              let uid = catalogAssetUID,
              let rel = catalogRelPath,
              let editorHelper,
              let sourceFileURL,
              let digest = sourceDigest,
              let count = sourceByteCount else { return }
        commitOpenDrafts()
        let logSnapshot = log
        let uti = sourceUTI ?? "public.data"
        let previewJPEG = preview.flatMap { ZImgRaw.jpegPreview(from: $0) } ?? Data([0xFF, 0xD8, 0xFF, 0xD9])
        let source = sourceFileURL
        Task {
            let outcome: Result<Data, Error> = await Task.detached {
                do {
                    let original = try Data(contentsOf: source)
                    if Blake3.hex(original) != digest || original.count != count {
                        throw ZImgError.hashMismatch
                    }
                    return .success(try SaveEdits.catalogBytes(
                        log: logSnapshot,
                        blake3: digest,
                        byteSize: count,
                        uti: uti,
                        assetUID: uid,
                        relativePathHint: rel,
                        previewJPEG: previewJPEG
                    ))
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .failure(let error):
                self.presentAlert(error.localizedDescription)
            case .success(let bytes):
                do {
                    try await editorHelper.putEdits(uid: uid, body: bytes)
                    self.previewBanner = "Edits saved."
                } catch {
                    self.presentAlert("The edits were not saved.")
                }
            }
        }
    }

    private func attachCatalogEdits(generation: Int) async {
        guard generation == catalogGeneration else { return }
        await refreshHelper()
        guard generation == catalogGeneration, helperUp, let editorHelper, let sourceFileURL, let sourceDigest else { return }
        let page: LibraryPage
        do {
            page = try await editorHelper.assets(matching: sourceFileURL.lastPathComponent)
        } catch {
            return
        }
        guard generation == catalogGeneration else { return }
        guard let asset = SaveEdits.matchingAsset(filePath: sourceFileURL.path, rows: page.rows),
              let rel = asset.relPath else {
            return
        }
        catalogAssetUID = asset.uid
        catalogRelPath = rel
        guard log.commands.isEmpty else { return }
        let saved: Data?
        do {
            saved = try await editorHelper.edits(uid: asset.uid)
        } catch {
            return
        }
        guard generation == catalogGeneration, let saved, let document = try? ZImgRaw.read(saved) else { return }
        guard document.base.kind == .catalogRef,
              document.base.assetUID == asset.uid,
              document.base.blake3 == sourceDigest else { return }
        if let count = sourceByteCount, document.base.byteSize != count { return }
        if let hint = document.base.relativePathHint, !hint.isEmpty {
            catalogRelPath = hint
        }
        applyCatalogLog(document.history, previewJPEG: document.previewJPEG)
    }

    private func applyCatalogLog(_ saved: HistoryLog, previewJPEG: Data) {
        cancelProvisionalEdits()
        log = saved
        syncDraftsFromLog()
        if let saved = image(fromPreviewJPEG: previewJPEG) {
            preview = saved
        } else {
            refreshPreview()
        }
    }

    /// Asks for a format, then writes a new file. The original path is refused.
    func showExportPanel() {
        discardFolderExportRequest()
        guard baseCI != nil else {
            presentAlert("Open a photo before exporting.")
            return
        }
        var state = log.state
        state.tone = draftTone
        state.geometry = draftGeometry
        do {
            try InpaintPipeline.validateForExport(state)
        } catch {
            presentAlert(error.localizedDescription)
            return
        }
        showsExportPanel = true
    }

    /// Prints the photograph on screen, including slider positions that have not been released yet.
    func printOpenPhoto() {
        guard !folderRotateBusy, proxy != nil, !showsPDFPicker, let baseCI else { return }
        var state = log.state
        state.tone = draftTone
        state.geometry = draftGeometry
        let image = FolderExportWorker.toned(base: baseCI, state: state, tokenPath: sourceFileURL?.path ?? "")
        guard let page = FolderExportWorker.raster(image, context: toneContext) else {
            folderRotateNote = "The photo could not be printed."
            return
        }
        folderRotateNote = nil
        _ = PhotoPrinter.run(images: [page], jobName: openedFileName ?? "Photo")
    }

    /// Prints each selected still. The open photo uses the picture on screen. Videos are already left out.
    func printFolderFiles(_ files: [URL]) {
        guard !folderRotateBusy, !files.isEmpty else { return }
        folderRotateBusy = true
        folderRotateNote = nil
        let total = files.count
        let openState: EditState? = {
            guard baseCI != nil, files.contains(where: isOpenFile) else { return nil }
            var state = log.state
            state.tone = draftTone
            state.geometry = draftGeometry
            return state
        }()
        let openBase = openState == nil ? nil : baseCI
        let openToken = sourceFileURL?.path ?? ""
        var sessions: [String: HistoryLog] = [:]
        for url in files {
            if isOpenFile(url) { continue }
            let key = sourceKey(url)
            if let saved = editsBySource[key]?.log {
                sessions[key] = saved
            }
        }
        Task {
            var pages: [CGImage] = []
            var onlyName: String?
            var failed = 0
            for (index, url) in files.enumerated() {
                self.folderRotateNote = "Preparing \(index + 1) of \(total) for printing."
                await Task.yield()
                let page: CGImage?
                if self.isOpenFile(url), let openState, let openBase {
                    let image = FolderExportWorker.toned(base: openBase, state: openState, tokenPath: openToken)
                    page = FolderExportWorker.raster(image, context: self.toneContext)
                } else {
                    let session = sessions[self.sourceKey(url)]
                    let raster = await Task.detached {
                        FolderExportWorker.rendered(file: url, session: session)
                    }.value
                    page = raster?.image
                }
                if let page {
                    if pages.isEmpty { onlyName = url.lastPathComponent }
                    pages.append(page)
                } else {
                    failed += 1
                }
            }
            self.folderRotateBusy = false
            self.folderRotateNote = nil
            guard !pages.isEmpty else {
                self.folderRotateNote = total == 1
                    ? "The photo could not be printed."
                    : "The photos could not be printed."
                return
            }
            let jobName = pages.count == 1 ? (onlyName ?? "Photo") : "\(pages.count) photos"
            let printed = PhotoPrinter.run(images: pages, jobName: jobName)
            if printed, failed > 0 {
                self.folderRotateNote = failed == 1
                    ? "One photo could not be printed."
                    : "\(failed) photos could not be printed."
            }
        }
    }

    /// Folder view asks for a format, then a folder, and writes every selected still there.
    func beginFolderExport(files: [URL]) {
        guard !folderRotateBusy, !files.isEmpty else { return }
        folderExportFiles = files
        folderExportSelection = true
        showsExportPanel = true
    }

    func discardFolderExportRequest() {
        folderExportSelection = false
        folderExportFiles = []
    }

    func exportStill(_ request: ExportRequest) {
        let exportingFolder = folderExportSelection
        let folderFiles = folderExportFiles
        discardFolderExportRequest()
        showsExportPanel = false
        if exportingFolder {
            writeFolderExport(folderFiles, request: request)
            return
        }
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: request.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = exportFileName(for: request)
        panel.prompt = "Export"
        DispatchQueue.main.async {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            self.writeExport(request, to: url)
        }
    }

    /// Picks a folder, then writes one new file per still. The open photo uses the picture on screen.
    private func writeFolderExport(_ files: [URL], request: ExportRequest) {
        guard !folderRotateBusy, !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Each selected photo is written into this folder. The original files are not changed."
        panel.directoryURL = files.first?.deletingLastPathComponent()
        DispatchQueue.main.async {
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            self.runFolderExport(files, request: request, folder: folder)
        }
    }

    private func runFolderExport(_ files: [URL], request: ExportRequest, folder: URL) {
        guard !folderRotateBusy, !files.isEmpty else { return }
        folderRotateBusy = true
        folderRotateNote = nil
        let total = files.count
        let openKey = sourceFileURL.map(sourceKey)
        let openState: EditState? = {
            guard baseCI != nil, let openKey, files.contains(where: { sourceKey($0) == openKey }) else { return nil }
            var state = log.state
            state.tone = draftTone
            state.geometry = draftGeometry
            return state
        }()
        let openBase = openState == nil ? nil : baseCI
        let openToken = sourceFileURL?.path ?? ""
        var sessions: [String: HistoryLog] = [:]
        for url in files {
            let key = sourceKey(url)
            if key == openKey { continue }
            if let saved = editsBySource[key]?.log {
                sessions[key] = saved
            }
        }
        let started = folder.startAccessingSecurityScopedResource()
        Task {
            var failed = 0
            for (index, url) in files.enumerated() {
                self.folderRotateNote = "Exporting \(index + 1) of \(total)."
                let key = self.sourceKey(url)
                let wrote: Bool
                if key == openKey, let openState, let openBase {
                    wrote = self.writeOpenFolderExport(
                        file: url,
                        folder: folder,
                        request: request,
                        state: openState,
                        base: openBase,
                        tokenPath: openToken
                    )
                } else {
                    let session = sessions[key]
                    wrote = await Task.detached {
                        FolderExportWorker.write(file: url, folder: folder, request: request, session: session)
                    }.value
                }
                if !wrote { failed += 1 }
            }
            if started {
                folder.stopAccessingSecurityScopedResource()
            }
            self.folderRotateBusy = false
            if failed == 0 {
                self.folderRotateNote = nil
            } else if failed == 1 {
                self.folderRotateNote = "One photo could not be exported."
            } else {
                self.folderRotateNote = "\(failed) photos could not be exported."
            }
        }
    }

    /// Same pixels as Export on the open photo. The file lands in the chosen folder, not on top of the original.
    private func writeOpenFolderExport(
        file: URL,
        folder: URL,
        request: ExportRequest,
        state: EditState,
        base: CIImage,
        tokenPath: String
    ) -> Bool {
        guard let destination = FolderExportWorker.destination(for: file, folder: folder, ext: request.fileExtension) else {
            return false
        }
        let image = FolderExportWorker.toned(base: base, state: state, tokenPath: tokenPath)
        let started = destination.startAccessingSecurityScopedResource()
        defer {
            if started {
                destination.stopAccessingSecurityScopedResource()
            }
        }
        return FolderExportWorker.write(image: image, state: state, request: request, to: destination, context: toneContext)
    }

    func openSelectedPDFPage() {
        guard let pdfDocument else { return }
        let index = pdfPageIndex
        let name = "\(openedFileName ?? "PDF") page \(index + 1)"
        let sourceURL = fileScopeURL
        do {
            let rendered = try PDFImport.render(document: pdfDocument, pageIndex: index)
            let proxy = try PDFImport.proxy(from: rendered.image, maxLongEdge: ProxyRenderer.maxLongEdge)
            adopt(
                proxy: proxy,
                name: name,
                url: sourceURL,
                banner: nil,
                support: .full,
                editBase: rendered.editBase
            )
            showsPDFPicker = false
        } catch {
            failOpen(name: name, message: error.localizedDescription)
            showsPDFPicker = false
        }
    }

    func cancelPDFPicker() {
        showsPDFPicker = false
        pdfDocument = nil
        if folderURL != nil {
            showsFolderGrid = true
        }
    }

    private func openPDF(at url: URL) {
        previewBanner = nil
        decodeSupport = nil
        editBase = nil
        do {
            let document = try PDFImport.load(url: url)
            pdfDocument = document
            pdfPageIndex = PDFImport.defaultPageIndex
            showsPDFPicker = true
            openedFileName = url.lastPathComponent
            canvasMessage = nil
            proxy = nil
            baseCI = nil
            preview = nil
            spectrumBins = []
            invalidateTile()
            resetEditsForNewImage()
        } catch {
            failOpen(name: url.lastPathComponent, message: error.localizedDescription)
        }
    }

    private func openX3F(at url: URL, generation: Int) {
        let name = url.lastPathComponent
        Task {
            let outcome: Result<X3FOpened, X3FOpenError> = await Task.detached {
                do {
                    return .success(try X3FPreview.open(url: url))
                } catch let error as X3FOpenError {
                    return .failure(error)
                } catch {
                    return .failure(.noPreview(name))
                }
            }.value
            guard generation == self.openGeneration else { return }
            switch outcome {
            case .success(let opened):
                self.adopt(
                    proxy: opened.proxy,
                    name: name,
                    url: url,
                    banner: opened.banner,
                    support: opened.decodeSupport,
                    editBase: nil
                )
            case .failure(let error):
                self.failOpen(name: name, message: error.localizedDescription)
            }
        }
    }

    private func openProxy(at url: URL, generation: Int) {
        let name = url.lastPathComponent
        Task {
            let outcome: Result<ProxyImage, ProxyOpenError> = await Task.detached {
                do {
                    return .success(try ProxyRenderer.open(url: url))
                } catch let error as ProxyOpenError {
                    return .failure(error)
                } catch {
                    return .failure(.cannotRead(url.lastPathComponent))
                }
            }.value
            guard generation == self.openGeneration else { return }
            switch outcome {
            case .success(let proxy):
                self.adopt(proxy: proxy, name: name, url: url, banner: nil, support: .full, editBase: nil)
            case .failure(let error):
                self.failOpen(name: name, message: error.localizedDescription)
            }
        }
    }

    private func adopt(
        proxy: ProxyImage,
        name: String,
        url: URL?,
        banner: String?,
        support: DecodeSupport,
        editBase: EditBase?
    ) {
        self.proxy = proxy
        self.baseCI = CIImage(cgImage: proxy.image)
        self.openedFileName = name
        self.canvasMessage = nil
        self.previewBanner = banner
        self.decodeSupport = support
        self.editBase = editBase
        self.zoom.resetForNewDocument()
        self.horizonClicks.removeAll()
        self.pendingFit = true
        self.invalidateTile()
        if let url {
            self.rememberSource(url)
        }
        savedCanvas = nil
        if let pending = pendingLoadedLog {
            cancelProvisionalEdits()
            log = pending
            pendingLoadedLog = nil
            syncDraftsFromLog()
            savedCanvas = image(fromPreviewJPEG: pendingPreviewJPEG ?? Data())
            pendingPreviewJPEG = nil
            if let url {
                editsBySource[sourceKey(url)] = PhotoEdits(
                    log: log,
                    documentURL: documentURL,
                    documentBookmark: documentBookmark,
                    display: savedCanvas
                )
            }
        } else if let url, restoreEdits(for: url) {
            // This photo keeps its own edits. The one just left stays in `editsBySource`.
        } else {
            resetEditsForNewImage()
        }
        if let savedCanvas {
            preview = savedCanvas
            self.savedCanvas = nil
            self.refreshSpectrumHistogram()
        } else {
            self.refreshPreview()
        }
        self.fitIfPossible()
        self.catalogAssetUID = nil
        self.catalogRelPath = nil
        guard EditorHelper.client() != nil else { return }
        catalogGeneration += 1
        let generation = catalogGeneration
        Task { await self.attachCatalogEdits(generation: generation) }
    }

    private func failOpen(name: String, message: String) {
        proxy = nil
        baseCI = nil
        preview = nil
        spectrumBins = []
        openedFileName = name
        previewBanner = nil
        decodeSupport = .unsupported
        editBase = nil
        securityScopedBookmark = nil
        canvasMessage = message
        horizonClicks.removeAll()
        invalidateTile()
        clearDocumentLink()
        pendingOpenURL = nil
        resetEditsForNewImage()
        releaseFileScope()
    }

    private func clearDocumentLink() {
        pendingLoadedLog = nil
        pendingPreviewJPEG = nil
        documentURL = nil
        documentBookmark = nil
        sourceFileURL = nil
        sourceDigest = nil
        sourceByteCount = nil
        sourceUTI = nil
        catalogAssetUID = nil
        catalogRelPath = nil
    }

    private func rememberSource(_ url: URL) {
        sourceFileURL = url
        let bytes = try? Data(contentsOf: url)
        sourceDigest = bytes.map { Blake3.hex($0) }
        sourceByteCount = bytes?.count
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        sourceUTI = type?.identifier ?? UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data"
        securityScopedBookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func openZimg(at url: URL, generation: Int) {
        let zimgBookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let name = url.lastPathComponent
        Task {
            let outcome: Result<ZImgRawDocument, Error> = await Task.detached {
                do {
                    return .success(try ZImgRaw.read(from: url))
                } catch {
                    return .failure(error)
                }
            }.value
            guard generation == self.openGeneration else { return }
            switch outcome {
            case .failure(let error):
                self.failOpen(name: name, message: error.localizedDescription)
            case .success(let document):
                self.finishOpeningZimg(document, zimgURL: url, zimgBookmark: zimgBookmark)
            }
        }
    }

    private func finishOpeningZimg(_ document: ZImgRawDocument, zimgURL: URL, zimgBookmark: Data?) {
        guard document.base.kind == .fileRef else {
            failOpen(name: zimgURL.lastPathComponent, message: "Pass 1 opens fileRef documents.")
            return
        }
        switch locateOriginal(for: document) {
        case .match(let original):
            armLoadedDocument(document, zimgURL: zimgURL, zimgBookmark: zimgBookmark)
            openSecurityScopedFile(at: original, keepLoadedLog: true)
        case .mismatch:
            failOpen(name: zimgURL.lastPathComponent, message: ZImgError.hashMismatch.localizedDescription)
        case .missing:
            askToLocateOriginal(for: document, zimgURL: zimgURL, zimgBookmark: zimgBookmark)
        }
    }

    private enum OriginalLocation {
        case match(URL)
        case mismatch
        case missing
    }

    /// Bookmark first, then the path hint. A readable file with the wrong hash is a mismatch.
    private func locateOriginal(for document: ZImgRawDocument) -> OriginalLocation {
        if let encoded = document.base.bookmarkBase64, let blob = Data(base64Encoded: encoded) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: blob,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return classify(url, against: document)
            }
        }
        if let hint = document.base.pathHint {
            let url = URL(fileURLWithPath: hint)
            if FileManager.default.isReadableFile(atPath: url.path) {
                return classify(url, against: document)
            }
        }
        return .missing
    }

    private func classify(_ url: URL, against document: ZImgRawDocument) -> OriginalLocation {
        let started = url.startAccessingSecurityScopedResource()
        let bytes = try? Data(contentsOf: url)
        if started {
            url.stopAccessingSecurityScopedResource()
        }
        guard let bytes else { return .missing }
        if ZImgRaw.resolveFileRef(document, bytes: bytes).applyLog {
            return .match(url)
        }
        return .mismatch
    }

    private func askToLocateOriginal(for document: ZImgRawDocument, zimgURL: URL, zimgBookmark: Data?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.prompt = "Locate"
        panel.message = ZImgError.needsLocate.localizedDescription
        if let hint = document.base.pathHint {
            let hinted = URL(fileURLWithPath: hint)
            panel.directoryURL = hinted.deletingLastPathComponent()
            panel.nameFieldStringValue = hinted.lastPathComponent
        }
        guard panel.runModal() == .OK, let picked = panel.url else {
            failOpen(name: zimgURL.lastPathComponent, message: ZImgError.needsLocate.localizedDescription)
            return
        }
        switch classify(picked, against: document) {
        case .match:
            armLoadedDocument(document, zimgURL: zimgURL, zimgBookmark: zimgBookmark)
            openSecurityScopedFile(at: picked, keepLoadedLog: true)
        case .mismatch, .missing:
            failOpen(name: zimgURL.lastPathComponent, message: ZImgError.hashMismatch.localizedDescription)
        }
    }

    private func armLoadedDocument(_ document: ZImgRawDocument, zimgURL: URL, zimgBookmark: Data?) {
        pendingLoadedLog = document.history
        pendingPreviewJPEG = document.previewJPEG
        documentURL = zimgURL
        documentBookmark = zimgBookmark
    }

    private func exportFileName(for request: ExportRequest) -> String {
        let stem = (openedFileName as NSString?)?.deletingPathExtension ?? "Export"
        return stem + "." + request.fileExtension
    }

    /// Geometry and tone of the open photo. Inpaint is not filled with the interactive stub.
    private func writeExport(_ request: ExportRequest, to url: URL) {
        guard let baseCI else { return }
        if let sourceFileURL, url.standardizedFileURL == sourceFileURL.standardizedFileURL {
            presentAlert("Export leaves the original file unchanged.")
            return
        }
        var state = log.state
        state.tone = draftTone
        state.geometry = draftGeometry
        let shaped = CropRect.apply(GeometryPipeline.apply(base: baseCI, geometry: state.geometry), crop: state.crop)
        let filled = InpaintPipeline.applyInteractive(
            base: shaped,
            operations: state.inpaints,
            imageToken: touchupImageToken()
        )
        let longEdge = max(filled.extent.width, filled.extent.height)
        let toned = TonePipeline.apply(base: filled, tone: state.tone, longEdge: max(longEdge, 1))
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try StillExporter.write(image: toned, state: state, request: request, to: url, context: toneContext)
        } catch {
            try? FileManager.default.removeItem(at: url)
            presentAlert(error.localizedDescription)
        }
    }

    private func suggestedDocumentName() -> String {
        if let documentURL {
            return documentURL.lastPathComponent
        }
        let stem = (openedFileName as NSString?)?.deletingPathExtension ?? "Untitled"
        return stem + ".zimg"
    }

    private func resolvedWriteURL(_ url: URL) -> URL {
        guard let documentBookmark else { return url }
        var stale = false
        if let resolved = try? URL(
            resolvingBookmarkData: documentBookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            return resolved
        }
        return url
    }

    /// Saves the open photo without a dialog. A newer save supersedes this one.
    private func writeOpenEdit(key: String, token: Int) {
        guard sourceFileURL.map(sourceKey) == key, let target = localEditFile() else { return }
        let catalog = catalogAssetUID.flatMap { uid in
            catalogRelPath.map { CatalogEditTarget(uid: uid, relativePath: $0) }
        }
        writeDocument(to: target, releaseAccess: false, quiet: true, saveKey: key, saveToken: token, catalog: catalog)
    }

    /// `releaseAccess` balances a `startAccessingSecurityScopedResource` done before the read.
    private func writeDocument(
        to url: URL,
        releaseAccess: Bool,
        quiet: Bool = false,
        saveKey: String? = nil,
        saveToken: Int? = nil,
        catalog: CatalogEditTarget? = nil
    ) {
        guard let sourceFileURL else {
            if releaseAccess {
                url.stopAccessingSecurityScopedResource()
            }
            if !quiet {
                presentAlert(ZImgError.cannotSave("Save needs the original photo.").localizedDescription)
            }
            return
        }
        let logSnapshot = log
        let bookmark = securityScopedBookmark
        let pathHint = sourceFileURL.path
        let digest = sourceDigest
        let expectedCount = sourceByteCount
        let uti = sourceUTI ?? "public.data"
        let previewJPEG = preview.flatMap { ZImgRaw.jpegPreview(from: $0) } ?? Data([0xFF, 0xD8, 0xFF, 0xD9])
        let source = sourceFileURL
        let savedKey = sourceKey(source)
        Task {
            let outcome: Result<Data, Error> = await Task.detached {
                do {
                    let original = try Data(contentsOf: source)
                    if let digest, Blake3.hex(original) != digest {
                        throw ZImgError.hashMismatch
                    }
                    if let expectedCount, original.count != expectedCount {
                        throw ZImgError.hashMismatch
                    }
                    let bytes = try ZImgRaw.bytesForSavePanel(
                        log: logSnapshot,
                        original: original,
                        pathHint: pathHint,
                        bookmark: bookmark,
                        uti: uti,
                        previewJPEG: previewJPEG
                    )
                    return .success(bytes)
                } catch {
                    return .failure(error)
                }
            }.value
            defer {
                if releaseAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            if let saveKey, let saveToken, self.editSaveToken[saveKey] != saveToken {
                return
            }
            switch outcome {
            case .failure(let error):
                if !quiet {
                    self.presentAlert(error.localizedDescription)
                }
            case .success(let bytes):
                do {
                    try bytes.write(to: url, options: .atomic)
                    let fileBookmark = try? url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    if let digest, let fileBookmark {
                        SavedEditBookmarks.store(fileBookmark, for: digest)
                    }
                    if !quiet, self.previewBanner == nil || self.previewBanner == "Edits saved." {
                        self.previewBanner = "Edits saved."
                    }
                    if self.sourceFileURL.map(self.sourceKey) == savedKey {
                        self.documentURL = url
                        self.documentBookmark = fileBookmark
                        self.rememberCurrentEdits(save: false)
                    } else if var stored = self.editsBySource[savedKey] {
                        stored.documentURL = url
                        stored.documentBookmark = fileBookmark
                        self.editsBySource[savedKey] = stored
                    }
                    if quiet, let catalog, let digest, let expectedCount {
                        await self.putCatalogEdits(
                            catalog,
                            log: logSnapshot,
                            previewJPEG: previewJPEG,
                            digest: digest,
                            count: expectedCount,
                            uti: uti
                        )
                    }
                } catch {
                    if !quiet {
                        self.presentAlert(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func presentAlert(_ message: String) {
        NSCursor.arrow.set()
        let alert = NSAlert()
        alert.messageText = "ZImage"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    func askCacheSize() {
        let alert = NSAlert()
        alert.messageText = "Set Cache Size"
        alert.informativeText = "Preview cache size in megabytes. The default is 200."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: String(FolderPreviewCache.storedMegabytes()))
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let megabytes = FolderPreviewCache.megabytes(from: field.stringValue) else {
            presentAlert("Enter a whole number of megabytes.")
            return
        }
        FolderPreviewCache.applyMegabytes(megabytes, persist: true)
    }

    func viewPreviewCache() {
        let directory = FolderPreviewCache.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    func clearPreviewCache() {
        FolderPreviewCache.wipe()
        previewJPEGByPath = [:]
        editedPreviewData = [:]
        preparePreviews(for: folderEntries, generation: folderGeneration)
    }

    func setScanSubfolders(_ on: Bool) {
        guard scanSubfolders != on else { return }
        scanSubfolders = on
        reloadFolderListing()
    }

    private func reloadFolderListing() {
        guard let folderURL else { return }
        folderListingReady = false
        folderGeneration += 1
        let generation = folderGeneration
        let url = folderURL
        let includeSubfolders = scanSubfolders
        Task {
            let listed = await Task.detached { () -> [FolderEntry]? in
                try? FolderListing.list(folder: url, includeSubfolders: includeSubfolders)
            }.value
            guard generation == self.folderGeneration else { return }
            guard let listed else {
                self.folderEntries = []
                self.selectedFolderKey = nil
                self.selectedFolderKeys = []
                self.folderSelectionAnchor = nil
                self.folderListingReady = true
                self.folderMessage = "Could not read this folder."
                return
            }
            self.folderEntries = listed
            if let key = self.selectedFolderKey, listed.contains(where: { $0.id == key }) {
                self.selectedFolderKeys.insert(key)
            }
            self.selectedFolderKeys = self.selectedFolderKeys.filter { key in
                listed.contains { $0.id == key }
            }
            if self.selectedFolderKeys.isEmpty {
                self.selectedFolderKey = nil
                self.folderSelectionAnchor = nil
            } else if let key = self.selectedFolderKey, !self.selectedFolderKeys.contains(key) {
                self.selectedFolderKey = self.selectedFolderKeys.first
            }
            self.folderListingReady = true
            self.folderMessage = nil
            self.preparePreviews(for: listed, generation: generation)
        }
    }

    /// Builds one preview at a time and shows it as soon as that file is ready.
    private func preparePreviews(for entries: [FolderEntry], generation: Int) {
        let images = entries.filter { !$0.isDirectory }.map(\.url)
        Task {
            for imageURL in images {
                let key = FolderEntry.cacheKey(for: imageURL)
                let loaded = await Task.detached { () -> (URL?, Data?) in
                    let original = try? FolderPreviewCache.ensureJPEG(for: imageURL)
                    let edited = FolderPreviewCache.readEditedJPEG(for: imageURL)
                    return (original, edited)
                }.value
                guard generation == self.folderGeneration else { return }
                if let jpeg = loaded.0 {
                    self.previewJPEGByPath[key] = jpeg
                }
                if let edited = loaded.1 {
                    self.editedPreviewData[key] = edited
                }
            }
        }
    }

    private func isInsideFolderScope(_ url: URL) -> Bool {
        guard let root = folderScopeURL ?? browseRoot ?? folderURL else { return false }
        let rootPath = FolderEntry.cacheKey(for: root)
        let childPath = FolderEntry.cacheKey(for: url)
        if childPath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return childPath.hasPrefix(prefix)
    }

    private func releaseFileScope() {
        fileScopeURL?.stopAccessingSecurityScopedResource()
        fileScopeURL = nil
    }

    private func releaseFolderScope() {
        folderScopeURL?.stopAccessingSecurityScopedResource()
        folderScopeURL = nil
    }

    private func folderBookmarkStore() -> UserDefaults? {
        if let folderBookmarkDefaults { return folderBookmarkDefaults }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        return .standard
    }

    private func rememberBrowseFolder() {
        guard let defaults = folderBookmarkStore(), let browseRoot, let folderURL else { return }
        EditorFolderBookmark.store(root: browseRoot, selection: folderURL, defaults: defaults)
    }

    func installCanvasKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            if event.keyCode == 49 {
                let held = event.type == .keyDown
                MainActor.assumeIsolated {
                    self?.spaceDown = held
                }
                return event
            }
            guard event.type == .keyDown else { return event }
            let blocked: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            guard event.modifierFlags.intersection(blocked).isEmpty else { return event }
            let delta: Int
            switch event.keyCode {
            case 123: delta = -1
            case 124: delta = 1
            default: return event
            }
            var forwarding = false
            MainActor.assumeIsolated {
                forwarding = self?.forwardingArrow ?? false
            }
            if forwarding { return event }
            if let responder = NSApp.keyWindow?.firstResponder {
                if let slider = responder as? NSSlider {
                    MainActor.assumeIsolated { self?.forwardingArrow = true }
                    slider.keyDown(with: event)
                    MainActor.assumeIsolated { self?.forwardingArrow = false }
                    return nil
                }
                if let text = responder as? NSTextView {
                    MainActor.assumeIsolated { self?.forwardingArrow = true }
                    text.keyDown(with: event)
                    MainActor.assumeIsolated { self?.forwardingArrow = false }
                    return nil
                }
            }
            var handled = false
            MainActor.assumeIsolated {
                handled = self?.imageStep?(delta) ?? false
            }
            return handled ? nil : event
        }
    }

    func updateCanvasSize(_ size: CGSize) {
        canvasSize = size
        fitIfPossible()
    }

    func fitToWindow() {
        guard let proxy else { return }
        let viewLong = Double(max(canvasSize.width, canvasSize.height))
        guard viewLong > 1 else {
            pendingFit = true
            return
        }
        zoom.fit(imageLongEdge: Double(proxy.longEdge), viewLongEdge: viewLong)
        pendingFit = false
        scheduleTileAfterZoom()
    }

    func actualSize() {
        zoom.actualSize()
        pendingFit = false
        scheduleTileAfterZoom()
    }

    private func fitIfPossible() {
        guard pendingFit, proxy != nil, canvasSize.width > 1, canvasSize.height > 1 else { return }
        fitToWindow()
    }

    func zoomIn(about point: CGPoint, in viewSize: CGSize) {
        zoom.zoomIn(about: point, viewSize: viewSize)
        pendingFit = false
        scheduleTileAfterZoom()
    }

    func zoomOut(about point: CGPoint, in viewSize: CGSize) {
        zoom.zoomOut(about: point, viewSize: viewSize)
        pendingFit = false
        scheduleTileAfterZoom()
    }

    func setZoomSlider(_ position: Double) {
        zoom.setLogarithmicPosition(position)
        pendingFit = false
        scheduleTileAfterZoom()
    }

    func beginPinch() {
        pinchStartMagnification = zoom.magnification
    }

    func pinchChanged(scale: Double, anchor: CGPoint, viewSize: CGSize) {
        let target = pinchStartMagnification * scale
        let factor = zoom.magnification == 0 ? 1 : target / zoom.magnification
        zoom.pinch(by: factor, anchor: anchor, viewSize: viewSize)
        pendingFit = false
        scheduleTileAfterZoom()
    }

    func beginPan() {
        panOrigin = zoom.offset
    }

    func pan(translation: CGSize) {
        guard handIsActive else { return }
        zoom.offset = CGSize(
            width: panOrigin.width + translation.width,
            height: panOrigin.height + translation.height
        )
    }

    private func invalidateTile() {
        tileGeneration += 1
        tileTask?.cancel()
        tileTask = nil
    }

    /// A higher-resolution tile is requested 150 ms after zoom settles above 1.25×.
    /// The proxy render count does not move.
    private func scheduleTileAfterZoom() {
        tileGeneration += 1
        let token = tileGeneration
        tileTask?.cancel()
        guard zoom.magnification > ZoomController.tileUpsampleThreshold else { return }
        tileTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, token == self.tileGeneration else { return }
            self.tileRequestCount += 1
        }
    }

    func commit(_ command: EditCommand) {
        log.commit(command)
    }

    /// True when the open photograph has an edit Redo can bring back, or a change that has not been released yet.
    var canResetPhoto: Bool {
        guard proxy != nil, !showsPDFPicker else { return false }
        if log.canUndo { return true }
        if draftTone != log.state.tone || draftGeometry != log.state.geometry { return true }
        return cropSelection != nil
    }

    /// Returns the open photograph to the start. Each edit stays on the redo stack.
    func resetPhoto() {
        guard proxy != nil, !showsPDFPicker else { return }
        touchupGeneration += 1
        commitOpenDrafts()
        guard log.canUndo || cropSelection != nil else { return }
        log.resetToBeginning()
        cropSelection = nil
        syncDraftsFromLog()
        refreshPreview()
        publishOpenPreview()
    }

    func undo() {
        touchupGeneration += 1
        cancelProvisionalEdits()
        log.undo()
        cropSelection = nil
        syncDraftsFromLog()
        refreshPreview()
        publishOpenPreview()
    }

    func redo() {
        touchupGeneration += 1
        cancelProvisionalEdits()
        log.redo()
        cropSelection = nil
        syncDraftsFromLog()
        refreshPreview()
        publishOpenPreview()
    }

    func selectCommand(at index: Int) {
        touchupGeneration += 1
        cancelProvisionalEdits()
        log.selectCommand(at: index)
        cropSelection = nil
        syncDraftsFromLog()
        refreshPreview()
        publishOpenPreview()
    }

    func pushSyntheticTone() {
        cancelProvisionalEdits()
        log.commit(.setTone(.identity, label: "Exposure"))
        syncDraftsFromLog()
        refreshPreview()
        publishOpenPreview()
    }

    private(set) var hasCopiedSettings = false
    private var copiedTone = ToneState.identity
    private var copiedGeometry = GeometryState.identity
    /// A later copy wins over a settings read that is still running.
    private var copyGeneration = 0

    /// Copies Tone and Geometry from the open photo, including a slider that has not been released yet.
    func copySettings() {
        copyGeneration += 1
        commitOpenDrafts()
        adoptCopied(tone: draftTone, geometry: draftGeometry)
    }

    /// Copies Tone and Geometry from one still. The open photo keeps its unsaved slider positions.
    func copySettings(from file: URL) {
        if isOpenFile(file) {
            copySettings()
            return
        }
        copyGeneration += 1
        let generation = copyGeneration
        if let session = editsBySource[sourceKey(file)]?.log {
            adoptCopied(tone: session.state.tone, geometry: session.state.geometry)
            return
        }
        hasCopiedSettings = false
        Task {
            let found = await Task.detached {
                FolderTurnWorker.adjustments(file: file)
            }.value
            guard generation == self.copyGeneration, let found else { return }
            self.adoptCopied(tone: found.tone, geometry: found.geometry)
        }
    }

    private func adoptCopied(tone: ToneState, geometry: GeometryState) {
        copiedTone = tone
        copiedGeometry = geometry
        hasCopiedSettings = true
    }

    private func isOpenFile(_ url: URL) -> Bool {
        guard let sourceFileURL, proxy != nil else { return false }
        return sourceKey(sourceFileURL) == sourceKey(url)
            || FolderEntry.cacheKey(for: sourceFileURL) == FolderEntry.cacheKey(for: url)
    }

    /// One history step. Crop and object removal stay as they are.
    func pasteSettings() {
        guard hasCopiedSettings, proxy != nil else { return }
        commitOpenDrafts()
        guard draftTone != copiedTone || draftGeometry != copiedGeometry else { return }
        log.commit(.pasteSettings(tone: copiedTone, geometry: copiedGeometry))
        syncDraftsFromLog()
        refreshPreview()
        publishOpenPreview()
    }

    func selectCanvasTool(_ tool: CanvasTool) {
        canvasTool = tool
        if tool != .horizon {
            horizonClicks.removeAll()
        }
        if tool != .select {
            cropSelection = nil
        }
    }

    /// The first click arms the tool. The next click returns to Zoom.
    func toggleCanvasTool(_ tool: CanvasTool) {
        if canvasTool == tool {
            selectCanvasTool(.zoom)
            return
        }
        selectCanvasTool(tool)
    }

    /// The first click selects the whole image. The next click leaves Select.
    func toggleSelect() {
        if canvasTool == .select {
            selectCanvasTool(.zoom)
            return
        }
        selectCanvasTool(.select)
        cropSelection = NormRect(x: 0, y: 0, width: 1, height: 1)
    }

    func rotateClockwise() {
        replaceGeometry("Rotate clockwise") { geometry in
            geometry.quarterTurns = GeometryPipeline.wrap(geometry.quarterTurns + 1)
        }
    }

    func rotateCounterclockwise() {
        replaceGeometry("Rotate counterclockwise") { geometry in
            geometry.quarterTurns = GeometryPipeline.wrap(geometry.quarterTurns - 1)
        }
    }

    func chooseLensProfile(_ id: String) {
        guard let profile = GeometryPipeline.profile(id: id) else { return }
        replaceGeometry(profile.name) { geometry in
            geometry.lens = profile.setting
        }
    }

    func setCornerPin(_ enabled: Bool) {
        replaceGeometry("Corners") { geometry in
            geometry.corners = enabled ? (geometry.corners ?? .unit) : nil
        }
    }

    func beginGeometryDrag() {
        geometryDragActive = true
        geometryIdle?.cancel()
    }

    func endGeometryDrag() {
        geometryDragActive = false
        geometryIdle?.cancel()
        commitGeometryDraft()
    }

    func nudgeGeometry(_ label: String, update: (inout GeometryState) -> Void) {
        update(&draftGeometry)
        pendingGeometryLabel = label
        refreshPreview()
        guard !geometryDragActive else { return }
        geometryIdle?.cancel()
        geometryIdle = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            commitGeometryDraft()
        }
    }

    func horizonClick(at viewPoint: CGPoint, in viewSize: CGSize) {
        guard let image = preview else { return }
        let pixel = imagePixel(viewPoint, viewSize: viewSize, imageSize: CGSize(width: image.width, height: image.height))
        let displayed = NormPoint(
            x: Double(pixel.x / CGFloat(image.width)),
            y: Double(pixel.y / CGFloat(image.height))
        )
        horizonClicks.append(CropRect.sourcePoint(displayed, within: log.state.crop))
        guard horizonClicks.count >= 2 else { return }
        let start = horizonClicks[0]
        let end = horizonClicks[1]
        horizonClicks.removeAll()
        endGeometryDrag()
        draftGeometry = GeometryPipeline.applyingHorizon(from: start, to: end, current: draftGeometry)
        pendingGeometryLabel = "Horizon"
        commitGeometryDraft()
    }

    func eyedropperClick(at viewPoint: CGPoint, in viewSize: CGSize) {
        guard let shaped = stage3Image(), let preview else { return }
        endToneDrag()
        let pixel = imagePixel(
            viewPoint,
            viewSize: viewSize,
            imageSize: CGSize(width: preview.width, height: preview.height)
        )
        let scaleX = shaped.extent.width / CGFloat(max(preview.width, 1))
        let scaleY = shaped.extent.height / CGFloat(max(preview.height, 1))
        let bitmap = CGPoint(x: pixel.x * scaleX, y: pixel.y * scaleY)
        let result: Eyedropper.GradeResult
        switch eyedropperMode {
        case .white:
            result = Eyedropper.whiteGrade(image: shaped, bitmapPoint: bitmap, context: toneContext, base: draftTone)
        case .skin:
            guard let preset = SkinPresets.preset(id: skinPresetID) else { return }
            result = Eyedropper.skinGrade(
                image: shaped,
                bitmapPoint: bitmap,
                preset: preset,
                context: toneContext,
                base: draftTone
            )
        }
        draftTone = result.tone
        pendingToneLabel = result.label
        refreshPreview()
        commitToneDraft()
    }

    func removeObjectClick(at viewPoint: CGPoint, in viewSize: CGSize) {
        guard let shaped = geometryImage(), let preview else { return }
        endToneDrag()
        let pixel = imagePixel(
            viewPoint,
            viewSize: viewSize,
            imageSize: CGSize(width: preview.width, height: preview.height)
        )
        let scaleX = shaped.extent.width / CGFloat(max(preview.width, 1))
        let scaleY = shaped.extent.height / CGFloat(max(preview.height, 1))
        let bitmap = CGPoint(x: pixel.x * scaleX, y: pixel.y * scaleY)
        let operation = InpaintPipeline.select(image: shaped, bitmapPoint: bitmap, context: toneContext)
        guard !operation.maskPNG.isEmpty else { return }
        log.commit(.addInpaint(operation))
        refreshPreview()
        publishOpenPreview()
    }

    func removeDust() {
        startTouchup(
            banner: "Removing dust…",
            empty: "No dust stood out from the surrounding photo. Spot covers a speck with the circle.",
            work: .dust
        )
    }

    func removeScratches() {
        startTouchup(
            banner: "Removing scratches…",
            empty: "No scratch stood out from the surrounding photo. Drag the Scratch circle along one.",
            work: .scratches
        )
    }

    func dustSpotClick(at viewPoint: CGPoint, in viewSize: CGSize) {
        guard let bitmap = touchupBitmap(at: viewPoint, in: viewSize) else { return }
        let radius = touchupRasterRadius()
        startTouchup(
            banner: "Removing the spot…",
            empty: "No speck stood out in that circle. Cover the spot and click it.",
            work: .spot(bitmap, radius)
        )
    }

    /// `viewPoints` are the drag, in canvas coordinates. A short drag does not add a history step.
    func scratchStroke(_ viewPoints: [CGPoint], in viewSize: CGSize) {
        var bitmaps: [CGPoint] = []
        for viewPoint in viewPoints {
            guard let bitmap = touchupBitmap(at: viewPoint, in: viewSize) else { continue }
            if let last = bitmaps.last {
                let dx = bitmap.x - last.x
                let dy = bitmap.y - last.y
                if dx * dx + dy * dy < 4 { continue }
            }
            bitmaps.append(bitmap)
        }
        if let end = viewPoints.last, let bitmap = touchupBitmap(at: end, in: viewSize) {
            let same = bitmaps.last.map { $0.x == bitmap.x && $0.y == bitmap.y } ?? false
            if !same { bitmaps.append(bitmap) }
        }
        var length: CGFloat = 0
        for index in 1..<bitmaps.count {
            length += hypot(bitmaps[index].x - bitmaps[index - 1].x, bitmaps[index].y - bitmaps[index - 1].y)
        }
        guard length >= 2 else { return }
        let radius = touchupRasterRadius()
        startTouchup(
            banner: "Removing the scratch…",
            empty: "No scratch stood out under that stroke.",
            work: .scratch(bitmaps, radius)
        )
    }

    func touchupRasterRadius() -> Int {
        guard let shaped = geometryImage(), let preview else {
            return max(1, Int((touchupBrushDiameter / 2).rounded()))
        }
        let scale = shaped.extent.width / CGFloat(max(preview.width, 1))
        return max(1, Int((touchupBrushDiameter / 2 * Double(scale)).rounded()))
    }

    func hasTouchup(_ modelID: String) -> Bool {
        log.state.inpaints.contains { $0.modelID == modelID }
    }

    func touchupStrength(modelID: String) -> Double {
        if modelID == InpaintModel.dust, let dustStrengthOverride { return dustStrengthOverride }
        if modelID == InpaintModel.scratch, let scratchStrengthOverride { return scratchStrengthOverride }
        return log.state.inpaints.last { $0.modelID == modelID }?.strength ?? 1
    }

    func beginTouchupStrength(modelID: String) {
        guard let operation = log.state.inpaints.last(where: { $0.modelID == modelID }) else { return }
        touchupDragID = operation.id
        touchupDragModelID = modelID
        touchupDragLabel = modelID == InpaintModel.dust ? "Dust amount" : "Scratch amount"
        if modelID == InpaintModel.dust {
            dustStrengthOverride = operation.strength
        } else {
            scratchStrengthOverride = operation.strength
        }
    }

    func setTouchupStrength(modelID: String, _ value: Double) {
        let clamped = min(1, max(0, value))
        if touchupDragID == nil {
            beginTouchupStrength(modelID: modelID)
        }
        if modelID == InpaintModel.dust {
            dustStrengthOverride = clamped
        } else {
            scratchStrengthOverride = clamped
        }
        refreshPreview()
    }

    func endTouchupStrength(modelID: String) {
        let value = touchupStrength(modelID: modelID)
        let editedID = touchupDragID
        let label = touchupDragLabel
        dustStrengthOverride = nil
        scratchStrengthOverride = nil
        touchupDragID = nil
        touchupDragModelID = nil
        guard let editedID else { return }
        let current = log.state.inpaints.first { $0.id == editedID }?.strength
        guard abs((current ?? value) - value) > 0.0001 else {
            refreshPreview()
            return
        }
        log.commit(.setInpaintStrength(id: editedID, strength: value, label: label))
        refreshPreview()
        publishOpenPreview()
    }

    func resetTouchupStrength(modelID: String) {
        beginTouchupStrength(modelID: modelID)
        setTouchupStrength(modelID: modelID, 1)
        endTouchupStrength(modelID: modelID)
    }

    private func touchupBitmap(at viewPoint: CGPoint, in viewSize: CGSize) -> CGPoint? {
        guard let shaped = geometryImage(), let preview else { return nil }
        let pixel = imagePixel(
            viewPoint,
            viewSize: viewSize,
            imageSize: CGSize(width: preview.width, height: preview.height)
        )
        let scaleX = shaped.extent.width / CGFloat(max(preview.width, 1))
        let scaleY = shaped.extent.height / CGFloat(max(preview.height, 1))
        return CGPoint(x: pixel.x * scaleX, y: pixel.y * scaleY)
    }

    private func startTouchup(banner: String, empty: String, work: TouchupWork) {
        guard !touchupBusy, proxy != nil else { return }
        commitOpenDrafts()
        guard let base = stage3Image(), let raster = Touchup.read(base) else { return }
        let chain = Touchup.chain(imageToken: touchupImageToken(), operations: touchupPreviewOperations())
        let extent = raster.extent
        touchupGeneration += 1
        let generation = touchupGeneration
        touchupBusyGeneration = generation
        touchupBusy = true
        let previousBanner = previewBanner
        previewBanner = banner
        let samples = raster.samples
        let width = raster.width
        let height = raster.height
        Task { @MainActor in
            let built = await Touchup.performOffMain(work, samples: samples, width: width, height: height)
            guard generation == self.touchupGeneration else {
                if self.touchupBusyGeneration == generation {
                    self.touchupBusy = false
                    if self.previewBanner == banner {
                        self.previewBanner = previousBanner
                    }
                }
                return
            }
            self.touchupBusy = false
            if self.previewBanner == banner {
                self.previewBanner = previousBanner
            }
            guard let built else {
                self.presentAlert(empty)
                return
            }
            let repaired = Touchup.ciImage(built.pixels, width: width, height: height, extent: extent)
            Touchup.store(
                chain: chain,
                width: width,
                height: height,
                maskPNG: built.operation.maskPNG,
                modelID: built.operation.modelID,
                image: repaired
            )
            self.log.commit(.addInpaint(built.operation))
            self.refreshPreview()
            self.publishOpenPreview()
        }
    }

    private func touchupImageToken() -> Int {
        Touchup.imageToken(
            path: sourceFileURL?.path ?? "",
            geometry: draftGeometry,
            crop: log.state.crop
        )
    }

    private func imagePixel(_ viewPoint: CGPoint, viewSize: CGSize, imageSize: CGSize) -> CGPoint {
        let magnification = zoom.magnification == 0 ? 1 : zoom.magnification
        let center = CGPoint(
            x: viewSize.width / 2 + zoom.offset.width,
            y: viewSize.height / 2 + zoom.offset.height
        )
        return CGPoint(
            x: (viewPoint.x - center.x) / magnification + imageSize.width / 2,
            y: (viewPoint.y - center.y) / magnification + imageSize.height / 2
        )
    }

    private func replaceGeometry(_ label: String, update: (inout GeometryState) -> Void) {
        cancelProvisionalEdits()
        syncDraftsFromLog()
        update(&draftGeometry)
        pendingGeometryLabel = label
        commitGeometryDraft()
    }

    private func syncDraftsFromLog() {
        draftTone = log.state.tone
        draftGeometry = log.state.geometry
        horizonClicks.removeAll()
    }

    /// A photo with no remembered edits and no saved `.zimg` starts from identity.
    /// A saved `.zimg` opened directly assigns `pendingLoadedLog` instead.
    private func resetEditsForNewImage() {
        touchupGeneration += 1
        touchupBusy = false
        cancelProvisionalEdits()
        log = HistoryLog()
        cropSelection = nil
        syncDraftsFromLog()
    }

    var canCrop: Bool {
        guard let cropSelection, let preview else { return false }
        return CropRect.isUsable(cropSelection, pixelWidth: preview.width, pixelHeight: preview.height)
    }

    /// Crops to the rectangle drawn on the image. The step is named Crop.
    func applyCrop() {
        guard let preview, let selection = cropSelection,
              CropRect.isUsable(selection, pixelWidth: preview.width, pixelHeight: preview.height) else { return }
        commitOpenDrafts()
        let next = CropRect.composed(selection, within: log.state.crop)
        guard next.width > 0, next.height > 0 else { return }
        log.commit(.setCrop(next))
        selectCanvasTool(.zoom)
        refreshPreview()
        publishOpenPreview()
    }

    private func sourceKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Folds slider and rotation drafts into the log so a switch or a save keeps what is on screen.
    private func commitOpenDrafts() {
        cancelProvisionalEdits()
        if draftTone != log.state.tone {
            log.commit(.setTone(draftTone, label: pendingToneLabel))
        }
        if draftGeometry != log.state.geometry {
            log.commit(.setGeometry(draftGeometry, label: pendingGeometryLabel))
        }
        if let modelID = touchupDragModelID {
            endTouchupStrength(modelID: modelID)
        }
    }

    private func rememberCurrentEdits(save: Bool = true) {
        guard let sourceFileURL else { return }
        commitOpenDrafts()
        editsBySource[sourceKey(sourceFileURL)] = PhotoEdits(
            log: log,
            documentURL: documentURL,
            documentBookmark: documentBookmark,
            display: preview
        )
        guard save else { return }
        publishOpenPreview()
        flushOpenEditSave()
    }

    /// Writes the open photo now, so a following open does not save the next photo over this one.
    private func flushOpenEditSave() {
        guard let key = sourceFileURL.map(sourceKey) else { return }
        guard !log.commands.isEmpty || documentURL != nil else { return }
        let token = nextEditToken(for: key)
        writeOpenEdit(key: key, token: token)
    }

    /// Session edits win. Otherwise the `.zimg` saved for this file, including one that is not beside the photo.
    private func restoreEdits(for url: URL) -> Bool {
        if let session = editsBySource[sourceKey(url)] {
            log = session.log
            documentURL = session.documentURL
            documentBookmark = session.documentBookmark
            syncDraftsFromLog()
            savedCanvas = session.display
            if savedCanvas == nil, !log.state.inpaints.isEmpty,
               let digest = sourceDigest, let count = sourceByteCount,
               let stored = storedEdits(digest: digest, count: count, beside: url) {
                savedCanvas = image(fromPreviewJPEG: stored.previewJPEG)
            }
            return true
        }
        guard let digest = sourceDigest, let count = sourceByteCount,
              let stored = storedEdits(digest: digest, count: count, beside: url) else {
            return false
        }
        applyStoredEdits(stored.history, previewJPEG: stored.previewJPEG, file: stored.file, bookmark: stored.bookmark, source: url)
        return true
    }

    private struct StoredFileEdits {
        var history: HistoryLog
        var previewJPEG: Data
        var file: URL
        var bookmark: Data?
    }

    /// The `.zimg` whose original matches this photo, including the saved JPEG.
    private func storedEdits(digest: String, count: Int, beside url: URL) -> StoredFileEdits? {
        if let bookmark = SavedEditBookmarks.bookmark(for: digest) {
            var stale = false
            if let file = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), let stored = matchingFile(at: file, digest: digest, count: count, bookmark: bookmark) {
                return stored
            }
        }
        if let local = try? LocalEditStore.fileURL(digest: digest),
           let stored = matchingFile(at: local, digest: digest, count: count, bookmark: nil) {
            let bookmark = try? local.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return StoredFileEdits(
                history: stored.history,
                previewJPEG: stored.previewJPEG,
                file: stored.file,
                bookmark: bookmark
            )
        }
        let sibling = url.deletingPathExtension().appendingPathExtension("zimg")
        guard var stored = matchingFile(at: sibling, digest: digest, count: count, bookmark: nil) else {
            return nil
        }
        let bookmark = try? sibling.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        if let bookmark {
            SavedEditBookmarks.store(bookmark, for: digest)
        }
        stored.bookmark = bookmark
        return stored
    }

    private func applyStoredEdits(
        _ history: HistoryLog,
        previewJPEG: Data,
        file: URL,
        bookmark: Data?,
        source: URL
    ) {
        cancelProvisionalEdits()
        log = history
        documentURL = file
        documentBookmark = bookmark
        syncDraftsFromLog()
        let display = image(fromPreviewJPEG: previewJPEG)
        savedCanvas = display
        editsBySource[sourceKey(source)] = PhotoEdits(
            log: history,
            documentURL: file,
            documentBookmark: bookmark,
            display: display
        )
    }

    private func matchingFile(at file: URL, digest: String, count: Int, bookmark: Data?) -> StoredFileEdits? {
        let started = file.startAccessingSecurityScopedResource()
        defer {
            if started {
                file.stopAccessingSecurityScopedResource()
            }
        }
        guard FileManager.default.isReadableFile(atPath: file.path),
              let document = try? ZImgRaw.read(from: file),
              document.base.kind == .fileRef,
              document.base.blake3 == digest,
              document.base.byteSize == count else {
            return nil
        }
        return StoredFileEdits(
            history: document.history,
            previewJPEG: document.previewJPEG,
            file: file,
            bookmark: bookmark
        )
    }

    private func image(fromPreviewJPEG data: Data) -> CGImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 1, image.height > 1 else {
            return nil
        }
        return image
    }

    /// Starts a slider drag. Values stay out of the log until `endToneDrag`.
    func beginToneDrag() {
        toneDragActive = true
        toneIdle?.cancel()
    }

    /// Starts a Spectrum drag. The histogram stays still until the handle is released.
    func beginSpectrumDrag() {
        spectrumDragActive = true
        beginToneDrag()
    }

    /// Moves one Spectrum handle. One drag is one history step.
    func setSpectrum(_ handle: SpectrumHandle, to value: Double) {
        guard proxy != nil, spectrumDragActive else { return }
        let next = SpectrumLevels.moving(
            handle,
            to: value,
            low: draftTone.spectrumLow,
            mid: draftTone.spectrumMid,
            high: draftTone.spectrumHigh
        )
        applySpectrum(next, label: SpectrumLevels.label(handle))
    }

    /// Puts one Spectrum handle back. Low returns to black, high to white, and middle to the center.
    func resetSpectrum(_ handle: SpectrumHandle) {
        guard proxy != nil else { return }
        let next = SpectrumLevels.reset(
            handle,
            low: draftTone.spectrumLow,
            mid: draftTone.spectrumMid,
            high: draftTone.spectrumHigh
        )
        beginSpectrumDrag()
        applySpectrum(next, label: SpectrumLevels.label(handle))
        endSpectrumDrag()
    }

    func endSpectrumDrag() {
        spectrumDragActive = false
        endToneDrag()
    }

    private func applySpectrum(_ next: (low: Double, mid: Double, high: Double), label: String) {
        draftTone.spectrumLow = next.low
        draftTone.spectrumMid = next.mid
        draftTone.spectrumHigh = next.high
        pendingToneLabel = label
        refreshPreview()
    }

    /// One history step named Auto. The six basic sliders come from the photograph before the current tone, so pressing Auto again does not stack.
    func autoAdjustTone() {
        endToneDrag()
        guard let shaped = stage3Image() else { return }
        let extent = shaped.extent
        let longSide = max(extent.width, extent.height)
        guard longSide.isFinite, longSide > 1 else { return }
        let scale = min(1, 160 / longSide)
        let small = shaped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = small.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width >= 2, height >= 2 else { return }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        toneContext.render(
            small,
            toBitmap: &bytes,
            rowBytes: width * 4,
            bounds: bounds,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        )
        guard let levels = ToneAuto.levels(rgba: bytes) else { return }
        draftTone = ToneAuto.applying(levels, to: draftTone)
        pendingToneLabel = "Auto"
        refreshPreview()
        commitToneDraft()
    }

    /// Mouse-up. One drag is one `setTone`.
    func endToneDrag() {
        toneDragActive = false
        spectrumDragActive = false
        toneIdle?.cancel()
        commitToneDraft()
    }

    /// Updates the provisional tone. A drag waits for mouse-up. A keyboard nudge
    /// commits after 400 ms of idle, so several arrow keys are one command.
    func nudgeTone(_ keyPath: WritableKeyPath<ToneState, Double>, to value: Double, label: String) {
        draftTone[keyPath: keyPath] = value
        pendingToneLabel = label
        refreshPreview()
        guard !toneDragActive else { return }
        toneIdle?.cancel()
        toneIdle = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            commitToneDraft()
        }
    }

    private func cancelToneGesture() {
        toneDragActive = false
        spectrumDragActive = false
        toneIdle?.cancel()
        toneIdle = nil
    }

    private func cancelGeometryGesture() {
        geometryDragActive = false
        geometryIdle?.cancel()
        geometryIdle = nil
    }

    private func cancelProvisionalEdits() {
        cancelToneGesture()
        cancelGeometryGesture()
        dustStrengthOverride = nil
        scratchStrengthOverride = nil
        touchupDragID = nil
        touchupDragModelID = nil
    }

    private func commitToneDraft() {
        guard draftTone != log.state.tone else { return }
        log.commit(.setTone(draftTone, label: pendingToneLabel))
        publishOpenPreview()
    }

    private func commitGeometryDraft() {
        guard draftGeometry != log.state.geometry else { return }
        log.commit(.setGeometry(draftGeometry, label: pendingGeometryLabel))
        refreshPreview()
        publishOpenPreview()
    }

    private func geometryImage() -> CIImage? {
        guard let baseCI else { return nil }
        let shaped = GeometryPipeline.apply(base: baseCI, geometry: draftGeometry)
        return CropRect.apply(shaped, crop: log.state.crop)
    }

    /// Geometry, then inpaint. Tone is applied after this.
    private func stage3Image() -> CIImage? {
        guard let shaped = geometryImage() else { return nil }
        return InpaintPipeline.applyInteractive(
            base: shaped,
            operations: touchupPreviewOperations(),
            imageToken: touchupImageToken()
        )
    }

    private func touchupPreviewOperations() -> [InpaintOp] {
        var operations = log.state.inpaints
        if let dustStrengthOverride, let index = operations.lastIndex(where: { $0.modelID == InpaintModel.dust }) {
            operations[index].strength = dustStrengthOverride
        }
        if let scratchStrengthOverride, let index = operations.lastIndex(where: { $0.modelID == InpaintModel.scratch }) {
            operations[index].strength = scratchStrengthOverride
        }
        return operations
    }

    private func refreshPreview() {
        guard let shaped = stage3Image() else {
            preview = nil
            spectrumBins = []
            return
        }
        let longEdge = max(shaped.extent.width, shaped.extent.height)
        let toned = TonePipeline.apply(base: shaped, tone: draftTone, longEdge: longEdge)
        let extent = toned.extent.integral
        guard extent.width >= 1, extent.height >= 1 else {
            preview = nil
            spectrumBins = []
            return
        }
        let screen = NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        preview = toneContext.createCGImage(toned, from: extent, format: .RGBA8, colorSpace: screen)
        proxyRenderCount += 1
        refreshSpectrumHistogram()
    }

    /// Luminance of the photograph before the Spectrum handles, so the graph stays put while a handle moves.
    private func refreshSpectrumHistogram() {
        guard !spectrumDragActive else { return }
        guard let shaped = stage3Image() else {
            spectrumBins = []
            return
        }
        let extent = shaped.extent
        let longSide = max(extent.width, extent.height)
        guard longSide.isFinite, longSide > 1 else {
            spectrumBins = []
            return
        }
        var tone = draftTone
        tone.spectrumLow = 0
        tone.spectrumMid = 0.5
        tone.spectrumHigh = 1
        let scale = min(1, 160 / longSide)
        let small = shaped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let toned = TonePipeline.apply(
            base: small,
            tone: tone,
            longEdge: max(small.extent.width, small.extent.height)
        )
        let bounds = toned.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width >= 2, height >= 2 else {
            spectrumBins = []
            return
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        toneContext.render(
            toned,
            toBitmap: &bytes,
            rowBytes: width * 4,
            bounds: bounds,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        )
        spectrumBins = SpectrumLevels.bins(rgba: bytes)
    }
}

struct Chrome: View {
    /// The inspector column. Undo, Redo, Copy settings, and Paste settings sit above it in Disk, and in Server while Image is selected.
    private static let inspectorColumn: CGFloat = 320

    @Bindable var model: EditorModel
    @Bindable var browser: LibraryBrowser
    @AppStorage("ZImage.folderTreeWidth") private var treeWidth = Double(EditorFolderSpan.initial)
    @AppStorage("ZImageLibrary.sidebarWidth") private var libraryTreeWidth = Double(LibrarySidebarSpan.initial)
    @AppStorage("ZImager.sourceMode") private var sourceMode = "disk"
    @AppStorage("ZImager.serverShowsFolder") private var serverShowsFolder = true
    @AppStorage("ZImage.inspectorSpectrumCollapsed") private var spectrumCollapsed = false
    @AppStorage("ZImage.inspectorToneCollapsed") private var toneCollapsed = false
    @AppStorage("ZImage.inspectorGeometryCollapsed") private var geometryCollapsed = false
    @AppStorage("ZImage.inspectorColorCollapsed") private var colorCollapsed = false
    @AppStorage("ZImage.inspectorHistoryCollapsed") private var historyCollapsed = false
    @AppStorage("ZImage.inspectorTouchupCollapsed") private var touchupCollapsed = false
    @State private var librarySection: String? = "Photos"
    @State private var showsEvents = false
    @State private var showsReorg = false
    @State private var sectionChangesSelectFolder = false

    private var diskMode: Bool { sourceMode != "server" }
    private var showsImage: Bool { diskMode ? !model.showsFolderGrid : !serverShowsFolder }

    var body: some View {
        GeometryReader { geo in
            let column = diskMode
                ? EditorFolderSpan.clamped(CGFloat(treeWidth), available: geo.size.width)
                : LibrarySidebarSpan.clamped(CGFloat(libraryTreeWidth), available: geo.size.width)
            VStack(spacing: 0) {
                toolbar(column: column)
                HStack(spacing: 0) {
                    folderColumn(width: column, available: geo.size.width)
                    center
                    if showsImage {
                        inspector
                    } else if !diskMode && (showsEvents || showsReorg) {
                        if showsEvents {
                            EventRename(browser: browser)
                                .frame(width: 280)
                        }
                        if showsReorg {
                            ReorgPanel(browser: browser)
                                .frame(width: 280)
                        }
                    } else if diskMode {
                        FolderFileDetails(model: model)
                            .frame(width: 280)
                    } else {
                        DateInspector(browser: browser)
                            .frame(width: 280)
                    }
                }
            }
        }
        .background(ChromePalette.panel)
        .foregroundStyle(ChromePalette.ink)
        .onAppear {
            browser.openFile = { url, _ in
                model.openSecurityScopedFile(at: url, switchToImageTab: false)
                UserDefaults.standard.set(false, forKey: "ZImager.serverShowsFolder")
            }
            model.onEditedFolderPreview = { url, jpeg in
                browser.installEditedPreview(file: url, jpeg: jpeg)
            }
            FolderPreviewCache.loadStoredCap()
            model.restoreLastFolder()
            browser.librarySection = librarySection ?? "Photos"
            model.imageStep = { [model, browser] delta in
                let server = UserDefaults.standard.string(forKey: "ZImager.sourceMode") == "server"
                let folder: Bool
                if server {
                    if UserDefaults.standard.object(forKey: "ZImager.serverShowsFolder") == nil {
                        folder = true
                    } else {
                        folder = UserDefaults.standard.bool(forKey: "ZImager.serverShowsFolder")
                    }
                } else {
                    folder = model.showsFolderGrid
                }
                guard !folder, model.proxy != nil, !model.showsPDFPicker else { return false }
                if server {
                    browser.stepImage(by: delta, matching: model.openedFileURL)
                } else {
                    model.stepListedImage(by: delta)
                }
                return true
            }
            model.installCanvasKeys()
            sectionChangesSelectFolder = true
        }
        .onChange(of: librarySection) { _, section in
            browser.librarySection = section ?? "Photos"
            if sectionChangesSelectFolder {
                serverShowsFolder = true
            }
        }
        .onChange(of: sourceMode) { _, mode in
            if mode == "server", model.canvasTool == .removeObject {
                model.selectCanvasTool(.zoom)
            }
        }
        .onChange(of: model.showsFolderGrid) { _, showing in
            if showing {
                model.publishFolderPreviewFromImage()
            }
        }
        .onChange(of: serverShowsFolder) { _, showing in
            if showing {
                model.publishFolderPreviewFromImage()
            }
        }
        .task(id: sourceMode) {
            guard sourceMode == "server" else {
                browser.clearHelperPass()
                await browser.clearFocus()
                return
            }
            await browser.refreshHelperPass()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
                await browser.refreshHelperPass()
            }
        }
        .sheet(isPresented: $model.showsExportPanel, onDismiss: {
            model.discardFolderExportRequest()
        }) {
            ExportPanel(model: model)
        }
    }

    private var serverRotatePool: [LibraryAsset] {
        switch librarySection {
        case "Review":
            return browser.reviewRows
        case "Duplicates":
            return browser.duplicateGroups.flatMap(\.members)
        default:
            return browser.rows
        }
    }

    private func rotateServerSelection(clockwise: Bool) {
        var files: [URL] = []
        var catalog: [String: CatalogEditTarget] = [:]
        for asset in browser.rotatableStills(in: serverRotatePool) {
            guard let url = browser.fileURL(for: asset), let relativePath = asset.relPath else { continue }
            files.append(url)
            catalog[FolderEntry.cacheKey(for: url)] = CatalogEditTarget(uid: asset.uid, relativePath: relativePath)
        }
        model.rotate(files: files, clockwise: clockwise, catalog: catalog)
    }

    private func exportServerSelection() {
        var files: [URL] = []
        for asset in browser.rotatableStills(in: serverRotatePool) {
            guard let url = browser.fileURL(for: asset) else { continue }
            files.append(url)
        }
        model.beginFolderExport(files: files)
    }

    private func printServerSelection() {
        var files: [URL] = []
        for asset in browser.rotatableStills(in: serverRotatePool) {
            guard let url = browser.fileURL(for: asset) else { continue }
            files.append(url)
        }
        model.printFolderFiles(files)
    }

    private func pasteServerSelection() {
        model.pasteLibraryStills(browser.rotatableStills(in: serverRotatePool)) { browser.fileURL(for: $0) }
    }

    /// Rotate sits beside the Folder/Image tabs in both views. Paste settings, Export, and Print are Folder only.
    private func rotateButtons(
        enabled: Bool,
        showPaste: Bool,
        perform: @escaping (Bool) -> Void,
        paste: @escaping () -> Void,
        export: @escaping () -> Void,
        printPhotos: @escaping () -> Void
    ) -> some View {
        let leftHelp = showPaste
            ? "Turns the selected photos a quarter turn to the left, saves their settings, and rebuilds their previews."
            : "Turns this photo a quarter turn to the left, saves its settings, and rebuilds its preview."
        let rightHelp = showPaste
            ? "Turns the selected photos a quarter turn to the right, saves their settings, and rebuilds their previews."
            : "Turns this photo a quarter turn to the right, saves its settings, and rebuilds its preview."
        return HStack(spacing: 8) {
            Button("Rotate left") { perform(false) }
                .buttonStyle(LibraryPushButtonStyle())
                .disabled(!enabled)
                .accessibilityIdentifier("Rotate left")
                .help(leftHelp)
            Button("Rotate right") { perform(true) }
                .buttonStyle(LibraryPushButtonStyle())
                .disabled(!enabled)
                .accessibilityIdentifier("Rotate right")
                .help(rightHelp)
            if showPaste {
                Button("Paste settings") { paste() }
                    .buttonStyle(LibraryPushButtonStyle())
                    .disabled(!model.hasCopiedSettings || !enabled)
                    .accessibilityIdentifier("Folder paste settings")
                    .help("Applies the copied Tone and Geometry settings to the selected photos, saves them, and rebuilds their previews.")
                Button("Export") { export() }
                    .buttonStyle(LibraryPushButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(!enabled)
                    .accessibilityIdentifier("Folder export")
                    .help("Writes a new file for each selected photo. The original photos are not changed.")
                Button("Print") { printPhotos() }
                    .buttonStyle(LibraryPushButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(!enabled)
                    .accessibilityIdentifier("Folder print")
                    .help("Prints each selected photo.")
            }
            if let note = model.folderRotateNote {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .lineLimit(1)
                    .accessibilityIdentifier("Rotate status")
            }
        }
    }

    private func folderColumn(width: CGFloat, available: CGFloat) -> some View {
        HStack(spacing: 0) {
            if diskMode {
                EditorFolderTree(model: model)
                    .frame(width: width)
                EditorFolderDivider(
                    width: Binding(
                        get: { CGFloat(treeWidth) },
                        set: { treeWidth = Double($0) }
                    ),
                    available: available
                )
            } else {
                Sidebar(selection: $librarySection, browser: browser) {
                    serverShowsFolder = true
                }
                .frame(width: width)
                LibrarySidebarDivider(
                    width: Binding(
                        get: { CGFloat(libraryTreeWidth) },
                        set: { libraryTreeWidth = Double($0) }
                    ),
                    available: available
                )
            }
        }
    }

    private func toolbar(column: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                if diskMode {
                    cacheMenu
                    Button("Open File") {
                        sourceMode = "disk"
                        model.openFile()
                    }
                    .help("Opens one still image, a Sigma X3F preview, or a PDF.")
                    Button("Open Folder") {
                        sourceMode = "disk"
                        model.openFolder()
                    }
                    .help("Shows this folder's stills and videos, and its subfolders in the tree.")
                } else {
                    serverMenu
                }
            }
            .padding(.leading, 16)
            .frame(minWidth: column + 8, alignment: .leading)
            HStack(spacing: 12) {
                Text("Source")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(true)
                Picker("Source", selection: $sourceMode) {
                    Text("Disk").tag("disk")
                    Text("Server").tag("server")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .accessibilityIdentifier("Source mode")
            }
            .padding(.leading, 20)
            .layoutPriority(1)
            if !diskMode, let line = DuplicateCopy.passLine(browser.helperPass) {
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .accessibilityIdentifier("Helper status")
            }
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                if diskMode || showsImage {
                    Button("Undo") { model.undo() }
                        .disabled(!model.log.canUndo)
                    Button("Redo") { model.redo() }
                        .disabled(!model.log.canRedo)
                    Button("Copy settings") { model.copySettings() }
                        .disabled(model.proxy == nil)
                        .accessibilityIdentifier("Copy settings")
                        .help("Copies the Tone and Geometry settings.")
                    Button("Paste settings") { model.pasteSettings() }
                        .disabled(!model.hasCopiedSettings || model.proxy == nil)
                        .accessibilityIdentifier("Paste settings")
                        .help("Applies the copied Tone and Geometry settings.")
                } else {
                    libraryPushButton("Events", identifier: "Events") {
                        showsEvents.toggle()
                        if showsEvents { serverShowsFolder = true }
                    }
                    libraryPushButton("Reorganize", identifier: "Reorganize") {
                        showsReorg.toggle()
                        if showsReorg { serverShowsFolder = true }
                    }
                }
            }
            .padding(.trailing, 16)
            .layoutPriority(1)
        }
        .padding(.vertical, 10)
        .background(ChromePalette.panel)
    }

    private var cacheMenu: some View {
        Menu {
            Menu("Cache") {
                Button("Set Cache Size") { model.askCacheSize() }
                Button("View Cache") { model.viewPreviewCache() }
                Button("Clear Cache") { model.clearPreviewCache() }
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .semibold))
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Menu")
        .accessibilityIdentifier("Main menu")
    }

    private var serverMenu: some View {
        Menu {
            Button("Choose Library Base Folder") { LibraryHost.pickLibraryFolder(browser: browser) }
                .accessibilityIdentifier("Choose Library Base Folder")
            Button("Pair with Helper") { LibraryHost.pairWithHelper(browser: browser) }
                .accessibilityIdentifier("Pair with Helper")
            Button("Clean folder") {
                Task { await browser.cleanDisplayFolder() }
            }
            .disabled(librarySection != "Photos" || browser.cleanBusy || browser.removalBusy || browser.dateBusy)
            .accessibilityIdentifier("Clean folder")
            .help("Removes catalog records in this folder whose files are gone and whose name and size match a photo that is still here. Photos on disk stay.")
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ChromePalette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(ChromePalette.muted.opacity(0.45), lineWidth: 1)
                )
                .accessibilityLabel("Library menu")
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier("Library menu")
    }

    private var inspector: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                InspectorSpectrum(model: model, collapsed: $spectrumCollapsed)
                inspectorRule
                InspectorTone(model: model, collapsed: $toneCollapsed)
                inspectorRule
                InspectorEyedropper(model: model, collapsed: $colorCollapsed)
                inspectorRule
                InspectorGeometry(model: model, collapsed: $geometryCollapsed)
                inspectorRule
                InspectorTouchup(model: model, collapsed: $touchupCollapsed)
                inspectorRule
                HistoryList(log: model.log, collapsed: $historyCollapsed) { index in
                    model.selectCommand(at: index)
                }
            }
            .frame(width: Self.inspectorColumn)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ChromePalette.panel)
    }

    private var inspectorRule: some View {
        Rectangle()
            .fill(ChromePalette.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    /// Both sources stay mounted. Hiding one keeps its preview-grid scroll offset.
    private var center: some View {
        ZStack {
            diskCenter
                .opacity(diskMode ? 1 : 0)
                .allowsHitTesting(diskMode)
                .accessibilityHidden(!diskMode)
            serverCenter
                .opacity(diskMode ? 0 : 1)
                .allowsHitTesting(!diskMode)
                .accessibilityHidden(diskMode)
        }
    }

    private var serverCenter: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("View", selection: $serverShowsFolder) {
                    Text("Folder").tag(true)
                    Text("Image").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .accessibilityIdentifier("Library tabs")
                rotateButtons(
                    enabled: serverShowsFolder
                        ? !browser.rotatableStills(in: serverRotatePool).isEmpty && !model.folderRotateBusy
                        : model.proxy != nil && !model.showsPDFPicker && !model.folderRotateBusy,
                    showPaste: serverShowsFolder
                ) { clockwise in
                    if serverShowsFolder {
                        rotateServerSelection(clockwise: clockwise)
                    } else if clockwise {
                        model.rotateClockwise()
                    } else {
                        model.rotateCounterclockwise()
                    }
                } paste: {
                    pasteServerSelection()
                } export: {
                    exportServerSelection()
                } printPhotos: {
                    printServerSelection()
                }
                if serverShowsFolder, let note = browser.notice, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundStyle(ChromePalette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("Library notice")
                }
                Spacer(minLength: 8)
                if showsImage {
                    imageActions
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            ZStack {
                libraryPage
                    .opacity(serverShowsFolder ? 1 : 0)
                    .allowsHitTesting(serverShowsFolder)
                    .accessibilityHidden(!serverShowsFolder)
                if model.showsPDFPicker, let document = model.pdfDocument, showsImage {
                    PDFPagePicker(
                        document: document,
                        pageIndex: $model.pdfPageIndex,
                        onOpen: { model.openSelectedPDFPage() },
                        onCancel: { model.cancelPDFPicker() }
                    )
                } else if showsImage {
                    VStack(spacing: 0) {
                        editorBar
                        canvas
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var libraryPage: some View {
        let live = !diskMode
        let onScreen = !diskMode && serverShowsFolder
        return Group {
            if librarySection == "Review" {
                ReviewList(browser: browser, model: model, live: live, onScreen: onScreen)
            } else if librarySection == "Duplicates" {
                DuplicatesBrowser(browser: browser, model: model, live: live, onScreen: onScreen)
            } else {
                LibraryGrid(browser: browser, model: model, media: "photo", live: live, onScreen: onScreen)
            }
        }
    }

    private var imageActions: some View {
        HStack(spacing: 8) {
            Button("Select") { model.toggleSelect() }
                .buttonStyle(LibraryPushButtonStyle())
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(model.canvasTool == .select ? Color(red: 140 / 255, green: 90 / 255, blue: 60 / 255) : Color.clear, lineWidth: 2)
                )
                .accessibilityIdentifier("Select")
                .help("Selects the whole image. Drag a corner or the middle of a side to change it. Click Select again to leave.")
                .disabled(model.preview == nil || model.showsPDFPicker)
            Button("Crop") { model.applyCrop() }
                .buttonStyle(LibraryPushButtonStyle())
                .accessibilityIdentifier("Crop")
                .help("Crops the image to the rectangle.")
                .disabled(!model.canCrop)
            Button("Export") { model.showExportPanel() }
                .fixedSize(horizontal: true, vertical: false)
                .help("Writes a new file. The original photo is not changed.")
            Button("Print") { model.printOpenPhoto() }
                .fixedSize(horizontal: true, vertical: false)
                .disabled(model.proxy == nil || model.showsPDFPicker || model.folderRotateBusy)
                .accessibilityIdentifier("Image print")
                .help("Prints this photo.")
        }
    }

    private var diskCenter: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Sub-folder")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .fixedSize()
                Toggle("Sub-folder", isOn: Binding(
                    get: { model.scanSubfolders },
                    set: { model.setScanSubfolders($0) }
                ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("Sub-folder")
                    .help("Shows images and videos from subfolders in the Folder view.")
                Picker("View", selection: $model.showsFolderGrid) {
                    Text("Folder").tag(true)
                    Text("Image").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("Editor tabs")
                rotateButtons(
                    enabled: model.showsFolderGrid
                        ? model.canRotateFolderSelection
                        : model.proxy != nil && !model.showsPDFPicker && !model.folderRotateBusy,
                    showPaste: model.showsFolderGrid
                ) { clockwise in
                    if model.showsFolderGrid {
                        model.rotateFolderSelection(clockwise: clockwise)
                    } else if clockwise {
                        model.rotateClockwise()
                    } else {
                        model.rotateCounterclockwise()
                    }
                } paste: {
                    model.pasteFolderSelection()
                } export: {
                    model.beginFolderExport(files: model.exportableFolderFiles())
                } printPhotos: {
                    model.printFolderFiles(model.exportableFolderFiles())
                }
                .padding(.leading, 18)
                Spacer(minLength: 8)
                if !model.showsFolderGrid {
                    imageActions
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            ZStack {
                FolderBrowser(model: model, onScreen: diskMode)
                    .opacity(model.showsFolderGrid ? 1 : 0)
                    .allowsHitTesting(model.showsFolderGrid)
                    .accessibilityHidden(!model.showsFolderGrid)
                if model.showsPDFPicker, let document = model.pdfDocument, !model.showsFolderGrid {
                    PDFPagePicker(
                        document: document,
                        pageIndex: $model.pdfPageIndex,
                        onOpen: { model.openSelectedPDFPage() },
                        onCancel: { model.cancelPDFPicker() }
                    )
                } else if !model.showsFolderGrid {
                    VStack(spacing: 0) {
                        editorBar
                        canvas
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorBar: some View {
        HStack(spacing: 12) {
            Button("Zoom") { model.selectCanvasTool(.zoom) }
                .buttonStyle(LibraryPushButtonStyle())
                .toolToggleBorder(active: model.canvasTool == .zoom)
                .accessibilityAddTraits(model.canvasTool == .zoom ? .isSelected : [])
                .help("Click zooms in. Option-click zooms out. Hold Space to pan.")
            if diskMode {
                RemoveObjectTool(model: model)
            }
            Slider(
                value: Binding(
                    get: { model.zoom.logarithmicPosition },
                    set: { model.setZoomSlider($0) }
                ),
                in: 0...1
            )
            .accessibilityLabel("Zoom")
            Text(model.zoom.factorLabel)
                .font(.system(size: 13))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ChromePalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Zoom")
    }

    private var canvas: some View {
        CanvasView(model: model)
    }
}
