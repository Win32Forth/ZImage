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

    func openSecurityScopedFile(at url: URL, keepLoadedLog: Bool = false) {
        fileOpenStarted = true
        showsFolderGrid = false
        showsPDFPicker = false
        pdfDocument = nil
        if !keepLoadedLog {
            rememberCurrentEdits()
            clearDocumentLink()
        }
        releaseFileScope()
        if url.startAccessingSecurityScopedResource() {
            fileScopeURL = url
        }
        let ext = url.pathExtension.lowercased()
        if ext == "zimg" {
            openZimg(at: url)
            return
        }
        if ext == "x3f" {
            openX3F(at: url)
            return
        }
        if ext == "pdf" {
            openPDF(at: url)
            return
        }
        openProxy(at: url)
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

    func exportStill(_ request: ExportRequest) {
        showsExportPanel = false
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
            invalidateTile()
            resetEditsForNewImage()
        } catch {
            failOpen(name: url.lastPathComponent, message: error.localizedDescription)
        }
    }

    private func openX3F(at url: URL) {
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

    private func openProxy(at url: URL) {
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
        openedFileName = name
        previewBanner = nil
        decodeSupport = .unsupported
        editBase = nil
        securityScopedBookmark = nil
        canvasMessage = message
        horizonClicks.removeAll()
        invalidateTile()
        clearDocumentLink()
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

    private func openZimg(at url: URL) {
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

    /// `releaseAccess` balances a `startAccessingSecurityScopedResource` done before the read.
    private func writeDocument(to url: URL, releaseAccess: Bool) {
        guard let sourceFileURL else {
            if releaseAccess {
                url.stopAccessingSecurityScopedResource()
            }
            presentAlert(ZImgError.cannotSave("Save needs the original photo.").localizedDescription)
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
            switch outcome {
            case .failure(let error):
                self.presentAlert(error.localizedDescription)
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
                    if self.previewBanner == nil || self.previewBanner == "Edits saved." {
                        self.previewBanner = "Edits saved."
                    }
                    if self.sourceFileURL.map(self.sourceKey) == savedKey {
                        self.documentURL = url
                        self.documentBookmark = fileBookmark
                        self.rememberCurrentEdits()
                    } else if var stored = self.editsBySource[savedKey] {
                        stored.documentURL = url
                        stored.documentBookmark = fileBookmark
                        self.editsBySource[savedKey] = stored
                    }
                } catch {
                    self.presentAlert(error.localizedDescription)
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
                self.folderListingReady = true
                self.folderMessage = "Could not read this folder."
                return
            }
            self.folderEntries = listed
            self.folderListingReady = true
            self.folderMessage = nil
            self.preparePreviews(for: listed, generation: generation)
        }
    }

    private func preparePreviews(for entries: [FolderEntry], generation: Int) {
        let images = entries.filter { !$0.isDirectory }.map(\.url)
        Task {
            let built = await Task.detached { () -> [(String, URL)] in
                var pairs: [(String, URL)] = []
                for imageURL in images {
                    guard let jpeg = try? FolderPreviewCache.ensureJPEG(for: imageURL) else { continue }
                    pairs.append((FolderEntry.cacheKey(for: imageURL), jpeg))
                }
                return pairs
            }.value
            guard generation == self.folderGeneration else { return }
            for (path, jpeg) in built {
                self.previewJPEGByPath[path] = jpeg
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
            guard event.keyCode == 49 else { return event }
            let held = event.type == .keyDown
            MainActor.assumeIsolated {
                self?.spaceDown = held
            }
            return event
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

    func undo() {
        touchupGeneration += 1
        cancelProvisionalEdits()
        log.undo()
        cropSelection = nil
        syncDraftsFromLog()
        refreshPreview()
    }

    func redo() {
        touchupGeneration += 1
        cancelProvisionalEdits()
        log.redo()
        cropSelection = nil
        syncDraftsFromLog()
        refreshPreview()
    }

    func selectCommand(at index: Int) {
        touchupGeneration += 1
        cancelProvisionalEdits()
        log.selectCommand(at: index)
        cropSelection = nil
        syncDraftsFromLog()
        refreshPreview()
    }

    func pushSyntheticTone() {
        cancelProvisionalEdits()
        log.commit(.setTone(.identity, label: "Exposure"))
        syncDraftsFromLog()
        refreshPreview()
    }

    private(set) var hasCopiedSettings = false
    private var copiedTone = ToneState.identity
    private var copiedGeometry = GeometryState.identity

    /// Copies Tone and Geometry, including a slider that has not been released yet.
    func copySettings() {
        commitOpenDrafts()
        copiedTone = draftTone
        copiedGeometry = draftGeometry
        hasCopiedSettings = true
    }

    /// One history step. Crop and object removal stay as they are.
    func pasteSettings() {
        guard hasCopiedSettings, proxy != nil else { return }
        commitOpenDrafts()
        guard draftTone != copiedTone || draftGeometry != copiedGeometry else { return }
        log.commit(.pasteSettings(tone: copiedTone, geometry: copiedGeometry))
        syncDraftsFromLog()
        refreshPreview()
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

    private func rememberCurrentEdits() {
        guard let sourceFileURL else { return }
        commitOpenDrafts()
        editsBySource[sourceKey(sourceFileURL)] = PhotoEdits(
            log: log,
            documentURL: documentURL,
            documentBookmark: documentBookmark,
            display: preview
        )
    }

    /// Session edits win. Otherwise the `.zimg` saved for this file, including one that is not beside the photo.
    private func restoreEdits(for url: URL) -> Bool {
        if let session = editsBySource[sourceKey(url)] {
            log = session.log
            documentURL = session.documentURL
            documentBookmark = session.documentBookmark
            syncDraftsFromLog()
            savedCanvas = session.display
            if savedCanvas == nil, let digest = sourceDigest, let count = sourceByteCount,
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

    /// Mouse-up. One drag is one `setTone`.
    func endToneDrag() {
        toneDragActive = false
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
    }

    private func commitGeometryDraft() {
        guard draftGeometry != log.state.geometry else { return }
        log.commit(.setGeometry(draftGeometry, label: pendingGeometryLabel))
        refreshPreview()
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
            return
        }
        let longEdge = max(shaped.extent.width, shaped.extent.height)
        let toned = TonePipeline.apply(base: shaped, tone: draftTone, longEdge: longEdge)
        let extent = toned.extent.integral
        guard extent.width >= 1, extent.height >= 1 else {
            preview = nil
            return
        }
        let screen = NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        preview = toneContext.createCGImage(toned, from: extent, format: .RGBA8, colorSpace: screen)
        proxyRenderCount += 1
    }
}

struct Chrome: View {
    /// The inspector column. Undo, Redo, and Push tone share its trailing edge with Copy and Paste.
    private static let inspectorColumn: CGFloat = 320

    @Bindable var model: EditorModel
    @AppStorage("ZImage.folderTreeWidth") private var treeWidth = Double(EditorFolderSpan.initial)
    @AppStorage("ZImage.inspectorToneCollapsed") private var toneCollapsed = false
    @AppStorage("ZImage.inspectorGeometryCollapsed") private var geometryCollapsed = false
    @AppStorage("ZImage.inspectorColorCollapsed") private var colorCollapsed = false
    @AppStorage("ZImage.inspectorHistoryCollapsed") private var historyCollapsed = false
    @AppStorage("ZImage.inspectorTouchupCollapsed") private var touchupCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                HStack(spacing: 0) {
                    EditorFolderTree(model: model)
                        .frame(width: EditorFolderSpan.clamped(CGFloat(treeWidth), available: geo.size.width))
                    EditorFolderDivider(
                        width: Binding(
                            get: { CGFloat(treeWidth) },
                            set: { treeWidth = Double($0) }
                        ),
                        available: geo.size.width
                    )
                    center
                    inspector
                }
            }
        }
        .background(ChromePalette.panel)
        .foregroundStyle(ChromePalette.ink)
        .onAppear {
            FolderPreviewCache.loadStoredCap()
            model.restoreLastFolder()
            model.installCanvasKeys()
        }
        .sheet(isPresented: $model.showsExportPanel) {
            ExportPanel(model: model)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
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
            Button("Open File") { model.openFile() }
                .help("Opens one still image, a Sigma X3F preview, or a PDF.")
            Button("Open Folder") { model.openFolder() }
                .help("Shows this folder's stills and videos, and its subfolders in the tree.")
            Spacer(minLength: 12)
            Button("Undo") { model.undo() }
                .disabled(!model.log.canUndo)
            Button("Redo") { model.redo() }
                .disabled(!model.log.canRedo)
            Button("Push tone") { model.pushSyntheticTone() }
                .help("Adds an identity tone command so the history list can be exercised before an image is open.")
            Button("Copy settings") { model.copySettings() }
                .disabled(model.proxy == nil)
                .accessibilityIdentifier("Copy settings")
                .help("Copies the Tone and Geometry settings.")
            Button("Paste settings") { model.pasteSettings() }
                .disabled(!model.hasCopiedSettings || model.proxy == nil)
                .accessibilityIdentifier("Paste settings")
                .help("Applies the copied Tone and Geometry settings.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ChromePalette.panel)
    }

    private var inspector: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
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

    private var center: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Sub-folder")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                Toggle("Sub-folder", isOn: Binding(
                    get: { model.scanSubfolders },
                    set: { model.setScanSubfolders($0) }
                ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityIdentifier("Sub-folder")
                    .help("Shows images and videos from subfolders in the Folder view.")
                Picker("View", selection: $model.showsFolderGrid) {
                    Text("Folder").tag(true)
                    Text("Image").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .accessibilityIdentifier("Editor tabs")
                Spacer(minLength: 8)
                if !model.showsFolderGrid {
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
                        .help("Writes a new file. The original photo is not changed.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            ZStack {
                FolderBrowser(model: model)
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
            RemoveObjectTool(model: model)
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
