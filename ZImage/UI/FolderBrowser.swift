import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One immediate child of an opened folder. Listing does not recurse.
nonisolated struct FolderEntry: Equatable, Identifiable, Sendable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var isVideo: Bool = false

    var id: String { Self.cacheKey(for: url) }

    static func cacheKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The Open Folder root and the folder selected in that tree, kept for the next launch.
/// A security-scoped bookmark is used when one can be made. Otherwise a plain bookmark is kept.
enum EditorFolderBookmark {
    static let rootKey = "ZImage.lastFolderRootBookmark"
    static let selectionKey = "ZImage.lastFolderSelectionBookmark"
    static let unavailableMessage = "The last folder could not be opened."

    struct Restored: Equatable {
        var root: URL
        var selection: URL
        var stale: Bool
    }

    static func contains(_ root: URL, _ child: URL) -> Bool {
        let rootPath = FolderEntry.cacheKey(for: root)
        let childPath = FolderEntry.cacheKey(for: child)
        if childPath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return childPath.hasPrefix(prefix)
    }

    static func store(root: URL, selection: URL, defaults: UserDefaults) {
        guard let rootData = try? bookmarkData(for: root) else { return }
        defaults.set(rootData, forKey: rootKey)
        let chosen = contains(root, selection) ? selection : root
        let selectionData = (try? bookmarkData(for: chosen)) ?? rootData
        defaults.set(selectionData, forKey: selectionKey)
    }

    static func resolve(defaults: UserDefaults) -> Restored? {
        guard let rootData = defaults.data(forKey: rootKey),
              let rootBookmark = resolveBookmark(rootData),
              isDirectory(rootBookmark.url) else { return nil }
        var selection = rootBookmark.url
        var stale = rootBookmark.stale
        if let data = defaults.data(forKey: selectionKey),
           let selectionBookmark = resolveBookmark(data),
           isDirectory(selectionBookmark.url),
           contains(rootBookmark.url, selectionBookmark.url) {
            selection = selectionBookmark.url
            stale = stale || selectionBookmark.stale
        }
        return Restored(root: rootBookmark.url, selection: selection, stale: stale)
    }

    static func hasStoredRoot(defaults: UserDefaults) -> Bool {
        defaults.data(forKey: rootKey) != nil
    }

    private struct BookmarkURL {
        var url: URL
        var stale: Bool
    }

    private static func bookmarkData(for url: URL) throws -> Data {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolveBookmark(_ data: Data) -> BookmarkURL? {
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            return BookmarkURL(url: url, stale: stale)
        }
        stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return BookmarkURL(url: url, stale: stale)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// Immediate child folders, ImageIO stills, and video files.
/// The grid does not list X3F or PDF. Those open from File → Open File.
/// With `includeSubfolders`, stills and videos in nested folders are included.
nonisolated enum FolderListing {
    static func list(folder: URL, includeSubfolders: Bool = false) throws -> [FolderEntry] {
        if includeSubfolders {
            var entries: [FolderEntry] = []
            try collect(folder: folder, root: folder, into: &entries)
            entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return entries
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [FolderEntry] = []
        for url in children {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                entries.append(FolderEntry(url: url, name: url.lastPathComponent, isDirectory: true))
                continue
            }
            guard values.isRegularFile == true else { continue }
            if let entry = mediaEntry(url: url, name: url.lastPathComponent) {
                entries.append(entry)
            }
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    /// Stills and videos under `folder`, named relative to `root`. Directories are not returned.
    /// Symbolic links are skipped.
    private static func collect(folder: URL, root: URL, into entries: inout [FolderEntry]) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for url in children {
            if url.lastPathComponent.hasPrefix(".") { continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                try collect(folder: url, root: root, into: &entries)
                continue
            }
            guard values.isRegularFile == true else { continue }
            if let entry = mediaEntry(url: url, name: relativeName(file: url, root: root)) {
                entries.append(entry)
            }
        }
    }

    private static func relativeName(file: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if file.path.hasPrefix(rootPath) {
            return String(file.path.dropFirst(rootPath.count))
        }
        return file.lastPathComponent
    }

    private static func mediaEntry(url: URL, name: String) -> FolderEntry? {
        if isVideo(url) {
            return FolderEntry(url: url, name: name, isDirectory: false, isVideo: true)
        }
        guard isImageIOStill(url) else { return nil }
        return FolderEntry(url: url, name: name, isDirectory: false)
    }

    /// Same extensions as the library video list. One directory level only.
    static func isVideo(_ url: URL) -> Bool {
        LibraryItemMenu.videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// ImageIO stills the current editor can open. One directory level only.
    static func isImageIOStill(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "x3f" || ext == "pdf" {
            return false
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let uti = CGImageSourceGetType(source) as String?,
              let type = UTType(uti) else {
            return false
        }
        if type.conforms(to: .pdf) || type.conforms(to: .movie) {
            return false
        }
        if let raw = UTType("public.camera-raw-image"), type.conforms(to: raw) {
            return true
        }
        return type.conforms(to: .image)
    }
}

/// One JPEG per source file under `temporaryDirectory/ZImage/folder-previews/`.
/// Long edge at most 250. JPEG quality is 70%. The cap starts at 200 MB and is kept across launches.
/// Quitting and opening another folder leave these files in place.
nonisolated enum FolderPreviewCache {
    static let maxLongEdge = 250
    /// `kCGImageDestinationLossyCompressionQuality`. 0.7 is 70%.
    static let jpegQuality = 0.7
    static let defaultMegabytes = 200
    static let defaultsKey = "ZImage.previewCacheMegabytes"
    static let defaultByteCap: Int64 = 200 * 1024 * 1024
    static var byteCap: Int64 = defaultByteCap

    /// A whole number of megabytes from 1 through 100000. Blank and zero are refused.
    static func megabytes(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...100_000).contains(value) else { return nil }
        return value
    }

    static func bytes(forMegabytes megabytes: Int) -> Int64 {
        Int64(megabytes) * 1024 * 1024
    }

    static func storedMegabytes() -> Int {
        let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Int
        guard let stored, (1...100_000).contains(stored) else { return defaultMegabytes }
        return stored
    }

    /// Uses the saved size, or 200 MB when none has been set.
    static func loadStoredCap() {
        applyMegabytes(storedMegabytes(), persist: false)
    }

    static func applyMegabytes(_ megabytes: Int, persist: Bool) {
        byteCap = bytes(forMegabytes: megabytes)
        if persist {
            UserDefaults.standard.set(megabytes, forKey: defaultsKey)
        }
        gate.sync { evictOldestLocked() }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        func sync<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }

    private static let gate = Gate()

    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ZImage", isDirectory: true)
            .appendingPathComponent("folder-previews", isDirectory: true)
    }

    static func wipe() {
        gate.sync {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Returns the existing JPEG when this source already has one.
    static func ensureJPEG(for source: URL) throws -> URL {
        let destination = directory.appendingPathComponent(fileName(for: source), isDirectory: false)
        let exists = gate.sync { FileManager.default.fileExists(atPath: destination.path) }
        if exists {
            gate.sync {
                touch(destination)
                evictOldestLocked()
            }
            return destination
        }
        let image = try thumbnail(for: source)
        try gate.sync {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                touch(destination)
            } else {
                try writeJPEG(image, to: destination)
            }
            evictOldestLocked()
        }
        return destination
    }

    static func stamps() -> [FolderPreviewStamp] {
        gate.sync { stampsLocked() }
    }

    /// Stable per source path. The preview size is not part of the name.
    static func fileName(for source: URL) -> String {
        let path = source.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex + ".jpg"
    }

    private static func thumbnail(for source: URL) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, sourceOptions) else {
            throw FolderPreviewError.unreadable(source.lastPathComponent)
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw FolderPreviewError.unreadable(source.lastPathComponent)
        }
        if max(image.width, image.height) > maxLongEdge {
            guard let fitted = scale(image, longEdge: maxLongEdge) else {
                throw FolderPreviewError.unreadable(source.lastPathComponent)
            }
            image = fitted
        }
        guard max(image.width, image.height) <= maxLongEdge else {
            throw FolderPreviewError.unreadable(source.lastPathComponent)
        }
        return image
    }

    private static func scale(_ image: CGImage, longEdge: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let edge = max(width, height)
        guard edge > longEdge, edge > 0 else { return image }
        let factor = Double(longEdge) / Double(edge)
        let fittedWidth = max(1, Int((Double(width) * factor).rounded(.down)))
        let fittedHeight = max(1, Int((Double(height) * factor).rounded(.down)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: fittedWidth,
                height: fittedHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: fittedWidth, height: fittedHeight))
        return context.makeImage()
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw FolderPreviewError.writeFailed(url.lastPathComponent)
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw FolderPreviewError.writeFailed(url.lastPathComponent)
        }
    }

    /// Drops the oldest JPEGs until the directory is within `byteCap`. The newest file stays.
    private static func evictOldestLocked() {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        var records: [(url: URL, size: Int64, date: Date)] = []
        for url in urls where url.pathExtension.lowercased() == "jpg" {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            records.append((
                url,
                Int64(values?.fileSize ?? 0),
                values?.contentModificationDate ?? .distantPast
            ))
        }
        records.sort { $0.date < $1.date }
        var total = records.reduce(Int64(0)) { $0 + $1.size }
        var index = 0
        while total > byteCap, index < records.count - 1 {
            try? manager.removeItem(at: records[index].url)
            total -= records[index].size
            index += 1
        }
    }

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private static func stampsLocked() -> [FolderPreviewStamp] {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let bytes = (try? Data(contentsOf: url)) ?? Data()
                return FolderPreviewStamp(
                    name: url.lastPathComponent,
                    bytes: bytes,
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                )
            }
    }
}

nonisolated struct FolderPreviewStamp: Equatable, Sendable {
    var name: String
    var bytes: Data
    var modifiedAt: Date
}

nonisolated enum FolderPreviewError: Error, Equatable {
    case unreadable(String)
    case writeFailed(String)
}

/// One scroll-geometry sample for the folder grid.
struct FolderScrollSample: Equatable {
    var y: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
}

/// Saved folder-grid offsets. Field writes do not refresh the editor.
final class FolderScrollMemory {
    var yByFolder: [String: CGFloat] = [:]
    /// Folder that should return to its saved offset before new scrolling is recorded.
    var holding: String?
    var wasVisible = false
    var visibleKey: String?
}

struct FolderScrollDecision: Equatable {
    var rememberY: CGFloat?
    var scrollTo: CGFloat?
    var clearHold: Bool
}

/// Decides whether a geometry change is the user's place in the grid or a tab-switch reset.
enum FolderScrollKeep {
    static let minimumSpan: CGFloat = 40

    static func rememberedY(_ sample: FolderScrollSample) -> CGFloat? {
        guard sample.containerHeight > minimumSpan, sample.contentHeight > minimumSpan else { return nil }
        return max(0, sample.y)
    }

    /// Nil while the grid has no real content yet. Otherwise the saved offset clamped to the content.
    static func restoreTarget(saved: CGFloat, sample: FolderScrollSample) -> CGFloat? {
        guard sample.containerHeight > minimumSpan, sample.contentHeight > minimumSpan else { return nil }
        let maxY = max(0, sample.contentHeight - sample.containerHeight)
        return min(max(0, saved), maxY)
    }

    static func decide(
        sample: FolderScrollSample,
        saved: CGFloat,
        holding: Bool,
        folderVisible: Bool,
        userMoved: Bool
    ) -> FolderScrollDecision {
        let none = FolderScrollDecision(rememberY: nil, scrollTo: nil, clearHold: false)
        if holding {
            guard let target = restoreTarget(saved: saved, sample: sample) else { return none }
            if userMoved, abs(sample.y - target) > 1 {
                return FolderScrollDecision(rememberY: max(0, sample.y), scrollTo: nil, clearHold: true)
            }
            if abs(sample.y - target) > 1 {
                return FolderScrollDecision(rememberY: nil, scrollTo: target, clearHold: false)
            }
            return FolderScrollDecision(rememberY: target, scrollTo: nil, clearHold: true)
        }
        guard folderVisible, let y = rememberedY(sample) else { return none }
        return FolderScrollDecision(rememberY: y, scrollTo: nil, clearHold: false)
    }
}

/// Right-click actions for one still in the editor folder grid.
enum EditorImageMenu {
    static let editImage = "Edit Image"
    static let showInFinder = "Show in Finder"
    static let openIn = "Open In"
    static let commandOrder = [editImage, showInFinder, openIn]
    static let videoCommandOrder = [LibraryItemMenu.openWithQuickTime, showInFinder, LibraryItemMenu.openWith]

    static func isEditor(_ application: URL) -> Bool {
        if let bundle = Bundle(url: application), bundle.bundleIdentifier == EditorHandoff.editorBundleID {
            return true
        }
        let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: EditorHandoff.editorBundleID)
        return application.standardizedFileURL.path == editor?.standardizedFileURL.path
    }
}

struct FolderBrowser: View {
    @Bindable var model: EditorModel
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var scrollMemory = FolderScrollMemory()

    var body: some View {
        let _ = pinScrollBeforeLayout()
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PreviewSizeSlider(points: Binding(
                    get: { model.previewPoints },
                    set: { model.previewPoints = PreviewSize.clamped($0) }
                ))
                Text(model.folderTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(ChromePalette.panel)

            if let folderMessage = model.folderMessage {
                Text(folderMessage)
                    .font(.body)
                    .foregroundStyle(ChromePalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            } else if model.folderURL == nil {
                Text("Open a folder to see its stills and videos.")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            } else if model.folderListingReady && images.isEmpty {
                Text("No still images or videos in this folder.")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(images) { entry in
                            cell(entry)
                        }
                    }
                    .padding(16)
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: FolderScrollSample.self) { geometry in
                    FolderScrollSample(
                        y: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height
                    )
                } action: { _, sample in
                    followScroll(sample)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Folder grid")
    }

    private var folderKey: String? {
        model.folderURL.map { FolderEntry.cacheKey(for: $0) }
    }

    /// Runs before layout so a tab switch cannot record the reset-to-top offset.
    private func pinScrollBeforeLayout() {
        let visible = model.showsFolderGrid
        let key = folderKey
        let becameVisible = visible && !scrollMemory.wasVisible
        let changedFolder = visible && key != scrollMemory.visibleKey
        if becameVisible || changedFolder, let key {
            scrollMemory.holding = key
        }
        scrollMemory.wasVisible = visible
        scrollMemory.visibleKey = visible ? key : nil
    }

    private func followScroll(_ sample: FolderScrollSample) {
        guard let key = folderKey else { return }
        let saved = scrollMemory.yByFolder[key] ?? 0
        let decision = FolderScrollKeep.decide(
            sample: sample,
            saved: saved,
            holding: scrollMemory.holding == key,
            folderVisible: model.showsFolderGrid,
            userMoved: scrollPosition.isPositionedByUser
        )
        if let y = decision.rememberY {
            scrollMemory.yByFolder[key] = y
        }
        if decision.clearHold, scrollMemory.holding == key {
            scrollMemory.holding = nil
        }
        if let y = decision.scrollTo {
            scrollPosition.scrollTo(y: y)
        }
    }

    private var images: [FolderEntry] {
        model.folderEntries.filter { !$0.isDirectory }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.previewPoints, maximum: model.previewPoints), spacing: 12)]
    }

    private func cell(_ entry: FolderEntry) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(ChromePalette.canvas.opacity(0.12))
                if let jpeg = model.previewJPEG(for: entry),
                   let image = NSImage(contentsOf: jpeg) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                }
            }
            .frame(width: model.previewPoints, height: model.previewPoints)
            Text(entry.name)
                .font(.system(size: 12))
                .foregroundStyle(ChromePalette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: model.previewPoints)
            if entry.isVideo {
                Text("Video")
                    .font(.system(size: 11))
                    .foregroundStyle(ChromePalette.muted)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.openListedEntry(entry)
        }
        .contextMenu {
            if entry.isVideo {
                Button(LibraryItemMenu.openWithQuickTime) {
                    model.openInQuickTime(entry)
                }
            } else {
                Button(EditorImageMenu.editImage) {
                    model.openListedEntry(entry)
                }
            }
            Button(EditorImageMenu.showInFinder) {
                model.showInFinder(entry)
            }
            Menu(entry.isVideo ? LibraryItemMenu.openWith : EditorImageMenu.openIn) {
                let targets = entry.isVideo ? model.videoApplications(for: entry) : model.imageApplications(for: entry)
                if targets.isEmpty {
                    Text("No application")
                } else {
                    ForEach(targets) { target in
                        Button(target.name) {
                            model.open(entry, with: target.url)
                        }
                    }
                }
            }
            Divider()
            Text(model.sizeLabel(for: entry))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.name)
        .accessibilityHint(entry.isVideo
            ? "Double-click opens this video in QuickTime Player. The menu can show it in Finder or open it in a video player."
            : "Double-click edits this image. The menu can show it in Finder or open it in another application.")
        .help(entry.isVideo ? "Double-click opens this video in QuickTime Player." : "Double-click edits this image.")
    }
}
