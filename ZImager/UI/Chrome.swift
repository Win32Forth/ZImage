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
    /// Click order. The first id is the left or the top when two photos are merged.
    var folderSelectionOrder: [String] = []
    var folderSelectionAnchor: String?
    var folderRotateBusy = false
    var folderRotateNote: String?
    /// Bumped after a Disk move creates a folder, so the left tree rereads its parent.
    var folderTreeRevision = 0
    /// Parents of folders a Disk move just created.
    var folderTreeParents: [URL] = []
    /// The joined photo on screen. Nil until Preview has drawn it.
    var mergePreviewImage: CGImage?
    var mergePreviewRight = 0
    var mergePreviewDown = 0
    var mergePreviewAxis = PhotoMergeAxis.horizontal
    /// True while the two photos are being read, or while Merge is writing the TIFF.
    var mergePreviewBusy = false
    /// Fit keeps the whole join in view. 100% is one point per pixel.
    var mergePreviewFitted = true
    /// Bumped each time 100% is chosen, so a second click recenters on the seam.
    var mergePreviewActualToken = 0
    /// Top-left of the first photo in the preview, in pixels. Y grows downward.
    var mergePreviewFirstOrigin = CGPoint.zero
    /// Pixel to center when 100% is chosen. Y grows downward.
    var mergePreviewFocus = CGPoint.zero
    /// Nil on Disk. The Server folder the preview was opened from.
    private(set) var mergePreviewServerFolder: String?
    static let mergePreviewingNote = "Previewing the join."
    /// Clears the previewing note, or reports a photo that could not be read.
    @ObservationIgnored
    var onMergePreviewNote: ((String?) -> Void)?
    private var mergePreviewFirst: CGImage?
    private var mergePreviewSecond: CGImage?
    private var mergePreviewFirstURL: URL?
    private var mergePreviewSecondURL: URL?
    private var mergePreviewDirectory: URL?
    private var mergePreviewGeneration = 0
    private var mergePreviewRenderToken = 0
    private var mergePreviewRendering = false
    var folderListingReady = false
    var folderMessage: String?
    var showsFolderGrid = false
    /// When on, the Folder view lists images and videos found in subfolders.
    var scanSubfolders = false
    /// Text in the Disk folder name field. Find copies this into `folderNameFilter`.
    var folderNameQuery = ""
    /// Applied name filter. Empty shows every file in the folder.
    var folderNameFilter = ""
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
    /// Set by a library-grid open, then consumed when that file's proxy is read.
    private var openingCatalog: CatalogEditTarget?
    var pdfDocument: PDFDocument?
    var pdfPageIndex = PDFImport.defaultPageIndex
    var canvasSize: CGSize = .zero
    private(set) var preview: CGImage?
    /// A movie is open in the image view, including while its first frame is still loading.
    private(set) var showsVideo = false
    /// The player on the canvas. Nil until the file is ready.
    private(set) var videoPlayback: VideoPlayback?
    /// Path key of the movie being opened or played.
    private var videoKey: String?
    /// The movie file on the canvas. Export reads this and writes a different file.
    private var videoSourceURL: URL?
    /// True while a graded movie is being written.
    private(set) var videoExportBusy = false
    /// Tone last used for each movie this session. Export can write it into a new file.
    @ObservationIgnored
    private var videoGrades: [String: ToneState] = [:]
    /// Small frame for the Spectrum graph and Auto while a movie is open.
    private var videoPoster: CIImage?
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
    /// Spot clicks not yet finished, including the one running. The canvas and the Touchup panel show this.
    var touchupSpotsRemaining = 0
    /// Display-tone histogram behind the Spectrum handles. Empty until a photograph is open.
    var spectrumBins: [Int] = []
    private var spectrumDragActive = false
    private var touchupGeneration = 0
    /// The generation that currently owns `touchupBusy`. A finished older job does not clear a newer one.
    private var touchupBusyGeneration = 0
    /// Repairs waiting their turn, including the one running. Further Spot clicks append here.
    @ObservationIgnored
    private var touchupQueue = TouchupQueue()
    /// Banner text from before this list started. Nil is a real saved value once `touchupBannerCaptured` is set.
    @ObservationIgnored
    private var touchupBannerCaptured = false
    @ObservationIgnored
    private var touchupBannerRestore: String?
    /// The running repair's banner, without the spots-left suffix.
    @ObservationIgnored
    private var touchupBannerBase: String?
    /// The picture after the current inpaint list, so the next spot does not rebuild every earlier repair.
    @ObservationIgnored
    private var touchupHead: (token: Int, operations: [InpaintOp], image: CIImage)?
    /// The frame `touchupHead` was painted from. A later token for the same pixels still matches.
    @ObservationIgnored
    private var touchupHeadFrame: TouchupFrame?
    /// Recent on-screen pictures, so Undo of a spot puts the speck back without rebuilding the rest.
    @ObservationIgnored
    private var touchupPictures = TouchupPictures()
    /// A cold replay is already running off the main thread. Further preview requests wait for it.
    @ObservationIgnored
    private var touchupReplayInFlight = false
    @ObservationIgnored
    private var touchupReplayAgain = false
    /// The bar across the photograph while saved repairs are being rebuilt. Nil when that work is idle.
    var touchupMeter: TouchupMeter?
    /// True while Flatten is rendering the full-size TIFF.
    var flattenBusy = false
    @ObservationIgnored
    private var flattenGeneration = 0
    /// True while Export is writing a flattened TIFF at full size.
    var exportBusy = false
    @ObservationIgnored
    private var exportGeneration = 0
    @ObservationIgnored
    private var touchupMeterSerial = 0
    @ObservationIgnored
    private var touchupMeterTicket: Int?
    /// Preview pixels to repair pixels. Measured when the picture is drawn.
    /// A click must not ask Core Image for this while a repair is rendering that picture.
    @ObservationIgnored
    private var touchupBitmapScaleX: CGFloat = 1
    @ObservationIgnored
    private var touchupBitmapScaleY: CGFloat = 1
    @ObservationIgnored
    private var touchupBitmapScaleReady = false
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
        cancelDiskMergePreview()
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
        cancelDiskMergePreview()
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
            openVideo(at: entry.url)
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

    /// Files the Disk folder grid is showing. A name filter hides the rest.
    var visibleFolderEntries: [FolderEntry] {
        folderEntries.filter { entry in
            guard !entry.isDirectory else { return false }
            return FolderNameFilter.matches(entry.name, query: folderNameFilter)
        }
    }

    /// The page of the Disk folder grid. Zero is the first 200 photos.
    var folderPage = 0

    var folderPhotos: [FolderEntry] {
        visibleFolderEntries.filter { !$0.isVideo }
    }

    var folderPhotoCount: Int { folderPhotos.count }

    var showsFolderPager: Bool { folderPhotoCount > FolderPage.limit }

    var folderPageIndex: Int {
        min(folderPage, FolderPage.pageCount(total: folderPhotoCount) - 1)
    }

    var folderPageCount: Int { FolderPage.pageCount(total: folderPhotoCount) }

    var folderPagePhotoCount: Int {
        let start = folderPageIndex * FolderPage.limit
        return min(FolderPage.limit, max(0, folderPhotoCount - start))
    }

    var folderPagerRange: String {
        FolderPage.range(page: folderPageIndex, countOnPage: folderPagePhotoCount, total: folderPhotoCount)
    }

    /// Photos on this page. Videos stay on the first page and are not part of the count.
    var pagedFolderEntries: [FolderEntry] {
        let photos = folderPhotos
        guard photos.count > FolderPage.limit else { return visibleFolderEntries }
        let page = folderPageIndex
        let start = page * FolderPage.limit
        let slice = photos[start..<min(start + FolderPage.limit, photos.count)]
        let ids = Set(slice.map(\.id))
        if page == 0 {
            return visibleFolderEntries.filter { $0.isVideo || ids.contains($0.id) }
        }
        return Array(slice)
    }

    func showFolderPage(_ index: Int) {
        let last = folderPageCount - 1
        folderPage = min(max(0, index), last)
    }

    func findFolderByName() {
        folderNameFilter = folderNameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        folderPage = 0
    }

    func clearFolderNameFilter() {
        folderNameQuery = ""
        folderNameFilter = ""
        folderPage = 0
    }

    /// Stills in the folder grid, in the order the grid shows them. Videos stay put.
    private var listedFolderImages: [FolderEntry] {
        pagedFolderEntries.filter { !$0.isVideo }
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

    /// Gives one folder file a new name in the folder it is already in.
    func renameFolderEntry(_ entry: FolderEntry, to typed: String) {
        guard !showsDiskMergePreview, !mergePreviewBusy, !folderRotateBusy, !exportBusy else {
            folderRotateNote = "An export is already running."
            return
        }
        guard !entry.isDirectory else { return }
        switch FileRename.perform(source: entry.url, typed: typed) {
        case .failure(let problem):
            let label: String
            if case .success(let cleaned) = FileRename.cleaned(typed) {
                label = cleaned
            } else {
                label = typed
            }
            if let message = FileRename.message(for: problem, name: label) {
                folderRotateNote = message
            }
        case .success(let dest):
            let updated = FolderEntry(
                url: dest,
                name: dest.lastPathComponent,
                isDirectory: false,
                isVideo: entry.isVideo
            )
            if let index = folderEntries.firstIndex(where: { $0.id == entry.id }) {
                folderEntries[index] = updated
            }
            let oldKey = entry.id
            let newKey = updated.id
            if selectedFolderKeys.contains(oldKey) {
                selectedFolderKeys.remove(oldKey)
                selectedFolderKeys.insert(newKey)
            }
            if selectedFolderKey == oldKey { selectedFolderKey = newKey }
            if folderSelectionAnchor == oldKey { folderSelectionAnchor = newKey }
            folderSelectionOrder = folderSelectionOrder.map { $0 == oldKey ? newKey : $0 }
            if let jpeg = previewJPEGByPath.removeValue(forKey: oldKey) {
                previewJPEGByPath[newKey] = jpeg
            }
            if let edited = editedPreviewData.removeValue(forKey: oldKey) {
                editedPreviewData[newKey] = edited
            }
            if let pendingOpenURL, FolderEntry.cacheKey(for: pendingOpenURL) == oldKey {
                self.pendingOpenURL = dest
            }
            if let sourceFileURL, FolderEntry.cacheKey(for: sourceFileURL) == oldKey {
                self.sourceFileURL = dest
            }
            if let documentURL, FolderEntry.cacheKey(for: documentURL) == oldKey {
                self.documentURL = dest
            }
            folderRotateNote = "Renamed to \(dest.lastPathComponent)."
        }
    }

    /// Selected files in the Disk folder. Directories stay where they are.
    func diskMoveTargets() -> [FolderEntry] {
        folderEntries.filter { selectedFolderKeys.contains($0.id) && !$0.isDirectory }
    }

    /// Moves the selection into the named folder. Unchecked creates it under the opened root.
    /// Checked creates it inside the folder on screen.
    func moveSelectedFolderFiles(to typed: String, subfolder: Bool) {
        guard !showsDiskMergePreview, !mergePreviewBusy, !folderRotateBusy, !exportBusy else {
            folderRotateNote = "An export is already running."
            return
        }
        guard let name = FolderMove.folderName(typed) else {
            folderRotateNote = "Type a folder name."
            return
        }
        guard let root = browseRoot, let open = folderURL else {
            folderRotateNote = "Select a file to move."
            return
        }
        let chosen = diskMoveTargets()
        guard !chosen.isEmpty else {
            folderRotateNote = "Select a file to move."
            return
        }
        var items: [(source: URL, directory: URL)] = []
        for entry in chosen {
            guard let directory = FolderMove.diskDestination(
                root: root,
                openFolder: open,
                file: entry.url,
                folderName: name,
                subfolder: subfolder
            ) else { continue }
            items.append((entry.url, directory))
        }
        guard !items.isEmpty else {
            folderRotateNote = "Those files are not in this folder."
            return
        }
        folderRotateBusy = true
        let total = items.count
        Task {
            var moved = 0
            var stayed = 0
            var directories: [URL] = []
            for (index, item) in items.enumerated() {
                self.folderRotateNote = "Moving \(index + 1) of \(total) to \(item.directory.lastPathComponent)."
                await Task.yield()
                let step = await Task.detached {
                    FolderMove.perform(files: [item])
                }.value
                moved += step.moved
                stayed += step.stayed
                for directory in step.directories {
                    let key = FolderEntry.cacheKey(for: directory)
                    if !directories.contains(where: { FolderEntry.cacheKey(for: $0) == key }) {
                        directories.append(directory)
                    }
                }
            }
            stayed += chosen.count - items.count
            self.folderRotateBusy = false
            if moved > 0 {
                self.noteDiskFoldersCreated(directories)
                self.reloadFolderListing()
            }
            let labels = directories.map { self.diskPlaceLabel(root: root, directory: $0) }
            let outcome = FolderMove.Outcome(moved: moved, stayed: stayed, directories: labels)
            self.folderRotateNote = FolderMove.finishedNotice(name: name, outcome: outcome)
        }
    }

    private func noteDiskFoldersCreated(_ directories: [URL]) {
        var parents: [URL] = []
        for directory in directories {
            let parent = directory.deletingLastPathComponent()
            let key = FolderEntry.cacheKey(for: parent)
            if !parents.contains(where: { FolderEntry.cacheKey(for: $0) == key }) {
                parents.append(parent)
            }
        }
        folderTreeParents = parents
        folderTreeRevision += 1
    }

    /// The destination named from the opened root, such as `Vacation/Album`.
    private func diskPlaceLabel(root: URL, directory: URL) -> String {
        let rootKey = FolderEntry.cacheKey(for: root)
        let directoryKey = FolderEntry.cacheKey(for: directory)
        if directoryKey.hasPrefix(rootKey + "/") {
            return String(directoryKey.dropFirst(rootKey.count + 1))
        }
        return directory.lastPathComponent
    }

    /// File size for the folder menu, in Finder's decimal megabytes.
    func sizeLabel(for entry: FolderEntry) -> String {
        let bytes = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return LibraryItemMenu.sizeLabel(bytes: bytes)
    }

    /// Plays the movie in the image view and grades it with the Tone panel.
    func openVideo(at url: URL) {
        fileOpenStarted = true
        openGeneration += 1
        let generation = openGeneration
        showsFolderGrid = false
        showsPDFPicker = false
        pdfDocument = nil
        rememberCurrentEdits()
        clearDocumentLink()
        stopVideoPlayback()
        clearStillForVideo()
        showsVideo = true
        openedFileName = url.lastPathComponent
        canvasMessage = "Opening video…"
        selectCanvasTool(.zoom)
        releaseFileScope()
        if url.startAccessingSecurityScopedResource() {
            fileScopeURL = url
        }
        let key = FolderEntry.cacheKey(for: url)
        videoKey = key
        videoSourceURL = url
        let remembered = videoGrades[key] ?? ToneState.identity
        if remembered != .identity {
            draftTone = remembered
            log.commit(.setTone(remembered, label: "Tone"))
        }
        Task {
            let playback = await VideoPlayback.make(url: url, tone: self.draftTone)
            guard generation == self.openGeneration else {
                playback?.stop()
                return
            }
            guard let playback else {
                self.showsVideo = false
                self.videoKey = nil
                self.videoSourceURL = nil
                self.canvasMessage = "This video could not be opened."
                return
            }
            self.videoPlayback = playback
            self.videoPoster = playback.poster
            self.canvasMessage = nil
            playback.setTone(self.draftTone)
            self.refreshSpectrumHistogram()
            playback.play()
        }
    }

    /// Drops the player. The tone for this movie stays in memory for the session.
    private func stopVideoPlayback() {
        if showsVideo, let videoKey {
            videoGrades[videoKey] = draftTone
        }
        videoPlayback?.stop()
        videoPlayback = nil
        videoPoster = nil
        videoKey = nil
        videoSourceURL = nil
        showsVideo = false
    }

    /// Removes the still so the canvas can show a movie.
    private func clearStillForVideo() {
        cancelTouchupQueue()
        proxy = nil
        baseCI = nil
        preview = nil
        spectrumBins = []
        previewBanner = nil
        decodeSupport = nil
        editBase = nil
        cropSelection = nil
        savedCanvas = nil
        sourceFileURL = nil
        sourceDigest = nil
        sourceByteCount = nil
        sourceUTI = nil
        securityScopedBookmark = nil
        pendingOpenURL = nil
        catalogAssetUID = nil
        catalogRelPath = nil
        resetEditsForNewImage()
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

    /// Applications that can open this still. ZImager is listed first.
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

    /// Opens the still in another application. Choosing ZImager edits it in this window.
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
        let order = pagedFolderEntries.map(\.id)
        let choice = GridSelection.choose(
            order: order,
            anchor: folderSelectionAnchor,
            clicked: entry.id,
            shift: shift,
            extend: extend,
            existing: selectedFolderKeys
        )
        folderSelectionOrder = SelectionOrder.update(
            previous: folderSelectionOrder,
            gridOrder: order,
            anchor: folderSelectionAnchor,
            clicked: entry.id,
            shift: shift,
            extend: extend,
            keys: choice.keys
        )
        selectedFolderKeys = choice.keys
        folderSelectionAnchor = choice.anchor
        selectedFolderKey = choice.primary
    }

    /// The selected stills in click order. A photo chosen without a click follows the folder list.
    func orderedMergeStills() -> [FolderEntry] {
        let stills = folderEntries.filter { selectedFolderKeys.contains($0.id) && !$0.isDirectory && !$0.isVideo }
        var ordered: [FolderEntry] = []
        for id in folderSelectionOrder {
            if let entry = stills.first(where: { $0.id == id }) {
                ordered.append(entry)
            }
        }
        for entry in stills where !ordered.contains(where: { $0.id == entry.id }) {
            ordered.append(entry)
        }
        return ordered
    }

    func mergeFolderPair() -> (first: String, second: String)? {
        let stills = orderedMergeStills()
        guard stills.count == 2 else { return nil }
        return (stills[0].name, stills[1].name)
    }

    var showsDiskMergePreview: Bool {
        mergePreviewDirectory != nil && mergePreviewServerFolder == nil
    }

    var showsServerMergePreview: Bool {
        mergePreviewServerFolder != nil
    }

    /// Shows the two Disk photos joined flush. Arrow keys move the second one.
    func beginFolderMergePreview(axis: PhotoMergeAxis) {
        guard !folderRotateBusy, !exportBusy else {
            folderRotateNote = "An export is already running."
            return
        }
        guard !mergePreviewBusy else { return }
        let stills = orderedMergeStills()
        guard stills.count == 2 else {
            folderRotateNote = "Select two photos."
            return
        }
        let first = stills[0].url
        let second = stills[1].url
        let folder1 = first.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let folder2 = second.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard folder1 == folder2 else {
            folderRotateNote = "Select two photos in the same folder."
            return
        }
        let firstPath = first.standardizedFileURL.resolvingSymlinksInPath()
        let secondPath = second.standardizedFileURL.resolvingSymlinksInPath()
        guard firstPath != secondPath else {
            folderRotateNote = "Select two different photos."
            return
        }
        folderRotateNote = Self.mergePreviewingNote
        beginMergePreview(first: first, second: second, directory: folder1, axis: axis, serverFolder: nil)
    }

    /// Shows the two photos joined flush. `serverFolder` is nil for a Disk folder.
    func beginMergePreview(
        first: URL,
        second: URL,
        directory: URL,
        axis: PhotoMergeAxis,
        serverFolder: String?
    ) {
        mergePreviewGeneration += 1
        mergePreviewRenderToken += 1
        let generation = mergePreviewGeneration
        mergePreviewImage = nil
        mergePreviewFirst = nil
        mergePreviewSecond = nil
        mergePreviewRight = 0
        mergePreviewDown = 0
        mergePreviewFitted = true
        mergePreviewActualToken = 0
        mergePreviewAxis = axis
        mergePreviewFirstURL = first
        mergePreviewSecondURL = second
        mergePreviewDirectory = directory
        mergePreviewServerFolder = serverFolder
        mergePreviewFirstOrigin = .zero
        mergePreviewFocus = .zero
        mergePreviewBusy = true
        Task {
            let loaded = await Task.detached { () -> (CGImage?, CGImage?) in
                (PhotoMerge.loadImage(at: first), PhotoMerge.loadImage(at: second))
            }.value
            guard generation == self.mergePreviewGeneration else { return }
            guard let primary = loaded.0, let secondary = loaded.1 else {
                self.mergePreviewBusy = false
                self.cancelMergePreview()
                self.onMergePreviewNote?("The photos could not be read.")
                return
            }
            self.mergePreviewFirst = primary
            self.mergePreviewSecond = secondary
            self.mergePreviewBusy = false
            self.scheduleMergePreview()
        }
    }

    /// Changing Horizontal or Vertical starts again from a flush join.
    func retargetMergePreview(axis: PhotoMergeAxis) {
        guard mergePreviewDirectory != nil, axis != mergePreviewAxis else { return }
        mergePreviewAxis = axis
        mergePreviewRight = 0
        mergePreviewDown = 0
        guard mergePreviewFirst != nil else { return }
        scheduleMergePreview()
    }

    /// Moves the second photo by one screen pixel. Returns true while a preview is up.
    func nudgeMergePreview(right dx: Int, down dy: Int) -> Bool {
        guard mergePreviewDirectory != nil else { return false }
        guard let first = mergePreviewFirst, let second = mergePreviewSecond, !mergePreviewBusy else { return true }
        guard let current = PhotoMerge.frame(
            first: first,
            second: second,
            axis: mergePreviewAxis,
            right: mergePreviewRight,
            down: mergePreviewDown
        ) else { return true }
        let placed = PhotoMerge.limit(
            right: mergePreviewRight + dx,
            down: mergePreviewDown + dy,
            axis: mergePreviewAxis,
            firstWidth: first.width,
            firstHeight: first.height,
            secondWidth: current.secondWidth,
            secondHeight: current.secondHeight
        )
        guard placed.right != mergePreviewRight || placed.down != mergePreviewDown else { return true }
        mergePreviewRight = placed.right
        mergePreviewDown = placed.down
        scheduleMergePreview()
        return true
    }

    func cancelDiskMergePreview() {
        guard showsDiskMergePreview else { return }
        cancelMergePreview()
    }

    func cancelServerMergePreview() {
        guard showsServerMergePreview else { return }
        cancelMergePreview()
    }

    func cancelMergePreviewIfServerFolderChanged(_ folder: String) {
        guard let current = mergePreviewServerFolder, current != folder else { return }
        cancelMergePreview()
    }

    func cancelMergePreview() {
        mergePreviewGeneration += 1
        mergePreviewRenderToken += 1
        mergePreviewBusy = false
        mergePreviewImage = nil
        mergePreviewFirst = nil
        mergePreviewSecond = nil
        mergePreviewFirstURL = nil
        mergePreviewSecondURL = nil
        mergePreviewDirectory = nil
        mergePreviewServerFolder = nil
        mergePreviewRight = 0
        mergePreviewDown = 0
        mergePreviewFirstOrigin = .zero
        mergePreviewFocus = .zero
    }

    /// Writes the TIFF at the offsets on screen. The caller closes the preview after a success.
    func writeMergePreview() async -> Result<String, PhotoMergeFailure> {
        guard let first = mergePreviewFirstURL,
              let second = mergePreviewSecondURL,
              let directory = mergePreviewDirectory else {
            return .failure(.cannotWrite)
        }
        let axis = mergePreviewAxis
        let right = mergePreviewRight
        let down = mergePreviewDown
        mergePreviewBusy = true
        let result = await Task.detached {
            PhotoMerge.perform(
                first: first,
                second: second,
                axis: axis,
                directory: directory,
                placement: (right: right, down: down)
            )
        }.value
        mergePreviewBusy = false
        return result
    }

    /// Saves the Disk preview and shows the new TIFF in this folder.
    func commitFolderMergePreview() {
        guard showsDiskMergePreview else { return }
        guard !folderRotateBusy, !exportBusy else {
            folderRotateNote = "An export is already running."
            return
        }
        guard !mergePreviewBusy else { return }
        folderRotateNote = "Merging the two photos."
        Task {
            let result = await self.writeMergePreview()
            switch result {
            case .success(let name):
                self.cancelMergePreview()
                self.folderRotateNote = "Merged into \(name)."
                self.reloadFolderListing()
            case .failure(let error):
                self.folderRotateNote = error.message
            }
        }
    }

    private func scheduleMergePreview() {
        mergePreviewRenderToken += 1
        guard !mergePreviewRendering else { return }
        mergePreviewRendering = true
        Task { await self.renderMergePreview() }
    }

    /// Drops a frame when a newer arrow has already moved the second photo.
    private func renderMergePreview() async {
        while true {
            let token = mergePreviewRenderToken
            guard mergePreviewDirectory != nil,
                  let first = mergePreviewFirst,
                  let second = mergePreviewSecond else {
                mergePreviewRendering = false
                return
            }
            let axis = mergePreviewAxis
            let right = mergePreviewRight
            let down = mergePreviewDown
            let placed = PhotoMerge.frame(first: first, second: second, axis: axis, right: right, down: down)
            let image = await Task.detached {
                PhotoMerge.render(first: first, second: second, axis: axis, right: right, down: down)
            }.value
            guard token == self.mergePreviewRenderToken, self.mergePreviewDirectory != nil else { continue }
            if let image {
                self.mergePreviewImage = image
                if let placed {
                    self.mergePreviewFirstOrigin = CGPoint(x: placed.firstX, y: placed.firstTop)
                    self.mergePreviewFocus = CGPoint(x: placed.focusX, y: placed.focusY)
                }
                self.onMergePreviewNote?(nil)
            }
            if token == self.mergePreviewRenderToken {
                self.mergePreviewRendering = false
                return
            }
        }
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

    private func publishOpenPreview(folderJPEG: Data? = nil) {
        guard let url = sourceFileURL, let preview else { return }
        let identity = log.state == .identity && log.commands.isEmpty
        // Flatten stores the pixels in the TIFF and clears the edit list. The folder cell
        // keeps that picture. A photo with no flatten file still falls back to the original.
        if log.state == .identity && !hasFlattenedSidecar {
            storeFolderPreview(url, renderedJPEG: nil, identity: true)
        } else if let jpeg = folderJPEG ?? ZImgRaw.jpegPreview(from: preview, maxLongEdge: FolderPreviewCache.maxLongEdge) {
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
            dropLocalEditCopy(digest: digest)
        } catch {
            return
        }
    }

    /// The library file is the one that remains. This Mac copy is only the send buffer.
    private func dropLocalEditCopy(digest: String) {
        let local = try? LocalEditStore.fileURL(digest: digest)
        LocalEditStore.discard(digest: digest)
        guard let path = local?.standardizedFileURL.path else { return }
        if documentURL?.standardizedFileURL.path == path {
            documentURL = nil
            documentBookmark = nil
        }
        for key in editsBySource.keys {
            guard var edits = editsBySource[key],
                  edits.documentURL?.standardizedFileURL.path == path else { continue }
            edits.documentURL = nil
            edits.documentBookmark = nil
            editsBySource[key] = edits
        }
    }

    /// A server-grid open. The asset id is already known, so the flattened TIFF can be the edit base.
    func openCatalogPhoto(at url: URL, uid: String, relativePath: String) {
        openingCatalog = CatalogEditTarget(uid: uid, relativePath: relativePath)
        openSecurityScopedFile(at: url, switchToImageTab: false)
    }

    func openSecurityScopedFile(at url: URL, keepLoadedLog: Bool = false, switchToImageTab: Bool = true) {
        fileOpenStarted = true
        let catalogHint = openingCatalog
        openingCatalog = nil
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
        stopVideoPlayback()
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
        openProxy(at: url, generation: generation, catalog: catalogHint)
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
                    self.dropLocalEditCopy(digest: digest)
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
        guard generation == catalogGeneration, helperUp, let editorHelper, let sourceFileURL, let sourceDigest else {
            guard generation == catalogGeneration else { return }
            if log.commands.isEmpty { _ = applyOnDiskCatalogLog() }
            adoptFlattenedBaseIfPresent()
            return
        }
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
        guard log.commands.isEmpty else {
            adoptFlattenedBaseIfPresent()
            return
        }
        let saved: Data?
        do {
            saved = try await editorHelper.edits(uid: asset.uid)
        } catch {
            saved = sidecarZimg(uid: asset.uid)
        }
        guard generation == catalogGeneration else { return }
        if let saved, let document = try? ZImgRaw.read(saved),
           document.base.kind == .catalogRef,
           document.base.assetUID == asset.uid,
           document.base.blake3 == sourceDigest,
           sourceByteCount == nil || document.base.byteSize == sourceByteCount {
            if let hint = document.base.relativePathHint, !hint.isEmpty {
                catalogRelPath = hint
            }
            applyCatalogLog(document.history, previewJPEG: document.previewJPEG)
        }
        adoptFlattenedBaseIfPresent()
    }

    /// The `.zimg` on the library share. Used when the helper does not answer.
    private func sidecarZimg(uid: String) -> Data? {
        guard let folder = libraryEditsFolder() else { return nil }
        let url = folder.appendingPathComponent(uid + ".zimg")
        return try? Data(contentsOf: url)
    }

    /// The library `.zimg` when this Mac has no edit list of its own. Returns true when that list is now current.
    private func applyOnDiskCatalogLog() -> Bool {
        guard let uid = catalogAssetUID, let digest = sourceDigest,
              let data = sidecarZimg(uid: uid),
              let document = try? ZImgRaw.read(data),
              document.base.kind == .catalogRef,
              document.base.assetUID == uid,
              document.base.blake3 == digest,
              sourceByteCount == nil || document.base.byteSize == sourceByteCount else { return false }
        if let hint = document.base.relativePathHint, !hint.isEmpty {
            catalogRelPath = hint
        }
        applyCatalogLog(document.history, previewJPEG: document.previewJPEG)
        return true
    }

    private func presentOpenedRepairs(quickLook: CGImage?) {
        if let quickLook {
            preview = quickLook
        }
        let generation = openGeneration
        let touchupTicket = touchupGeneration
        let token = touchupImageToken()
        let operations = touchupPreviewOperations()
        if let shaped = geometryImage(), operations.contains(where: { !$0.maskPNG.isEmpty }) {
            Task { @MainActor in
                guard let replayed = await self.awaitTouchupReplay(
                    shaped: shaped,
                    operations: operations,
                    token: token,
                    generation: generation,
                    touchupTicket: touchupTicket
                ) else { return }
                self.storeTouchupHead(token: token, operations: operations, image: replayed.image)
                self.rememberShownTouchup()
                self.refreshSpectrumHistogram()
                self.hideTouchupMeter(replayed.meter)
            }
        } else {
            self.refreshSpectrumHistogram()
        }
    }

    private func applyCatalogLog(_ saved: HistoryLog, previewJPEG: Data) {
        cancelProvisionalEdits()
        log = saved
        syncDraftsFromLog()
        if let saved = image(fromPreviewJPEG: previewJPEG) {
            preview = saved
            if let shaped = geometryImage() {
                rememberTouchupBitmapScale(
                    rasterWidth: shaped.extent.width,
                    rasterHeight: shaped.extent.height,
                    preview: saved
                )
            }
        } else {
            refreshPreview()
        }
    }

    /// Asks for a format, then writes a new file. The original path is refused.
    /// An open video writes a new movie with the Tone adjustments instead of a still.
    func showExportPanel() {
        guard !videoExportBusy else { return }
        if showsVideo {
            exportOpenVideo()
            return
        }
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

    /// Asks where to write the open movie. The Tone on screen is baked into the new file.
    private func exportOpenVideo() {
        guard videoPlayback != nil, let source = videoSourceURL else {
            presentAlert("This video is still opening.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = source.deletingLastPathComponent()
        let stem = (openedFileName as NSString?)?.deletingPathExtension ?? "Video"
        panel.nameFieldStringValue = stem + ".mp4"
        panel.prompt = "Export"
        panel.message = "The Tone adjustments are written into this movie. The original video is not changed."
        DispatchQueue.main.async {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            self.writeVideoExport(from: source, to: url)
        }
    }

    /// Writes the open movie to a new path. Playback pauses until the file is finished.
    private func writeVideoExport(from source: URL, to url: URL) {
        if FolderEntry.cacheKey(for: url) == FolderEntry.cacheKey(for: source) {
            presentAlert("Export leaves the original file unchanged.")
            return
        }
        let tone = draftTone
        if let videoKey {
            videoGrades[videoKey] = tone
        }
        let generation = openGeneration
        let wasPlaying = videoPlayback?.isPlaying ?? false
        videoPlayback?.pause()
        videoExportBusy = true
        previewBanner = "Exporting video…"
        let meter = VideoExportMeter()
        let started = url.startAccessingSecurityScopedResource()
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                let fraction = meter.load()
                if fraction > 0, generation == self.openGeneration, self.showsVideo {
                    let percent = min(99, Int((fraction * 100).rounded()))
                    self.previewBanner = "Exporting video… \(percent)%"
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        Task {
            defer {
                poll.cancel()
                if started {
                    url.stopAccessingSecurityScopedResource()
                }
                self.videoExportBusy = false
                if generation == self.openGeneration, self.showsVideo {
                    self.previewBanner = nil
                    if wasPlaying {
                        self.videoPlayback?.play()
                    }
                }
            }
            do {
                try await VideoExporter.write(source: source, tone: tone, to: url, meter: meter)
            } catch {
                self.presentAlert(error.localizedDescription)
            }
        }
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

    /// Picks a folder, then writes one new file per still. The open photo uses its flattened TIFF when that file is present.
    private func writeFolderExport(_ files: [URL], request: ExportRequest) {
        guard !folderRotateBusy, !files.isEmpty else { return }
        if flattenBusy {
            folderRotateNote = "Flatten is still writing this photograph."
            return
        }
        if exportBusy {
            folderRotateNote = "An export is already running."
            return
        }
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
        guard !files.isEmpty else { return }
        if flattenBusy {
            folderRotateNote = "Flatten is still writing this photograph."
            return
        }
        if exportBusy || folderRotateBusy {
            folderRotateNote = "An export is already running."
            return
        }
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
        let openTIFF = openState == nil ? nil : readableFlattenedTIFF()
        let openBase = openState == nil ? nil : baseCI
        let openToken = sourceFileURL?.path ?? ""
        let sidecars = FlattenSidecarIndex()
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
                if key == openKey, let openState, let openTIFF {
                    wrote = await Task.detached {
                        FolderExportWorker.write(
                            flattened: openTIFF,
                            file: url,
                            folder: folder,
                            request: request,
                            state: openState
                        )
                    }.value
                } else if key == openKey, let openState, let openBase {
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
                        FolderExportWorker.write(
                            file: url,
                            folder: folder,
                            request: request,
                            session: session,
                            sidecars: sidecars
                        )
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
        stopVideoPlayback()
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

    private func openProxy(at url: URL, generation: Int, catalog: CatalogEditTarget?) {
        let name = url.lastPathComponent
        Task {
            let outcome: Result<(ProxyImage, FlattenedMaster.Identity?), ProxyOpenError> = await Task.detached {
                do {
                    let proxy = try ProxyRenderer.open(url: url)
                    let flat = FlattenedMaster.find(file: url, hint: catalog)
                    return .success((proxy, flat))
                } catch let error as ProxyOpenError {
                    return .failure(error)
                } catch {
                    return .failure(.cannotRead(url.lastPathComponent))
                }
            }.value
            guard generation == self.openGeneration else { return }
            switch outcome {
            case .success(let (proxy, flat)):
                self.adopt(
                    proxy: proxy,
                    name: name,
                    url: url,
                    banner: nil,
                    support: .full,
                    editBase: nil,
                    flat: flat
                )
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
        editBase: EditBase?,
        flat: FlattenedMaster.Identity? = nil
    ) {
        cancelTouchupQueue()
        touchupPictures.removeAll()
        Touchup.resetRasterCache()
        if let flat {
            catalogAssetUID = flat.uid
            catalogRelPath = flat.relativePath
        }
        let openedProxy: ProxyImage
        if let flat, let data = FlattenedMaster.workingJPEG(for: flat), let image = image(fromPreviewJPEG: data) {
            openedProxy = ProxyImage(
                image: image,
                entryPoint: .imageIOThumbnail,
                appliedScaleFactor: nil,
                nativeLongEdge: nil
            )
        } else {
            openedProxy = proxy
        }
        self.proxy = openedProxy
        self.baseCI = CIImage(cgImage: openedProxy.image)
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
        let loadedCatalogLog = log.commands.isEmpty && applyOnDiskCatalogLog()
        if hasFlattenedSidecar {
            adoptFlattenedBaseIfPresent()
        } else if !loadedCatalogLog, let savedCanvas {
            preview = savedCanvas
            self.savedCanvas = nil
            presentOpenedRepairs(quickLook: savedCanvas)
        } else if !loadedCatalogLog {
            preview = nil
            spectrumBins = []
            self.refreshPreview()
        } else {
            self.savedCanvas = nil
            presentOpenedRepairs(quickLook: preview)
        }
        self.fitIfPossible()
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

    /// Geometry, tone, and later repairs of the open photo.
    /// A flattened TIFF is the source when that file is present, so the export keeps its size and depth.
    private func writeExport(_ request: ExportRequest, to url: URL) {
        let tiff = readableFlattenedTIFF()
        guard baseCI != nil || tiff != nil else { return }
        if let sourceFileURL, sameExportFile(url, sourceFileURL) {
            presentAlert("Export leaves the original file unchanged.")
            return
        }
        if let tiff, sameExportFile(url, tiff) {
            presentAlert("Export leaves the flattened TIFF unchanged.")
            return
        }
        if flattenBusy {
            presentAlert("Flatten is still writing this photograph.")
            return
        }
        if exportBusy || folderRotateBusy {
            presentAlert("An export is already running.")
            return
        }
        var state = log.state
        state.tone = draftTone
        state.geometry = draftGeometry
        if let tiff {
            writeFlattenedExport(request, state: state, tiff: tiff, to: url)
            return
        }
        guard let baseCI else { return }
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

    /// Renders the full `.zflat` off the main thread and writes the format chosen in the export panel.
    private func writeFlattenedExport(_ request: ExportRequest, state: EditState, tiff: URL, to url: URL) {
        exportGeneration += 1
        let generation = exportGeneration
        exportBusy = true
        let ownsMeter = touchupMeter == nil && !touchupReplayInFlight
        if ownsMeter {
            touchupMeter = TouchupMeter(title: "Exporting the photograph", done: 0, total: 0, fraction: nil)
        }
        let started = url.startAccessingSecurityScopedResource()
        let tokenPath = sourceFileURL?.path ?? ""
        Task {
            let outcome: Result<Void, Error> = await Task.detached {
                let context = TonePipeline.makeContext()
                do {
                    let image = try FolderExportWorker.tonedFlattened(
                        tiff: tiff,
                        state: state,
                        tokenPath: tokenPath,
                        context: context
                    ) { fraction, done, total in
                        guard total > 0 else { return }
                        let shown: Double? = done > 0 ? min(1, max(0, fraction)) : nil
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard self.exportGeneration == generation, self.exportBusy else { return }
                                guard self.touchupMeterTicket == nil, !self.touchupReplayInFlight else { return }
                                self.touchupMeter = TouchupMeter(
                                    title: "Repairing the photograph",
                                    done: done,
                                    total: total,
                                    fraction: shown
                                )
                            }
                        }
                    }
                    try StillExporter.write(
                        image: image,
                        state: state,
                        request: request,
                        to: url,
                        context: context
                    ) { done, total in
                        let fraction = total > 0 && done > 0 ? Double(done) / Double(total) : nil
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard self.exportGeneration == generation, self.exportBusy else { return }
                                guard self.touchupMeterTicket == nil, !self.touchupReplayInFlight else { return }
                                self.touchupMeter = TouchupMeter(
                                    title: "Exporting the photograph",
                                    done: done,
                                    total: total,
                                    fraction: fraction
                                )
                            }
                        }
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            if case .failure(let error) = outcome {
                try? FileManager.default.removeItem(at: url)
                if started {
                    url.stopAccessingSecurityScopedResource()
                }
                self.finishFlattenedExport(generation: generation, ownsMeter: ownsMeter)
                self.presentAlert(error.localizedDescription)
                return
            }
            if started {
                url.stopAccessingSecurityScopedResource()
            }
            self.finishFlattenedExport(generation: generation, ownsMeter: ownsMeter)
        }
    }

    private func finishFlattenedExport(generation: Int, ownsMeter: Bool) {
        guard exportGeneration == generation else { return }
        exportGeneration += 1
        exportBusy = false
        if ownsMeter, touchupMeterTicket == nil, !touchupReplayInFlight {
            touchupMeter = nil
        }
    }

    private func sameExportFile(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath()
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
        folderPage = 0
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
                self.folderSelectionOrder = []
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
            self.folderSelectionOrder = self.folderSelectionOrder.filter { self.selectedFolderKeys.contains($0) }
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
    /// The page on screen goes first. The rest of the folder follows.
    private func preparePreviews(for entries: [FolderEntry], generation: Int) {
        let folder = entries.filter { !$0.isDirectory }.map(\.url)
        Task {
            var done = Set<String>()
            while generation == self.folderGeneration {
                let visible = self.pagedFolderEntries.map(\.url)
                guard let imageURL = FolderPreviewQueue.nextURL(visible: visible, folder: folder, done: done) else { return }
                let key = FolderEntry.cacheKey(for: imageURL)
                done.insert(key)
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
            let step: (right: Int, down: Int)?
            switch event.keyCode {
            case 123: step = (-1, 0)
            case 124: step = (1, 0)
            case 125: step = (0, 1)
            case 126: step = (0, -1)
            default: step = nil
            }
            guard let step else { return event }
            let blocked: NSEvent.ModifierFlags = [.command, .option, .control]
            if !event.modifierFlags.intersection(blocked).isEmpty { return event }
            var forwarding = false
            MainActor.assumeIsolated {
                forwarding = self?.forwardingArrow ?? false
            }
            if forwarding { return event }
            let shift = event.modifierFlags.contains(.shift)
            if let responder = NSApp.keyWindow?.firstResponder {
                if responder is NSSlider || responder is NSTextView {
                    if shift { return event }
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
            }
            var nudging = false
            MainActor.assumeIsolated {
                nudging = self?.nudgeMergePreview(right: step.right, down: step.down) ?? false
            }
            if nudging { return nil }
            if shift || step.down != 0 { return event }
            var handled = false
            MainActor.assumeIsolated {
                handled = self?.imageStep?(step.right) ?? false
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
        if showsVideo {
            if log.canUndo { return true }
            return draftTone != log.state.tone || draftTone != .identity
        }
        guard proxy != nil, !showsPDFPicker else { return false }
        if log.canUndo { return true }
        if draftTone != log.state.tone || draftGeometry != log.state.geometry { return true }
        return cropSelection != nil
    }

    /// A library still can be flattened. The edit file's folder on the share has to be visible.
    var canFlattenPhoto: Bool {
        guard !flattenBusy, !exportBusy, !showsVideo, !showsPDFPicker, proxy != nil,
              catalogAssetUID?.isEmpty == false, libraryEditsFolder() != nil else { return false }
        return true
    }

    /// Asks, then writes the full-size `.zflat` beside the library `.zimg`.
    func confirmFlatten() {
        guard canFlattenPhoto else { return }
        let alert = NSAlert()
        alert.messageText = "Flatten this photograph?"
        alert.informativeText = """
        Flatten writes a full-size LZW TIFF beside this photo's edits on the library. The file name ends in .zflat. An 8-bit original is saved as 8-bit. An original with more than 8 bits per channel is saved as 16-bit.

        That TIFF becomes the starting point for later edits. Tone, spots, and the other edits are saved into the TIFF, and the edit list returns to the start. The original photo stays unchanged. The preview and the .zimg stay. Flatten again overwrites the TIFF.

        A large photo is rendered at full size once, with a progress bar.

        Revert is available after a flatten. It removes that TIFF and every edit, and the photograph returns to the original file.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Revert")
        if alert.buttons.count > 2 {
            alert.buttons[2].isEnabled = hasFlattenedSidecar
        }
        NSCursor.arrow.set()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            startFlatten()
        case .alertThirdButtonReturn:
            confirmRevertFlatten()
        default:
            break
        }
    }

    /// Warns, then removes the flattened TIFF and every edit.
    private func confirmRevertFlatten() {
        guard hasFlattenedSidecar else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revert this photograph?"
        alert.informativeText = """
        Revert removes the flattened TIFF and every edit, including edits made after the flatten. The photograph returns to the original file with an empty edit list. The original file stays unchanged.
        """
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Yes")
        if alert.buttons.count > 1 {
            alert.buttons[1].keyEquivalent = ""
        }
        NSCursor.arrow.set()
        guard alert.runModal() == .alertSecondButtonReturn else {
            confirmFlatten()
            return
        }
        startRevert()
    }

    /// Loads the original file, then drops the flattened sidecars.
    private func startRevert() {
        guard canFlattenPhoto, hasFlattenedSidecar,
              let source = sourceFileURL,
              let uid = catalogAssetUID,
              let folder = libraryEditsFolder(),
              let digest = sourceDigest,
              let count = sourceByteCount else { return }
        cancelTouchupQueue()
        touchupReplayAgain = false
        let sourceKey = sourceKey(source)
        let uti = sourceUTI ?? "public.data"
        let relative = catalogRelPath ?? ""
        let catalog = CatalogEditTarget(uid: uid, relativePath: relative)
        let zflat = folder.appendingPathComponent(uid + ".zflat")
        flattenGeneration += 1
        let generation = flattenGeneration
        let openGen = openGeneration
        flattenBusy = true
        touchupMeter = TouchupMeter(title: "Reverting the photograph", done: 0, total: 0, fraction: nil)
        Task {
            let outcome: Result<(ProxyImage, Data), Error> = await Task.detached {
                do {
                    let opened = try ProxyRenderer.open(url: source)
                    guard let previewJPEG = ZImgRaw.jpegPreview(from: opened.image) else {
                        throw FlattenError.cannotWrite(source.lastPathComponent)
                    }
                    try FlattenedMaster.revertToOriginal(
                        uid: uid,
                        editsFolder: folder,
                        previewJPEG: previewJPEG,
                        blake3: digest,
                        byteSize: count,
                        uti: uti,
                        relativePath: relative
                    )
                    return .success((opened, previewJPEG))
                } catch {
                    return .failure(error)
                }
            }.value
            guard self.flattenGeneration == generation else { return }
            self.flattenBusy = false
            self.touchupMeter = nil
            switch outcome {
            case .failure(let error):
                self.presentAlert(error.localizedDescription)
            case .success(let (opened, previewJPEG)):
                self.finishRevert(
                    opened,
                    previewJPEG: previewJPEG,
                    sourceKey: sourceKey,
                    catalog: catalog,
                    digest: digest,
                    count: count,
                    uti: uti,
                    openGeneration: openGen,
                    zflat: zflat
                )
            }
        }
    }

    /// The open photograph shows the original file. The edit list is empty, with nothing waiting on Redo.
    private func finishRevert(
        _ opened: ProxyImage,
        previewJPEG: Data,
        sourceKey: String,
        catalog: CatalogEditTarget,
        digest: String,
        count: Int,
        uti: String,
        openGeneration: Int,
        zflat: URL
    ) {
        editSaveToken[sourceKey] = (editSaveToken[sourceKey] ?? 0) + 1
        let stillOpen = self.openGeneration == openGeneration && !FileManager.default.isReadableFile(atPath: zflat.path)
        var shown: CGImage?
        if stillOpen {
            cancelTouchupQueue()
            touchupReplayAgain = false
            log = HistoryLog()
            cropSelection = nil
            touchupPictures.removeAll()
            Touchup.resetRasterCache()
            clearTouchupHead()
            syncDraftsFromLog()
            baseCI = CIImage(cgImage: opened.image)
            proxy = opened
            refreshPreview()
            shown = preview
            previewBanner = "Reverted."
            publishOpenPreview()
        }
        editsBySource[sourceKey] = PhotoEdits(
            log: HistoryLog(),
            documentURL: nil,
            documentBookmark: nil,
            display: shown
        )
        dropLocalEditCopy(digest: digest)
        Task {
            await self.putCatalogEdits(
                catalog,
                log: HistoryLog(),
                previewJPEG: previewJPEG,
                digest: digest,
                count: count,
                uti: uti
            )
        }
    }

    private func startFlatten() {
        guard canFlattenPhoto,
              let source = sourceFileURL,
              let uid = catalogAssetUID,
              let folder = libraryEditsFolder(),
              let digest = sourceDigest,
              let count = sourceByteCount else { return }
        commitOpenDrafts()
        cancelTouchupQueue()
        let state = log.state
        let zflat = folder.appendingPathComponent(uid + ".zflat")
        let zjpg = folder.appendingPathComponent(uid + ".zjpg")
        let zimg = folder.appendingPathComponent(uid + ".zimg")
        let pixels = FileManager.default.isReadableFile(atPath: zflat.path) ? zflat : source
        let uti = sourceUTI ?? "public.data"
        let relative = catalogRelPath ?? ""
        let catalog = CatalogEditTarget(uid: uid, relativePath: relative)
        flattenGeneration += 1
        let generation = flattenGeneration
        let openGen = openGeneration
        flattenBusy = true
        touchupMeter = TouchupMeter(title: "Flattening the photograph", done: 0, total: 0, fraction: nil)
        Task {
            let outcome: Result<FlattenWriter.Product, Error> = await Task.detached {
                do {
                    let product = try FlattenWriter.produce(
                        pixels: pixels,
                        depthFrom: source,
                        state: state,
                        tiff: zflat
                    ) { title, done, total, fraction in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard self.flattenGeneration == generation, self.flattenBusy else { return }
                                self.touchupMeter = TouchupMeter(
                                    title: title,
                                    done: done,
                                    total: total,
                                    fraction: fraction
                                )
                            }
                        }
                    }
                    let document = try SaveEdits.catalogBytes(
                        log: HistoryLog(),
                        blake3: digest,
                        byteSize: count,
                        uti: uti,
                        assetUID: uid,
                        relativePathHint: relative,
                        previewJPEG: product.previewJPEG
                    )
                    try product.workingJPEG.write(to: zjpg, options: .atomic)
                    try document.write(to: zimg, options: .atomic)
                    return .success(product)
                } catch {
                    return .failure(error)
                }
            }.value
            guard self.flattenGeneration == generation else { return }
            self.flattenBusy = false
            self.touchupMeter = nil
            switch outcome {
            case .failure(let error):
                self.presentAlert(error.localizedDescription)
            case .success(let product):
                guard self.openGeneration == openGen else { return }
                self.finishFlatten(product, catalog: catalog, digest: digest, count: count, uti: uti)
            }
        }
    }

    /// The edit list is cleared because those changes are now in the TIFF. Later edits start from the working JPEG.
    private func finishFlatten(
        _ product: FlattenWriter.Product,
        catalog: CatalogEditTarget,
        digest: String,
        count: Int,
        uti: String
    ) {
        cancelTouchupQueue()
        log = HistoryLog()
        cropSelection = nil
        touchupPictures.removeAll()
        Touchup.resetRasterCache()
        clearTouchupHead()
        syncDraftsFromLog()
        if let image = image(fromPreviewJPEG: product.workingJPEG) {
            baseCI = CIImage(cgImage: image)
            proxy = ProxyImage(
                image: image,
                entryPoint: .imageIOThumbnail,
                appliedScaleFactor: nil,
                nativeLongEdge: nil
            )
            preview = image
        }
        refreshSpectrumHistogram()
        previewBanner = "Flattened."
        publishOpenPreview()
        Task {
            await self.putCatalogEdits(
                catalog,
                log: HistoryLog(),
                previewJPEG: product.previewJPEG,
                digest: digest,
                count: count,
                uti: uti
            )
            self.dropLocalEditCopy(digest: digest)
        }
    }

    /// `.zimage/edits` on the same library volume as the open photo.
    private func libraryEditsFolder() -> URL? {
        guard let source = sourceFileURL, let rel = catalogRelPath else { return nil }
        return FlattenedMaster.editsFolder(file: source, relativePath: rel)
    }

    /// When a flatten file exists, later edits start from its working JPEG.
    private func adoptFlattenedBaseIfPresent() {
        guard let uid = catalogAssetUID, let folder = libraryEditsFolder() else { return }
        let zflat = folder.appendingPathComponent(uid + ".zflat")
        let zjpg = folder.appendingPathComponent(uid + ".zjpg")
        guard FileManager.default.isReadableFile(atPath: zflat.path),
              let data = try? Data(contentsOf: zjpg),
              let image = image(fromPreviewJPEG: data) else { return }
        baseCI = CIImage(cgImage: image)
        proxy = ProxyImage(
            image: image,
            entryPoint: .imageIOThumbnail,
            appliedScaleFactor: nil,
            nativeLongEdge: nil
        )
        if log.commands.isEmpty {
            preview = image
            refreshSpectrumHistogram()
            publishOpenPreview()
        } else {
            refreshPreview()
        }
    }

    /// The library `.zflat` for the open photo. Later edits and the folder cell use that picture.
    private var hasFlattenedSidecar: Bool {
        readableFlattenedTIFF() != nil
    }

    /// Full-size flattened TIFF for the open photo. Opening the photo still uses the working JPEG.
    private func readableFlattenedTIFF() -> URL? {
        guard let uid = catalogAssetUID, !uid.isEmpty, let folder = libraryEditsFolder() else { return nil }
        return FlattenedMaster.tiffURL(uid: uid, editsFolder: folder)
    }

    /// Returns the open photograph to the start. Each edit stays on the redo stack.
    func resetPhoto() {
        guard showsVideo || (proxy != nil && !showsPDFPicker) else { return }
        cancelTouchupQueue()
        commitOpenDrafts()
        guard log.canUndo || cropSelection != nil else { return }
        log.resetToBeginning()
        cropSelection = nil
        syncDraftsFromLog()
        refreshAfterHistoryChange()
    }

    func undo() {
        cancelProvisionalEdits()
        let snapshot = touchupSnapshot()
        cancelTouchupQueue()
        log.undo()
        cropSelection = nil
        syncDraftsFromLog()
        applyHistoryMove(snapshot)
    }

    func redo() {
        cancelProvisionalEdits()
        let snapshot = touchupSnapshot()
        cancelTouchupQueue()
        log.redo()
        cropSelection = nil
        syncDraftsFromLog()
        applyHistoryMove(snapshot)
    }

    func selectCommand(at index: Int) {
        cancelProvisionalEdits()
        let snapshot = touchupSnapshot()
        cancelTouchupQueue()
        log.selectCommand(at: index)
        cropSelection = nil
        syncDraftsFromLog()
        applyHistoryMove(snapshot)
    }

    /// The repaired picture before this Undo, Redo, or history click.
    private struct TouchupSnapshot {
        var token: Int
        var operations: [InpaintOp]
        var image: CIImage?
    }

    private func touchupSnapshot() -> TouchupSnapshot {
        TouchupSnapshot(
            token: touchupImageToken(),
            operations: touchupPreviewOperations(),
            image: touchupHead?.image
        )
    }

    /// Pastes the small before or after picture for the repairs that moved. A miss rebuilds from the masks.
    private func applyHistoryMove(_ snapshot: TouchupSnapshot) {
        if !showsVideo, !showsPDFPicker, let image = restoredTouchupImage(from: snapshot) {
            let token = touchupImageToken()
            storeTouchupHead(token: token, operations: touchupPreviewOperations(), image: image)
            paintPreview(from: image)
            refreshSpectrumHistogram(using: image)
            publishOpenPreview()
            return
        }
        refreshAfterHistoryChange()
    }

    private func restoredTouchupImage(from snapshot: TouchupSnapshot) -> CIImage? {
        let token = touchupImageToken()
        guard token == snapshot.token else { return nil }
        let current = touchupPreviewOperations()
        if sameRepairList(current, snapshot.operations), let image = snapshot.image {
            return image
        }
        if current.count < snapshot.operations.count,
           sameRepairList(current, Array(snapshot.operations.prefix(current.count))),
           let image = snapshot.image,
           let restored = Touchup.stampBefore(
            Array(snapshot.operations.dropFirst(current.count)),
            onto: image,
            frameToken: token
           ) {
            return restored
        }
        if snapshot.operations.count < current.count,
           sameRepairList(snapshot.operations, Array(current.prefix(snapshot.operations.count))),
           let image = snapshot.image,
           let restored = Touchup.stampAfter(
            Array(current.dropFirst(snapshot.operations.count)),
            onto: image,
            frameToken: token
           ) {
            return restored
        }
        guard let shaped = geometryImage() else { return nil }
        return Touchup.stampAfter(current, onto: shaped, frameToken: token)
    }

    /// Puts a remembered repair picture back on screen. A full rebuild runs only when that picture is gone.
    private func refreshAfterHistoryChange() {
        if restoreRememberedTouchup() {
            publishOpenPreview()
        } else {
            refreshPreview()
            publishOpenPreview()
        }
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
        guard proxy != nil else { return }
        replaceGeometry("Rotate clockwise") { geometry in
            geometry.quarterTurns = GeometryPipeline.wrap(geometry.quarterTurns + 1)
        }
    }

    func rotateCounterclockwise() {
        guard proxy != nil else { return }
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
        var next = draftGeometry
        update(&next)
        guard next != draftGeometry else { return }
        draftGeometry = next
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
        // The preview is already the cropped picture, in its own pixels.
        horizonClicks.append(NormPoint(
            x: Double(pixel.x / CGFloat(image.width)),
            y: Double(pixel.y / CGFloat(image.height))
        ))
        guard horizonClicks.count >= 2 else { return }
        let start = horizonClicks[0]
        let end = horizonClicks[1]
        horizonClicks.removeAll()
        endGeometryDrag()
        draftGeometry = GeometryPipeline.applyingHorizon(
            from: start,
            to: end,
            pixelWidth: Double(image.width),
            pixelHeight: Double(image.height),
            current: draftGeometry
        )
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
        enqueueTouchup(
            banner: "Removing dust…",
            empty: "No dust stood out from the surrounding photo. Spot covers a speck with the circle.",
            work: .dust
        )
    }

    func removeScratches() {
        enqueueTouchup(
            banner: "Removing scratches…",
            empty: "No scratch stood out from the surrounding photo. Drag the circle along one.",
            work: .scratches
        )
    }

    func dustSpotClick(at viewPoint: CGPoint, in viewSize: CGSize) {
        guard let bitmap = touchupBitmap(at: viewPoint, in: viewSize) else { return }
        let radius = touchupRasterRadius()
        enqueueTouchup(
            banner: "Removing the spot…",
            empty: "No speck stood out in that circle. Cover the spot and click it.",
            work: .spot(bitmap, radius)
        )
    }

    func redEyeClick(at viewPoint: CGPoint, in viewSize: CGSize) {
        guard let bitmap = touchupBitmap(at: viewPoint, in: viewSize) else { return }
        enqueueTouchup(
            banner: "Correcting red eye…",
            empty: "No red eye under that click. Click the red of the pupil.",
            work: .redEye(bitmap)
        )
    }

    /// `viewPoints` are the drag, in canvas coordinates. A short drag does not add a history step.
    /// Returns false when the stroke is too short to be a scratch.
    @discardableResult
    func scratchStroke(_ viewPoints: [CGPoint], in viewSize: CGSize) -> Bool {
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
        guard length >= 2 else { return false }
        let radius = touchupRasterRadius()
        enqueueTouchup(
            banner: "Removing the scratch…",
            empty: "No scratch stood out under that stroke.",
            work: .scratch(bitmaps, radius)
        )
        return true
    }

    func touchupRasterRadius() -> Int {
        guard let preview else {
            return max(1, Int((touchupBrushDiameter / 2).rounded()))
        }
        let scale = touchupBitmapScale(for: preview)
        return max(1, Int((touchupBrushDiameter / 2 * Double(scale.x)).rounded()))
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
        if abs(touchupStrength(modelID: modelID) - clamped) < 0.000_000_1 {
            return
        }
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
        guard let preview else { return nil }
        let pixel = imagePixel(
            viewPoint,
            viewSize: viewSize,
            imageSize: CGSize(width: preview.width, height: preview.height)
        )
        let scale = touchupBitmapScale(for: preview)
        return CGPoint(x: pixel.x * scale.x, y: pixel.y * scale.y)
    }

    /// The scale from the last picture that was drawn. While a repair is rendering, this does not touch that image.
    private func touchupBitmapScale(for preview: CGImage) -> (x: CGFloat, y: CGFloat) {
        if touchupBitmapScaleReady {
            return (touchupBitmapScaleX, touchupBitmapScaleY)
        }
        if touchupBusy {
            return (1, 1)
        }
        guard let shaped = geometryImage() else { return (1, 1) }
        rememberTouchupBitmapScale(
            rasterWidth: shaped.extent.width,
            rasterHeight: shaped.extent.height,
            preview: preview
        )
        return (touchupBitmapScaleX, touchupBitmapScaleY)
    }

    private func rememberTouchupBitmapScale(rasterWidth: CGFloat, rasterHeight: CGFloat, preview: CGImage) {
        guard rasterWidth > 0, rasterHeight > 0 else { return }
        touchupBitmapScaleX = rasterWidth / CGFloat(max(preview.width, 1))
        touchupBitmapScaleY = rasterHeight / CGFloat(max(preview.height, 1))
        touchupBitmapScaleReady = true
    }

    /// The words under the photograph while spots are still in the list.
    var touchupSpotsLeftLabel: String? {
        guard touchupSpotsRemaining > 0 else { return nil }
        return touchupSpotsRemaining == 1 ? "1 spot left" : "\(touchupSpotsRemaining) spots left"
    }

    /// Adds one repair. A click during a running repair waits in the list, up to `TouchupQueue.cap`.
    private func enqueueTouchup(banner: String, empty: String, work: TouchupWork) {
        guard proxy != nil else { return }
        let idle = touchupQueue.running == nil
        let job = QueuedTouchup(banner: banner, empty: empty, work: work)
        guard touchupQueue.add(job) else {
            noteTouchupListFull()
            return
        }
        touchupSpotsRemaining = touchupQueue.spotsRemaining
        if idle {
            touchupBannerRestore = previewBanner
            touchupBannerCaptured = true
            beginRunningTouchup()
        } else if let base = touchupBannerBase {
            previewBanner = touchupStatusBanner(base)
        }
    }

    private func noteTouchupListFull() {
        let base = touchupBannerBase ?? "Removing the spot…"
        previewBanner = "\(touchupStatusBanner(base)) The list holds \(TouchupQueue.cap)."
    }

    private func touchupStatusBanner(_ base: String) -> String {
        guard let label = touchupSpotsLeftLabel else { return base }
        return "\(base) \(label)"
    }

    /// Runs the job already stored in `touchupQueue.running`. Spot clicks already waiting fill together.
    private func beginRunningTouchup() {
        guard proxy != nil else {
            stopTouchupQueue(restoreBanner: true)
            return
        }
        guard !touchupBusy, let job = touchupQueue.running else { return }
        commitOpenDrafts()
        let imageToken = touchupImageToken()
        let operations = touchupPreviewOperations()
        let base: CIImage
        let prior: [InpaintOp]
        if touchupHeadShows(operations, token: imageToken), let head = touchupHead {
            base = head.image
            prior = []
        } else if let shaped = geometryImage() {
            base = shaped
            prior = operations
        } else {
            stopTouchupQueue(restoreBanner: true)
            return
        }
        let spotBatch = leadingSpotBatch(startingAt: job)
        let chain = Touchup.chain(imageToken: imageToken, operations: operations)
        let baseChain = chain
        rememberShownTouchup(allowWithoutImage: true)
        let tone = draftTone
        let displaySpaceName = (NSScreen.main?.colorSpace?.cgColorSpace?.name as String?)
            ?? (CGColorSpace.sRGB as String)
        touchupGeneration += 1
        let generation = touchupGeneration
        touchupBusyGeneration = generation
        touchupBusy = true
        touchupSpotsRemaining = touchupQueue.spotsRemaining
        touchupBannerBase = job.banner
        previewBanner = touchupStatusBanner(job.banner)
        let work = job.work
        let empty = job.empty
        Task { @MainActor in
            if spotBatch.count >= 2 {
                let rendered = await Touchup.finishSpotsOffMain(
                    image: base,
                    spots: spotBatch,
                    tone: tone,
                    displaySpaceName: displaySpaceName,
                    priorOperations: prior,
                    priorToken: imageToken,
                    baseChain: baseChain,
                    frameToken: imageToken
                )
                guard generation == self.touchupGeneration else { return }
                if let repaired = rendered.repaired, !rendered.operations.isEmpty {
                    for operation in rendered.operations {
                        self.log.commit(.addInpaint(operation))
                    }
                    self.storeTouchupHead(token: imageToken, operations: self.touchupPreviewOperations(), image: repaired)
                    self.showTouchupPicture(
                        picture: rendered.preview,
                        spectrum: rendered.spectrum,
                        width: rendered.width,
                        height: rendered.height,
                        tone: tone,
                        folderJPEG: rendered.folderJPEG
                    )
                }
                self.settleTouchupQueue(generation: generation, failed: rendered.operations.isEmpty, empty: empty)
            } else {
                let rendered = await Touchup.finishOffMain(
                    image: base,
                    work: work,
                    tone: tone,
                    displaySpaceName: displaySpaceName,
                    priorOperations: prior,
                    priorToken: imageToken,
                    baseChain: baseChain,
                    frameToken: imageToken
                )
                guard generation == self.touchupGeneration else { return }
                if let built = rendered.built, let repaired = rendered.repaired {
                    Touchup.store(
                        chain: chain,
                        width: rendered.width,
                        height: rendered.height,
                        maskPNG: built.operation.maskPNG,
                        modelID: built.operation.modelID,
                        image: repaired
                    )
                    self.log.commit(.addInpaint(built.operation))
                    self.storeTouchupHead(token: imageToken, operations: self.touchupPreviewOperations(), image: repaired)
                    self.showTouchupPicture(
                        picture: rendered.preview,
                        spectrum: rendered.spectrum,
                        width: rendered.width,
                        height: rendered.height,
                        tone: tone,
                        folderJPEG: rendered.folderJPEG
                    )
                }
                self.settleTouchupQueue(generation: generation, failed: rendered.built == nil, empty: empty)
            }
        }
    }

    /// Spot clicks lined up behind the one already running. A scratch or a Dust pass stays for the next turn.
    private func leadingSpotBatch(startingAt job: QueuedTouchup) -> [(CGPoint, Int)] {
        guard job.work.isSpot else { return [] }
        let taken = touchupQueue.takeLeadingSpots()
        guard taken.count >= 2 else { return [] }
        return taken.compactMap { item in
            if case .spot(let point, let radius) = item.work { return (point, radius) }
            return nil
        }
    }

    private func showTouchupPicture(
        picture: CGImage?,
        spectrum: [Int],
        width: Int,
        height: Int,
        tone: ToneState,
        folderJPEG: Data?
    ) {
        if let picture, draftTone == tone {
            preview = picture
            rememberTouchupBitmapScale(
                rasterWidth: CGFloat(width),
                rasterHeight: CGFloat(height),
                preview: picture
            )
            spectrumBins = spectrum
            proxyRenderCount += 1
            rememberShownTouchup()
        } else {
            refreshPreview()
        }
        publishOpenPreview(folderJPEG: folderJPEG)
    }

    /// Lets the picture land, and lets a click already in the list join, before the next repair starts.
    private func settleTouchupQueue(generation: Int, failed: Bool, empty: String) {
        guard generation == touchupGeneration else { return }
        let moreWaiting = !touchupQueue.waiting.isEmpty
        if failed, !moreWaiting {
            presentAlert(empty)
        }
        guard generation == touchupGeneration else { return }
        if moreWaiting {
            Task { @MainActor in
                await Task.yield()
                guard generation == self.touchupGeneration else { return }
                self.advanceTouchupQueue()
            }
        } else {
            advanceTouchupQueue()
        }
    }

    /// Starts the next repair, or clears the busy flag when the list is empty.
    private func advanceTouchupQueue() {
        guard touchupQueue.finishRunning() != nil else {
            stopTouchupQueue(restoreBanner: true)
            return
        }
        touchupBusy = false
        touchupSpotsRemaining = touchupQueue.spotsRemaining
        beginRunningTouchup()
    }

    /// Saves the picture now on screen for this repair list.
    /// A click saves it before the repair starts, including when the raster is not ready yet.
    private func rememberShownTouchup(allowWithoutImage: Bool = false) {
        guard dustStrengthOverride == nil, scratchStrengthOverride == nil else { return }
        guard let preview else { return }
        let token = touchupImageToken()
        let operations = touchupPreviewOperations()
        guard operations.contains(where: { !$0.maskPNG.isEmpty }) else { return }
        let image: CIImage?
        if let head = touchupHead, head.operations == operations, (head.token == token || touchupFrameMatches()) {
            image = head.image
        } else if allowWithoutImage {
            image = nil
        } else {
            return
        }
        touchupPictures.remember(TouchupShown(
            token: token,
            operations: operations,
            image: image,
            tone: draftTone,
            preview: preview,
            spectrum: spectrumBins
        ))
    }

    /// Shows the picture from before the undone spots. Returns false when that picture was not kept.
    private func restoreRememberedTouchup() -> Bool {
        let token = touchupImageToken()
        let operations = touchupPreviewOperations()
        guard let frame = touchupPictures.frame(token: token, operations: operations) else { return false }
        if let image = frame.image {
            storeTouchupHead(token: token, operations: operations, image: image)
        } else {
            clearTouchupHead()
        }
        if frame.tone == draftTone || frame.image == nil {
            preview = frame.preview
            spectrumBins = frame.spectrum
            rememberTouchupBitmapScale(
                rasterWidth: frame.image?.extent.width ?? CGFloat(frame.preview.width),
                rasterHeight: frame.image?.extent.height ?? CGFloat(frame.preview.height),
                preview: frame.preview
            )
            proxyRenderCount += 1
            return true
        }
        guard let image = frame.image else { return false }
        paintPreview(from: image)
        refreshSpectrumHistogram(using: image)
        return true
    }

    /// Drops a list that belongs to the photograph being left, undone, or reset.
    /// Pictures already shown stay, so Undo can put the last speck back.
    private func cancelTouchupQueue() {
        touchupGeneration += 1
        touchupBusyGeneration = touchupGeneration
        Touchup.abandonQueuedWork()
        stopTouchupQueue(restoreBanner: true)
        clearTouchupHead()
        touchupMeter = nil
        touchupMeterTicket = nil
    }

    private func stopTouchupQueue(restoreBanner: Bool) {
        let base = touchupBannerBase
        let restore = touchupBannerRestore
        touchupQueue.removeAll()
        touchupBusy = false
        touchupSpotsRemaining = 0
        touchupBannerBase = nil
        let captured = touchupBannerCaptured
        touchupBannerCaptured = false
        touchupBannerRestore = nil
        guard restoreBanner, captured, let base, let banner = previewBanner, banner.hasPrefix(base) else { return }
        previewBanner = restore
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
        cancelTouchupQueue()
        cancelProvisionalEdits()
        log = HistoryLog()
        cropSelection = nil
        touchupBitmapScaleReady = false
        touchupPictures.removeAll()
        Touchup.resetRasterCache()
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
        guard (proxy != nil || showsVideo), spectrumDragActive else { return }
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
        guard proxy != nil || showsVideo else { return }
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
        guard let shaped = videoPoster ?? stage3Image() else { return }
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
        if showsVideo, let videoKey {
            videoGrades[videoKey] = draftTone
        }
        publishOpenPreview()
    }

    private func commitGeometryDraft() {
        guard draftGeometry != log.state.geometry else { return }
        log.commit(.setGeometry(draftGeometry, label: pendingGeometryLabel))
        refreshPreview()
        publishOpenPreview()
    }

    /// Path, geometry, and crop for the picture a repair list was painted on.
    private struct TouchupFrame: Equatable {
        var path: String
        var geometry: GeometryState
        var crop: NormRect?
    }

    private func currentTouchupFrame() -> TouchupFrame {
        TouchupFrame(path: sourceFileURL?.path ?? "", geometry: draftGeometry, crop: log.state.crop)
    }

    private func storeTouchupHead(token: Int, operations: [InpaintOp], image: CIImage, frame: TouchupFrame? = nil) {
        touchupHead = (token, operations, image)
        touchupHeadFrame = frame ?? currentTouchupFrame()
    }

    private func clearTouchupHead() {
        touchupHead = nil
        touchupHeadFrame = nil
    }

    /// The stored frame still describes the pixels on screen. Sub-threshold geometry
    /// noise does not, because those values never reach a filter.
    private func touchupFrameMatches() -> Bool {
        guard let painted = touchupHeadFrame else { return false }
        let frame = currentTouchupFrame()
        guard painted.path == frame.path, painted.crop == frame.crop else { return false }
        return !Self.geometryChangesPixels(painted.geometry, frame.geometry)
    }

    private static func geometryChangesPixels(_ painted: GeometryState, _ current: GeometryState) -> Bool {
        if painted.quarterTurns != current.quarterTurns { return true }
        if abs(painted.straightenDegrees - current.straightenDegrees) > 1e-6 { return true }
        if painted.verticalKeystone != current.verticalKeystone { return true }
        if painted.horizontalKeystone != current.horizontalKeystone { return true }
        if abs(painted.offsetX - current.offsetX) > 1e-9 { return true }
        if abs(painted.offsetY - current.offsetY) > 1e-9 { return true }
        if painted.corners != current.corners { return true }
        if painted.lens != current.lens { return true }
        if painted.sharpness != current.sharpness { return true }
        return false
    }

    /// True when `touchupHead` is already this repair list on the current frame.
    private func touchupHeadShows(_ operations: [InpaintOp], token: Int) -> Bool {
        guard let head = touchupHead, sameRepairList(head.operations, operations) else { return false }
        return head.token == token || touchupFrameMatches()
    }

    private func geometryImage() -> CIImage? {
        guard let baseCI else { return nil }
        let shaped = GeometryPipeline.apply(base: baseCI, geometry: draftGeometry)
        return CropRect.apply(shaped, crop: log.state.crop)
    }

    /// Geometry, then inpaint. Tone is applied after this.
    /// A new repair at the end of the list is applied on the picture already built for the repairs before it.
    private func stage3Image() -> CIImage? {
        let token = touchupImageToken()
        let operations = touchupPreviewOperations()
        if touchupHeadShows(operations, token: token), let head = touchupHead {
            return head.image
        }
        guard let shaped = geometryImage() else { return nil }
        if let head = touchupHead, head.token == token || touchupFrameMatches() {
            if operations.count > head.operations.count,
               sameRepairList(Array(operations.prefix(head.operations.count)), head.operations) {
                let suffix = Array(operations.dropFirst(head.operations.count))
                if let stamped = Touchup.stampAfter(suffix, onto: head.image, frameToken: token) {
                    storeTouchupHead(token: token, operations: operations, image: stamped)
                    return stamped
                }
                var chain = token
                for operation in head.operations where !operation.maskPNG.isEmpty {
                    chain = Touchup.advance(chain, operation)
                }
                let image = InpaintPipeline.applyInteractive(base: head.image, operations: suffix, imageToken: chain)
                storeTouchupHead(token: token, operations: operations, image: image)
                return image
            }
        }
        if let stamped = Touchup.stampAfter(operations, onto: shaped, frameToken: token) {
            storeTouchupHead(token: token, operations: operations, image: stamped)
            return stamped
        }
        let image = InpaintPipeline.applyInteractive(base: shaped, operations: operations, imageToken: token)
        storeTouchupHead(token: token, operations: operations, image: image)
        return image
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

    /// The repairs already painted. Mask bytes are not compared: walking every PNG made a finished replay look new and start over.
    private func sameRepairList(_ left: [InpaintOp], _ right: [InpaintOp]) -> Bool {
        guard left.count == right.count else { return false }
        for index in left.indices {
            if left[index].id != right[index].id
                || left[index].modelID != right[index].modelID
                || left[index].featherPx != right[index].featherPx
                || left[index].strength != right[index].strength {
                return false
            }
        }
        return true
    }

    private func refreshPreview() {
        if showsVideo {
            videoPlayback?.setTone(draftTone)
            refreshSpectrumHistogram()
            return
        }
        if scheduleBackgroundReplay() { return }
        guard let shaped = stage3Image() else {
            preview = nil
            spectrumBins = []
            return
        }
        paintPreview(from: shaped)
        refreshSpectrumHistogram()
    }

    /// Draws `shaped` with the current tone. The caller chooses whether the spectrum uses this frame.
    private func paintPreview(from shaped: CIImage) {
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
        if let preview {
            rememberTouchupBitmapScale(
                rasterWidth: shaped.extent.width,
                rasterHeight: shaped.extent.height,
                preview: preview
            )
        }
        proxyRenderCount += 1
        rememberShownTouchup()
    }

    /// A photograph with saved repairs shows its geometry frame at once. The repairs are filled off the main thread.
    /// Returns true when this call should not run those repairs on the main thread.
    private func scheduleBackgroundReplay() -> Bool {
        let operations = touchupPreviewOperations()
        guard operations.contains(where: { !$0.maskPNG.isEmpty }) else { return false }
        let token = touchupImageToken()
        if touchupHeadShows(operations, token: token) {
            return false
        }
        if let head = touchupHead, head.token == token || touchupFrameMatches(),
           operations.count > head.operations.count,
           sameRepairList(Array(operations.prefix(head.operations.count)), head.operations) {
            return false
        }
        guard let shaped = geometryImage() else { return false }
        if let stamped = Touchup.stampAfter(operations, onto: shaped, frameToken: token) {
            storeTouchupHead(token: token, operations: operations, image: stamped)
            return false
        }
        if preview == nil {
            paintPreview(from: shaped)
            refreshSpectrumHistogram(using: shaped)
        }
        if touchupBusy || touchupReplayInFlight {
            touchupReplayAgain = true
            return true
        }
        touchupReplayInFlight = true
        let generation = openGeneration
        let touchupTicket = touchupGeneration
        let frame = currentTouchupFrame()
        Task { @MainActor in
            guard let replayed = await self.awaitTouchupReplay(
                shaped: shaped,
                operations: operations,
                token: token,
                generation: generation,
                touchupTicket: touchupTicket
            ) else {
                self.touchupReplayInFlight = false
                if self.touchupReplayAgain {
                    self.touchupReplayAgain = false
                    self.refreshPreview()
                }
                return
            }
            self.touchupReplayInFlight = false
            let current = self.touchupPreviewOperations()
            let sameRepairs = self.sameRepairList(current, operations)
            self.touchupReplayAgain = false
            // These repairs are done. A frame token that moved during the pass is not a new list.
            // refreshPreview would start the same repairs and the bar would return to 0.
            if sameRepairs {
                self.storeTouchupHead(token: token, operations: current, image: replayed.image, frame: frame)
                self.paintPreview(from: replayed.image)
                self.refreshSpectrumHistogram(using: replayed.image)
            } else {
                self.refreshPreview()
            }
            self.hideTouchupMeter(replayed.meter)
        }
        return true
    }

    private func touchupRepairCount(_ operations: [InpaintOp]) -> Int {
        operations.reduce(into: 0) { count, operation in
            if !operation.maskPNG.isEmpty { count += 1 }
        }
    }

    /// Several saved repairs get a bar. One repair stays quiet.
    private func showTouchupMeter(operations: [InpaintOp]) -> Int {
        let repairs = operations.filter { !$0.maskPNG.isEmpty }
        touchupMeterSerial += 1
        let serial = touchupMeterSerial
        touchupMeterTicket = serial
        let title: String
        if repairs.allSatisfy({ $0.modelID == InpaintModel.dust }) {
            title = "Removing dust"
        } else if repairs.allSatisfy({ $0.modelID == InpaintModel.scratch }) {
            title = "Repairing scratches"
        } else {
            title = "Repairing the photograph"
        }
        touchupMeter = TouchupMeter(title: title, done: 0, total: max(repairs.count, 1), fraction: nil)
        return serial
    }

    private func noteTouchupMeter(fraction: Double, done: Int, total: Int, meter: Int) {
        guard touchupMeterTicket == meter, var current = touchupMeter else { return }
        guard fraction > 0 else { return }
        if let shown = current.fraction, fraction + 0.0001 < shown { return }
        current.total = max(total, 1)
        current.done = min(current.total, max(current.done, done))
        current.fraction = min(1, fraction)
        touchupMeter = current
    }

    private func hideTouchupMeter(_ meter: Int) {
        guard meter != 0, touchupMeterTicket == meter else { return }
        touchupMeter = nil
        touchupMeterTicket = nil
    }

    private func touchupProgress(meter: Int) -> Touchup.ProgressHandler {
        let sink = TouchupMeterSink { [weak self] fraction, done, total in
            MainActor.assumeIsolated {
                self?.noteTouchupMeter(fraction: fraction, done: done, total: total, meter: meter)
            }
        }
        return { fraction, done, total in
            sink.report(fraction: fraction, done: done, total: total)
        }
    }

    /// Rebuilds saved repairs away from the main thread. Several repairs show the bar before the read starts,
    /// because that read can occupy the main thread and a bar drawn afterward would never move.
    /// Nil when this photograph was replaced before the rebuild finished.
    private func awaitTouchupReplay(
        shaped: CIImage,
        operations: [InpaintOp],
        token: Int,
        generation: Int,
        touchupTicket: Int
    ) async -> (image: CIImage, meter: Int)? {
        let meter: Int
        if touchupRepairCount(operations) >= 2 {
            meter = showTouchupMeter(operations: operations)
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard generation == openGeneration, touchupTicket == touchupGeneration else {
                hideTouchupMeter(meter)
                return nil
            }
        } else {
            meter = 0
        }
        let progress: Touchup.ProgressHandler? = meter == 0 ? nil : touchupProgress(meter: meter)
        guard let image = await Touchup.replay(
            base: shaped,
            operations: operations,
            token: token,
            progress: progress
        ) else {
            hideTouchupMeter(meter)
            return nil
        }
        guard generation == openGeneration, touchupTicket == touchupGeneration else {
            hideTouchupMeter(meter)
            return nil
        }
        return (image, meter)
    }

    /// Luminance of the photograph before the Spectrum handles, so the graph stays put while a handle moves.
    private func refreshSpectrumHistogram(using shapedOverride: CIImage? = nil) {
        guard !spectrumDragActive else { return }
        let shaped = shapedOverride ?? videoPoster ?? stage3Image()
        guard let shaped else {
            spectrumBins = []
            return
        }
        if let preview {
            rememberTouchupBitmapScale(
                rasterWidth: shaped.extent.width,
                rasterHeight: shaped.extent.height,
                preview: preview
            )
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
    /// The Photos folder grid. Review and Duplicates keep the date column as it is.
    private var showsServerMovePanel: Bool {
        !diskMode && !showsImage && !showsEvents && !showsReorg
            && (librarySection ?? "Photos") == "Photos"
    }

    private var showsServerFolderPager: Bool {
        !diskMode && !showsImage && !showsEvents && !showsReorg
            && (librarySection ?? "Photos") == "Photos"
            && browser.showsFolderPager
    }

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
                        VStack(spacing: 0) {
                            if model.showsFolderPager {
                                FolderPagePanel(
                                    title: "\(model.folderPhotoCount.formatted()) photos",
                                    range: model.folderPagerRange,
                                    canGoBack: model.folderPageIndex > 0,
                                    canGoForward: model.folderPageIndex + 1 < model.folderPageCount,
                                    first: { model.showFolderPage(0) },
                                    previous: { model.showFolderPage(model.folderPageIndex - 1) },
                                    next: { model.showFolderPage(model.folderPageIndex + 1) },
                                    last: { model.showFolderPage(model.folderPageCount - 1) }
                                )
                                Rectangle()
                                    .fill(ChromePalette.hairline)
                                    .frame(height: 1)
                            }
                            FolderFileDetails(model: model)
                            Rectangle()
                                .fill(ChromePalette.hairline)
                                .frame(height: 1)
                            DiskMoveFolderPanel(model: model)
                            Rectangle()
                                .fill(ChromePalette.hairline)
                                .frame(height: 1)
                            MergePhotosPanel(
                                firstName: model.mergeFolderPair()?.first,
                                secondName: model.mergeFolderPair()?.second,
                                busy: model.folderRotateBusy || model.exportBusy || model.mergePreviewBusy,
                                previewing: model.showsDiskMergePreview,
                                ready: model.mergePreviewImage != nil,
                                right: model.mergePreviewRight,
                                down: model.mergePreviewDown,
                                preview: { axis in model.beginFolderMergePreview(axis: axis) },
                                retarget: { axis in model.retargetMergePreview(axis: axis) },
                                merge: { model.commitFolderMergePreview() },
                                cancel: { model.cancelMergePreview() }
                            )
                        }
                        .frame(width: 280, alignment: .top)
                        .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        VStack(spacing: 0) {
                            if showsServerFolderPager {
                                FolderPagePanel(
                                    title: browser.folderPagerTitle,
                                    range: browser.folderPagerRange,
                                    canGoBack: browser.folderPageCanGoBack,
                                    canGoForward: browser.folderPageCanGoForward,
                                    first: { Task { await browser.showFirstFolderPage() } },
                                    previous: { Task { await browser.showPreviousFolderPage() } },
                                    next: { Task { await browser.showNextFolderPage() } },
                                    last: { Task { await browser.showLastFolderPage() } }
                                )
                                Rectangle()
                                    .fill(ChromePalette.hairline)
                                    .frame(height: 1)
                            }
                            DateInspector(browser: browser)
                            if showsServerMovePanel {
                                Rectangle()
                                    .fill(ChromePalette.hairline)
                                    .frame(height: 1)
                                MoveFolderPanel(browser: browser)
                                Rectangle()
                                    .fill(ChromePalette.hairline)
                                    .frame(height: 1)
                                MergePhotosPanel(
                                    firstName: browser.mergeFolderPair()?.first,
                                    secondName: browser.mergeFolderPair()?.second,
                                    busy: browser.mergeBusy || browser.moveBusy || browser.dateBusy
                                        || browser.removalBusy || browser.cleanBusy || browser.rescanBusy
                                        || model.mergePreviewBusy,
                                    previewing: model.showsServerMergePreview,
                                    ready: model.mergePreviewImage != nil,
                                    right: model.mergePreviewRight,
                                    down: model.mergePreviewDown,
                                    preview: { axis in
                                        switch browser.mergePair() {
                                        case .refused(let message):
                                            browser.notice = message
                                        case .ready(let first, let second, let directory, let folder):
                                            browser.notice = EditorModel.mergePreviewingNote
                                            model.beginMergePreview(
                                                first: first,
                                                second: second,
                                                directory: directory,
                                                axis: axis,
                                                serverFolder: folder
                                            )
                                        }
                                    },
                                    retarget: { axis in model.retargetMergePreview(axis: axis) },
                                    merge: {
                                        guard let folder = model.mergePreviewServerFolder else { return }
                                        guard browser.claimMergeWrite() else { return }
                                        Task {
                                            let result = await model.writeMergePreview()
                                            if case .success = result {
                                                model.cancelMergePreview()
                                            }
                                            await browser.finishMergeWrite(result, folder: folder)
                                        }
                                    },
                                    cancel: { model.cancelMergePreview() }
                                )
                            }
                        }
                        .frame(width: 280, alignment: .top)
                        .frame(maxHeight: .infinity, alignment: .top)
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
            browser.openCatalogFile = { url, uid, relative in
                model.openCatalogPhoto(at: url, uid: uid, relativePath: relative)
                UserDefaults.standard.set(false, forKey: "ZImager.serverShowsFolder")
            }
            browser.openVideo = { url in
                model.openVideo(at: url)
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
            model.onMergePreviewNote = { [model, browser] note in
                let server = UserDefaults.standard.string(forKey: "ZImager.sourceMode") == "server"
                if server {
                    if note == nil, browser.notice != EditorModel.mergePreviewingNote { return }
                    browser.notice = note
                } else {
                    if note == nil, model.folderRotateNote != EditorModel.mergePreviewingNote { return }
                    model.folderRotateNote = note
                }
            }
            sectionChangesSelectFolder = true
        }
        .onChange(of: librarySection) { _, section in
            browser.librarySection = section ?? "Photos"
            if sectionChangesSelectFolder {
                serverShowsFolder = true
            }
            if section != "Photos" {
                model.cancelServerMergePreview()
            }
        }
        .onChange(of: sourceMode) { _, mode in
            model.cancelMergePreview()
            if mode == "server", model.canvasTool == .removeObject {
                model.selectCanvasTool(.zoom)
            }
        }
        .onChange(of: model.showsFolderGrid) { _, showing in
            if showing {
                model.publishFolderPreviewFromImage()
            } else {
                model.cancelDiskMergePreview()
            }
        }
        .onChange(of: serverShowsFolder) { _, showing in
            if showing {
                model.publishFolderPreviewFromImage()
            } else {
                model.cancelServerMergePreview()
            }
        }
        .onChange(of: browser.displayFolder) { _, folder in
            model.cancelMergePreviewIfServerFolderChanged(folder)
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
                // Events and Reorganize stay out of the toolbar until those tools are ready.
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
                    .opacity(serverShowsFolder && !model.showsServerMergePreview ? 1 : 0)
                    .allowsHitTesting(serverShowsFolder && !model.showsServerMergePreview)
                    .accessibilityHidden(!serverShowsFolder || model.showsServerMergePreview)
                if serverShowsFolder, model.showsServerMergePreview {
                    mergePreviewLayer
                } else if model.showsPDFPicker, let document = model.pdfDocument, showsImage {
                    PDFPagePicker(
                        document: document,
                        pageIndex: $model.pdfPageIndex,
                        onOpen: { model.openSelectedPDFPage() },
                        onCancel: { model.cancelPDFPicker() }
                    )
                } else if showsImage {
                    VStack(spacing: 0) {
                        if !model.showsVideo {
                            editorBar
                        }
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
                .disabled(model.videoExportBusy || (model.showsVideo && model.videoPlayback == nil))
                .help(model.showsVideo
                    ? "Writes a new movie with the Tone adjustments. The original video is not changed."
                    : "Writes a new file. The original photo is not changed.")
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
                    .opacity(model.showsFolderGrid && !model.showsDiskMergePreview ? 1 : 0)
                    .allowsHitTesting(model.showsFolderGrid && !model.showsDiskMergePreview)
                    .accessibilityHidden(!model.showsFolderGrid || model.showsDiskMergePreview)
                if model.showsFolderGrid, model.showsDiskMergePreview {
                    mergePreviewLayer
                } else if model.showsPDFPicker, let document = model.pdfDocument, !model.showsFolderGrid {
                    PDFPagePicker(
                        document: document,
                        pageIndex: $model.pdfPageIndex,
                        onOpen: { model.openSelectedPDFPage() },
                        onCancel: { model.cancelPDFPicker() }
                    )
                } else if !model.showsFolderGrid {
                    VStack(spacing: 0) {
                        if !model.showsVideo {
                            editorBar
                        }
                        canvas
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var mergePreviewLayer: some View {
        if let image = model.mergePreviewImage {
            MergePreviewCanvas(
                image: image,
                fitted: model.mergePreviewFitted,
                actualToken: model.mergePreviewActualToken,
                firstOrigin: model.mergePreviewFirstOrigin,
                focus: model.mergePreviewFocus,
                spaceDown: model.spaceDown,
                setFitted: { model.mergePreviewFitted = $0 },
                chooseActualSize: {
                    model.mergePreviewFitted = false
                    model.mergePreviewActualToken += 1
                },
                userZoomed: { model.mergePreviewFitted = false }
            )
        } else {
            ZStack {
                Color.black
                Text("Reading the two photos.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("Merge preview")
        }
    }

    private var editorBar: some View {
        HStack(spacing: 12) {
            Button("Zoom") { model.selectCanvasTool(.zoom) }
                .buttonStyle(LibraryPushButtonStyle())
                .toolToggleBorder(active: model.canvasTool == .zoom)
                .accessibilityAddTraits(model.canvasTool == .zoom ? .isSelected : [])
                .help("Click zooms in. Option-click zooms out. Hold Space to pan.")
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
