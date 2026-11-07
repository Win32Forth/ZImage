import AppKit
import Darwin
import Foundation
import SwiftUI

/// Photos is the library. Videos lists the movies still stored under Photos. Review lists the park. Duplicates lists the store. The path stays `Photos/_Duplicates`.
enum LibrarySidebar {
    static let items = ["Photos", "Videos", "Review", "Duplicates"]

    /// A folder click keeps Videos on screen. Review and Duplicates move to Photos.
    static func sectionAfterTreePick(_ current: String?) -> String {
        current == "Videos" ? "Videos" : "Photos"
    }

    static func media(for section: String) -> String {
        section == "Videos" ? "video" : "photo"
    }
}

/// A file with no confidence stays out of the park. The server `review=1` query is the list the grid loads.
enum ReviewPark {
    static let threshold = 0.70

    static func contains(_ asset: LibraryAsset) -> Bool {
        guard let confidence = asset.captureConfidence else { return false }
        if confidence < threshold { return true }
        let path = asset.relPath ?? ""
        return path.hasPrefix("Photos/_Review/")
    }
}

/// The sandboxed library stored its host and folder bookmark in the container.
/// An unsandboxed launch reads the normal preferences and would otherwise stay offline.
enum SandboxPreferenceImport {
    static func adoptLibraryContainer(into defaults: UserDefaults = .standard) {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.Win32Forth.ZImageLibrary/Data/Library/Preferences/com.Win32Forth.ZImageLibrary.plist")
        adopt(into: defaults, containerPlist: plist)
    }

    static func adopt(into defaults: UserDefaults, containerPlist: URL) {
        guard let data = try? Data(contentsOf: containerPlist),
              let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return
        }
        let host = defaults.string(forKey: LibraryAppClient.hostDefaultsKey) ?? ""
        if !HelperClient.isIPv4(host),
           let saved = stored[LibraryAppClient.hostDefaultsKey] as? String,
           HelperClient.isIPv4(saved) {
            defaults.set(saved, forKey: LibraryAppClient.hostDefaultsKey)
        }
        if defaults.data(forKey: LibraryFolderBookmark.defaultsKey) == nil,
           let bookmark = stored[LibraryFolderBookmark.defaultsKey] as? Data {
            defaults.set(bookmark, forKey: LibraryFolderBookmark.defaultsKey)
        }
    }
}

enum LibraryFolderBookmark {
    static let defaultsKey = "ZImageLibrary.shareBookmark"

    static func store(_ url: URL, defaults: UserDefaults) throws {
        let data = try bookmarkData(for: url)
        defaults.set(data, forKey: defaultsKey)
    }

    static func resolve(defaults: UserDefaults) -> URL? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return resolveBookmark(data)
    }

    /// A security-scoped bookmark is kept when the sandbox can make one. Otherwise a plain bookmark is enough.
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

    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            return url
        }
        stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }
}

enum LibraryPairing {
    static let missingToken = "The helper has no pairing token in .zimage."

    struct Material: Equatable {
        var token: String
        /// True when the one-time file is still on the share. Claim sends the token in the body.
        var fromPairingFile: Bool
    }

    static func material(inLibraryRoot root: URL) throws -> Material {
        let pairing = root.appendingPathComponent(".zimage").appendingPathComponent("PAIRING-TOKEN")
        if FileManager.default.fileExists(atPath: pairing.path) {
            return Material(token: try PairingFile.token(inLibraryRoot: root), fromPairingFile: true)
        }
        let auth = root.appendingPathComponent(".zimage").appendingPathComponent("auth.token")
        let token = (try String(contentsOf: auth, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw HelperError.unauthorized }
        return Material(token: token, fromPairingFile: false)
    }

    /// `//user@DS423._smb._tcp.local/BackupData` or `smb://user@host/share`.
    static func mountHost(fromMountSource source: String) -> String? {
        var text = source
        if text.hasPrefix("smb://") {
            text.removeFirst("smb://".count)
        } else if text.hasPrefix("//") {
            text.removeFirst(2)
        } else {
            return nil
        }
        let hostAndUser = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let host = hostAndUser.split(separator: "@").last.map(String.init) ?? ""
        let name = host.split(separator: ":").first.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    /// The SMB Bonjour name often has no A record. `DS423._smb._tcp.local` is also looked up as `DS423.local`.
    static func lookupNames(forMountHost host: String) -> [String] {
        let marker = "._smb._tcp.local"
        guard host.hasSuffix(marker) else { return [host] }
        let base = String(host.dropLast(marker.count))
        guard !base.isEmpty else { return [host] }
        return [host, base + ".local"]
    }

    static func firstIPv4(mountHost: String, resolve: (String) throws -> String) throws -> String {
        var failure: Error = HelperError.notIPv4
        for name in lookupNames(forMountHost: mountHost) {
            do {
                let address = try resolve(name)
                guard HelperClient.isIPv4(address) else { throw HelperError.notIPv4 }
                return address
            } catch {
                failure = error
            }
        }
        throw failure
    }

    static func mountSource(forPath path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafePointer(to: info.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.f_mntfromname)) {
                String(cString: $0)
            }
        }
    }
}

enum LibraryAppClient {
    static let hostDefaultsKey = "ZImageLibrary.helperHost"

    /// Used when the library has no stored IPv4 helper. It does not open a socket.
    static func offline() -> HelperClient {
        HelperClient(credentials: HelperCredentials(host: "0.0.0.0")) { _ in
            throw HelperError.offline
        }
    }
}

struct LibraryGridCell: Equatable, Sendable {
    var imageData: Data?
    /// Helper thumbnail. A cell never stores a file URL of the original.
    var thumbnailURL: URL?
    var badge: String?
    var placeholder: Bool
}

struct LibraryOpenTarget: Identifiable, Equatable, Sendable {
    var url: URL
    var name: String
    var isZImage: Bool
    var id: String { url.path }
}

/// A calendar day written in a filename or folder. The date closest to the file wins.
enum PathCapture {
    private static let patterns = [
        #"(?i)(?:^|[^A-Za-z0-9])IMG_(\d{4})(\d{2})(\d{2})(?:[^0-9]|$)"#,
        #"(?:^|[^0-9])(\d{4})-(\d{2})-(\d{2})(?:[^0-9]|$)"#,
        #"(?:^|[^0-9])(\d{4})(\d{2})(\d{2})(?:[^0-9]|$)"#,
    ]

    static func day(in relPath: String?, now: Date = Date()) -> String? {
        guard let relPath, !relPath.isEmpty else { return nil }
        let base = (relPath as NSString).lastPathComponent
        if let day = findDay(in: base, now: now) { return day }
        return findDay(in: relPath, now: now)
    }

    static func year(in relPath: String?, now: Date = Date()) -> String? {
        guard let relPath else { return nil }
        var found: String?
        for part in relPath.split(separator: "/").dropLast() {
            guard part.count == 4, part.allSatisfy(\.isNumber), let year = Int(part) else { continue }
            if year == 1969 || !yearOK(year, now: now) { continue }
            found = String(format: "%04d", year)
        }
        return found
    }

    /// Shown under a video name, and in the inspector. A catalog day stays the caption.
    static func lines(for relPath: String?, now: Date = Date()) -> [String] {
        if let day = day(in: relPath, now: now) { return ["Path date \(day)"] }
        if let year = year(in: relPath, now: now) { return ["Path year \(year)"] }
        return []
    }

    private static func findDay(in text: String, now: Date) -> String? {
        let padded = " " + text
        let ns = padded as NSString
        let range = NSRange(location: 0, length: ns.length)
        var bestAt = -1
        var best: String?
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: padded, range: range) where match.numberOfRanges >= 4 {
                guard let year = int(ns, match.range(at: 1)),
                      let month = int(ns, match.range(at: 2)),
                      let day = int(ns, match.range(at: 3)),
                      valid(year: year, month: month, day: day),
                      yearOK(year, now: now),
                      !epoch(year: year, month: month, day: day) else { continue }
                let at = match.range(at: 1).location
                if best != nil && at <= bestAt { continue }
                bestAt = at
                best = String(format: "%04d-%02d-%02d", year, month, day)
            }
        }
        return best
    }

    private static func int(_ text: NSString, _ range: NSRange) -> Int? {
        guard range.location != NSNotFound else { return nil }
        return Int(text.substring(with: range))
    }

    private static func yearOK(_ year: Int, now: Date) -> Bool {
        year >= 1960 && year <= calendar.component(.year, from: now) + 1
    }

    private static func epoch(year: Int, month: Int, day: Int) -> Bool {
        (year == 1969 && month == 12 && day == 31) || (year == 1970 && month == 1 && day == 1)
    }

    private static func valid(year: Int, month: Int, day: Int) -> Bool {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        guard let date = calendar.date(from: parts) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}

/// Right-click actions for one library file. Open with ZImage is the first command for a still.
/// A video leads with QuickTime Player.
enum LibraryItemMenu {
    static let openWithZImage = "Open with ZImage"
    static let openWithQuickTime = "Open with QuickTime Player"
    static let quickTimeBundleID = "com.apple.QuickTimePlayerX"
    static let showInFinder = "Show in Finder"
    static let openWith = "Open With"
    static let sizeUnavailable = "Size unavailable"
    static let noDate = "No date"

    static let commandOrder = [openWithZImage, showInFinder, openWith]
    static let videoCommandOrder = [openWithQuickTime, showInFinder, openWith]

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "m4p", "avi", "mkv", "mpg", "mpeg", "mpe", "m2v",
        "wmv", "flv", "webm", "3gp", "3g2", "mts", "m2ts", "ts", "vob", "ogv", "asf", "divx",
    ]

    /// A catalog capture time shown as a day. A year-only value stays four digits.
    static func captureLabel(_ captureTime: String?) -> String {
        guard let captureTime, !captureTime.isEmpty else { return noDate }
        if captureTime.count == 4 { return captureTime }
        if captureTime.count >= 10 { return String(captureTime.prefix(10)) }
        return captureTime
    }

    /// The value posted to the helper. A calendar day is midnight UTC. A year stays four digits.
    static func captureRequest(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 4, trimmed.allSatisfy(\.isNumber), Int(trimmed) != nil {
            return trimmed
        }
        if trimmed.count == 10, trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)] == "-", trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)] == "-" {
            let year = Int(trimmed.prefix(4))
            let month = Int(trimmed.dropFirst(5).prefix(2))
            let day = Int(trimmed.dropFirst(8).prefix(2))
            if let year, let month, let day, calendarDay(year: year, month: month, day: day) {
                return trimmed + "T00:00:00Z"
            }
            return nil
        }
        if trimmed.contains("T"), isoTimestamp(trimmed) {
            return trimmed
        }
        return nil
    }

    private static func calendarDay(year: Int, month: Int, day: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        guard let date = calendar.date(from: parts) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }

    private static func isoTimestamp(_ text: String) -> Bool {
        ISO8601DateFormatter().date(from: text) != nil
    }

    /// The catalog day when one is stored. Otherwise a date written in the path.
    static func videoCaption(captureTime: String?, relPath: String?) -> String {
        let stored = captureLabel(captureTime)
        if stored != noDate { return stored }
        if let day = PathCapture.day(in: relPath) { return day }
        if let year = PathCapture.year(in: relPath) { return year }
        return noDate
    }

    /// Decimal megabytes, the same 1,000,000-byte unit Finder uses for MB.
    static func sizeLabel(bytes: Int?) -> String {
        guard let bytes, bytes >= 0 else { return sizeUnavailable }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    /// ZImage stays first. A second copy of the same application is left out.
    static func applications(zimage: URL?, others: [URL], names: (URL) -> String) -> [LibraryOpenTarget] {
        var ordered: [URL] = []
        if let zimage {
            ordered.append(zimage)
        }
        let zimagePath = zimage?.standardizedFileURL.path
        for url in others {
            let path = url.standardizedFileURL.path
            if path == zimagePath || ordered.contains(where: { $0.standardizedFileURL.path == path }) {
                continue
            }
            ordered.append(url)
        }
        return ordered.map { url in
            let isZImage = url.standardizedFileURL.path == zimagePath
            return LibraryOpenTarget(url: url, name: isZImage ? "ZImage" : names(url), isZImage: isZImage)
        }
    }

    /// QuickTime Player stays first. ZImage and a second copy of QuickTime are left out.
    static func videoApplications(quickTime: URL?, others: [URL], editor: URL?, names: (URL) -> String) -> [LibraryOpenTarget] {
        var ordered: [URL] = []
        if let quickTime {
            ordered.append(quickTime)
        }
        let skip = Set([quickTime, editor].compactMap { $0?.standardizedFileURL.path })
        for url in others {
            let path = url.standardizedFileURL.path
            if skip.contains(path) || ordered.contains(where: { $0.standardizedFileURL.path == path }) {
                continue
            }
            ordered.append(url)
        }
        let quickPath = quickTime?.standardizedFileURL.path
        return ordered.map { url in
            let isQuickTime = url.standardizedFileURL.path == quickPath
            return LibraryOpenTarget(url: url, name: isQuickTime ? "QuickTime Player" : names(url), isZImage: false)
        }
    }
}

/// The folder shown on the Photos tab. The share root is refused.
enum DisplayFolder {
    static let root = "Photos"
    static let outsidePhotos = "The display folder must be Photos or a folder inside it."

    static func prefix(selected: URL, libraryRoot: URL) -> String? {
        let rootPath = libraryRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let pickedPath = selected.standardizedFileURL.resolvingSymlinksInPath().path
        if pickedPath == rootPath {
            return nil
        }
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard pickedPath.hasPrefix(rootPrefix) else { return nil }
        let relative = String(pickedPath.dropFirst(rootPrefix.count))
        let parts = relative.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.first == "Photos" else { return nil }
        return parts.joined(separator: "/")
    }

    /// A trailing slash keeps Photos/2026 from also matching Photos/20260.
    static func needle(_ folder: String) -> String? {
        let parts = folder.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.first == "Photos", parts.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        return parts.joined(separator: "/") + "/"
    }
}

/// One page of the catalog grid. Cells scale a single 512 px JPEG.
@MainActor
@Observable
final class LibraryBrowser {
    static let pageLimit = 200

    private var client: HelperClient
    let session: LibrarySession
    var notice: String?
    private(set) var rows: [LibraryAsset] = []
    private(set) var reviewRows: [LibraryAsset] = []
    private(set) var events: [LibraryEvent] = []
    private(set) var reorg: ReorgStatus?
    var reorgPrefix = "Photos"
    /// Relative folder shown in the Photos and Videos grids. Review and Duplicates ignore it.
    var displayFolder = DisplayFolder.root
    private(set) var reorgNotice: String?
    private(set) var reorgPending: ReorgPending?
    /// Seconds the panel has been counting, stepped every status check.
    private(set) var reorgTick = 0
    private(set) var reorgStatusFault: String?
    private(set) var trim: TrimStatus?
    private(set) var trimNotice: String?
    private(set) var duplicateGroups: [DuplicateGroup] = []
    private(set) var duplicateNotice: String?
    private(set) var duplicateThumbCount = 0
    private(set) var cells: [String: LibraryGridCell] = [:]
    private(set) var previewPoints: Double = PreviewSize.defaultPoints
    private(set) var thumbnailRequestCount = 0
    var libraryRoot: URL
    var selectedUID: String?
    var selectedEventUID: String?
    var openFile: (URL, String) -> Void
    /// When set, a video open calls this instead of QuickTime Player.
    var openVideo: ((URL) -> Void)?
    private var scopedRoot: URL?
    private var fetchedThumbs: Set<String> = []
    private var fetchedDuplicateThumbs: Set<String> = []
    private var checkpointed: Set<String> = []
    /// Visible stills this session already tried to reduce. A new folder's rows are not in this set.
    private var previewTried: Set<String> = []

    init(client: HelperClient, libraryRoot: URL, openFile: @escaping (URL, String) -> Void) {
        self.client = client
        self.session = LibrarySession(client: client)
        self.libraryRoot = libraryRoot
        self.openFile = openFile
    }

    func adoptLibraryRoot(_ url: URL) {
        if let scopedRoot {
            scopedRoot.stopAccessingSecurityScopedResource()
        }
        if url.startAccessingSecurityScopedResource() {
            scopedRoot = url
        } else {
            scopedRoot = nil
        }
        libraryRoot = url
    }

    /// Switches the grid onto a paired helper. The next reload uses that client.
    func connect(_ client: HelperClient) {
        self.client = client
        session.use(client)
        rows = []
        reviewRows = []
        events = []
        cells = [:]
        fetchedThumbs = []
        checkpointed = []
        previewTried = []
        selectedUID = nil
        selectedEventUID = nil
        notice = nil
        reorg = nil
        reorgNotice = nil
        reorgPending = nil
        reorgStatusFault = nil
        reorgPrefix = "Photos"
        displayFolder = DisplayFolder.root
        trim = nil
        trimNotice = nil
        duplicateGroups = []
        duplicateNotice = nil
        fetchedDuplicateThumbs = []
    }

    /// `photo` hides videos. `video` lists movies, earliest capture day first.
    func reload(media: String? = nil) async {
        let folder = (media == "photo" || media == "video") ? displayFolder : nil
        await session.refresh(media: media, under: folder)
        var loaded = Array(session.rows.prefix(Self.pageLimit))
        if media == "video" {
            loaded = loaded.filter { isVideo($0) }.sorted { captureKey($0) < captureKey($1) }
        } else if media == "photo" {
            loaded = loaded.filter { !isVideo($0) }
        }
        rows = loaded
        if let selectedUID, rows.contains(where: { $0.uid == selectedUID }) == false {
            self.selectedUID = nil
        }
        await loadThumbnails()
    }

    private func captureKey(_ asset: LibraryAsset) -> String {
        let time = asset.captureTime ?? ""
        return time.isEmpty ? "9999" : time
    }

    /// Loads one reduced JPEG for the selected Review row. The grid request counter stays as it is.
    func ensurePreview(for uid: String?) async {
        guard let uid else { return }
        if cells[uid]?.imageData != nil { return }
        let asset = reviewRows.first { $0.uid == uid } ?? rows.first { $0.uid == uid }
        guard let asset else { return }
        if asset.thumbRel == nil {
            if cells[uid] == nil {
                cells[uid] = LibraryGridCell(
                    imageData: nil,
                    thumbnailURL: nil,
                    badge: cellBadge(for: asset),
                    placeholder: true
                )
            }
            return
        }
        if fetchedThumbs.contains(uid) { return }
        let url = thumbnailURL(uid: uid)
        do {
            let data = try await client.thumbnail(uid: uid)
            fetchedThumbs.insert(uid)
            cells[uid] = LibraryGridCell(
                imageData: data,
                thumbnailURL: url,
                badge: cellBadge(for: asset),
                placeholder: false
            )
        } catch {
            cells[uid] = LibraryGridCell(
                imageData: nil,
                thumbnailURL: nil,
                badge: cellBadge(for: asset),
                placeholder: true
            )
        }
    }

    /// Loads the park into `reviewRows`. The Photos grid rows stay as they are.
    func loadReview() async {
        do {
            let page = try await client.reviewAssets()
            reviewRows = Array(page.rows.prefix(Self.pageLimit))
        } catch {
            reviewRows = []
        }
    }

    /// Posts one typed date. Confidence becomes 1.0. The file stays where it is.
    func setCaptureDate(_ text: String) async {
        guard let selectedUID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let wire = LibraryItemMenu.captureRequest(trimmed) else {
            notice = "The date was not saved. Use YYYY-MM-DD or a four-digit year."
            return
        }
        do {
            let updated = try await client.setCaptureDate(uid: selectedUID, captureTime: wire)
            notice = "Confidence 1.0"
            replace(updated)
        } catch {
            notice = "The date was not saved."
        }
    }

    func loadEvents() async {
        do {
            events = try await client.events()
            if let selectedEventUID, events.contains(where: { $0.uid == selectedEventUID }) == false {
                self.selectedEventUID = nil
            }
        } catch {
            events = []
        }
    }

    /// Loads the reorg lamp and the step line. A failed check keeps the last answer.
    func loadReorg() async {
        do {
            reorg = try await client.reorgStatus()
            reorgStatusFault = nil
            absorbReorgPoll()
            bumpReorgTick()
        } catch {
            let counting = reorg?.runState == "planning"
            if case .planning = reorgPending {
                reorgStatusFault = nil
            } else if counting {
                reorgStatusFault = nil
            } else if reorg != nil {
                reorgStatusFault = "No answer from the helper."
            }
            bumpReorgTick()
        }
    }

    /// Advances the counting line by 2 seconds while a plan is still open.
    private func bumpReorgTick() {
        let planning: Bool
        if case .planning = reorgPending {
            planning = true
        } else {
            planning = reorg?.runState == "planning"
        }
        if planning {
            reorgTick += 2
        } else {
            reorgTick = 0
        }
    }

    /// Typing a new folder drops the previous error. The status line says to plan.
    func reorgPrefixChanged(from old: String, to new: String) {
        guard old != new else { return }
        reorgNotice = nil
    }

    /// Opens the share at Photos and stores the chosen folder as the plan prefix.
    func chooseReorgFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder inside Photos."
        let photos = libraryRoot.appendingPathComponent("Photos", isDirectory: true)
        if FileManager.default.fileExists(atPath: photos.path) {
            panel.directoryURL = photos
        } else {
            panel.directoryURL = libraryRoot
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let prefix = ReorgFolder.prefix(selected: url, libraryRoot: libraryRoot) else {
            reorgNotice = ReorgCopy.outsidePhotos
            return
        }
        reorgPrefix = prefix
        reorgNotice = nil
    }

    /// Opens the share at the current folder and shows that folder in the grid.
    /// Photos and Videos share `displayFolder`.
    func chooseDisplayFolder(media: String = "photo") {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Display Folder"
        panel.message = "Choose a folder inside Photos to display."
        let current = libraryRoot.appending(path: displayFolder)
        let photos = libraryRoot.appendingPathComponent("Photos", isDirectory: true)
        if FileManager.default.fileExists(atPath: current.path) {
            panel.directoryURL = current
        } else if FileManager.default.fileExists(atPath: photos.path) {
            panel.directoryURL = photos
        } else {
            panel.directoryURL = libraryRoot
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let prefix = DisplayFolder.prefix(selected: url, libraryRoot: libraryRoot) else {
            notice = DisplayFolder.outsidePhotos
            return
        }
        displayFolder = prefix
        notice = nil
        let shown = (media == "photo" || media == "video") ? media : "photo"
        Task { await reload(media: shown) }
    }

    /// Dry-run for the typed prefix. Nothing is copied.
    func planReorg() async {
        let prefix = ReorgActivity.folder(reorgPrefix)
        if reorgPrefix != prefix {
            reorgPrefix = prefix
        }
        reorgPending = .planning(prefix)
        reorgNotice = nil
        do {
            let reply = try await client.reorgPlan(prefix: prefix)
            if let code = reply.error {
                reorgPending = nil
                reorgNotice = ReorgCopy.planFailure(code)
                await loadReorg()
                return
            }
            guard reply.plan != nil else {
                reorgPending = nil
                reorgNotice = ReorgCopy.planFailure(nil)
                return
            }
            reorgNotice = nil
            await loadReorg()
            if case .planning(let sent) = reorgPending, reorg?.phase == sent, reorg?.runState == "plan_ready" {
                reorgPending = nil
            } else if reorg?.runState != "planning" {
                reorgPending = nil
            }
        } catch let error as URLError where error.code == .timedOut {
            await loadReorg()
        } catch let error as HelperError {
            reorgPending = nil
            reorgNotice = ReorgCopy.unreachable(error, action: "the plan")
        } catch {
            reorgPending = nil
            reorgNotice = ReorgCopy.unreachable(.offline, action: "the plan")
        }
    }

    /// One Start for the planned prefix. A changed folder is not sent.
    func startReorg() async {
        if case .planning = reorgPending {
            reorgNotice = reorg?.runState == "planning" ? ReorgCopy.startWhilePlanning : ReorgCopy.startWhilePlanOpen
            return
        }
        let typed = ReorgActivity.folder(reorgPrefix)
        let saved = reorg.flatMap { ReorgActivity.savedFolder($0.phase) }
        if saved != typed {
            reorgNotice = ReorgCopy.startNeedsPlan(typed: typed, saved: saved)
            return
        }
        reorgPending = .starting
        reorgNotice = nil
        do {
            let reply = try await client.reorgStart()
            applyReorg(reply, idle: "Start was not confirmed. The helper sent no status.")
        } catch let error as URLError where error.code == .timedOut {
            reorgNotice = ReorgCopy.startTimedOut
            await loadReorg()
        } catch let error as HelperError {
            reorgPending = nil
            reorgNotice = ReorgCopy.unreachable(error, action: "Start")
        } catch {
            reorgPending = nil
            reorgNotice = ReorgCopy.unreachable(.offline, action: "Start")
        }
    }

    func pauseReorg() async {
        reorgPending = .pausing
        reorgNotice = nil
        do {
            let reply = try await client.reorgPause()
            applyReorg(reply, idle: "Pause was not confirmed. The helper sent no status.")
        } catch let error as URLError where error.code == .timedOut {
            reorgNotice = "The Mac stopped waiting after 10 seconds. Pause may still be set. This panel checks every 2 seconds."
            await loadReorg()
        } catch let error as HelperError {
            reorgPending = nil
            reorgNotice = ReorgCopy.unreachable(error, action: "Pause")
        } catch {
            reorgPending = nil
            reorgNotice = ReorgCopy.unreachable(.offline, action: "Pause")
        }
    }

    func resumeReorg() async {
        reorgPending = .resuming
        reorgNotice = nil
        do {
            let reply = try await client.reorgResume()
            applyReorg(reply, idle: "Resume was not confirmed. The helper sent no status.")
        } catch let error as URLError where error.code == .timedOut {
            reorgNotice = "The Mac stopped waiting after 10 seconds. Resume may still be reaching the helper. This panel checks every 2 seconds."
            await loadReorg()
        } catch let error as HelperError {
            reorgPending = nil
            reorgNotice = ReorgCopy.unreachable(error, action: "Resume")
        } catch {
            reorgPending = nil
            reorgNotice = ReorgCopy.unreachable(.offline, action: "Resume")
        }
    }

    private func applyReorg(_ reply: ReorgCall, idle: String) {
        if let code = reply.error {
            reorgPending = nil
            reorgNotice = ReorgCopy.actionFailure(code, fallback: idle)
            return
        }
        if let status = reply.status {
            reorg = status
            reorgStatusFault = nil
            reorgNotice = nil
            absorbReorgPoll()
            return
        }
        reorgPending = nil
        reorgNotice = idle
    }

    /// Drops a local "in process" flag once the helper status shows that step.
    private func absorbReorgPoll() {
        guard let reorg else { return }
        switch reorgPending {
        case .planning(let prefix):
            if reorg.runState == "planning" {
                if reorgNotice == ReorgCopy.planTimedOut { reorgNotice = nil }
            } else if reorg.runState == "plan_ready", reorg.phase == prefix {
                reorgPending = nil
                if reorgNotice == ReorgCopy.planTimedOut { reorgNotice = nil }
            } else if reorg.runState == "idle" {
                reorgPending = nil
                if reorgNotice == ReorgCopy.planTimedOut {
                    reorgNotice = ReorgCopy.planReturnedIdle
                }
            } else {
                reorgPending = nil
            }
        case .starting:
            if reorg.runState == "running" || reorg.runState == "completed" || reorg.runState == "blocked"
                || reorg.runState == "paused" || reorg.runState == "pause_requested" || reorg.runState == "recovering" {
                reorgPending = nil
            }
        case .pausing:
            if reorg.pauseRequested || reorg.runState == "paused" || reorg.runState == "pause_requested" {
                reorgPending = nil
            }
        case .resuming:
            if reorg.runState == "running" || reorg.runState == "completed" || reorg.runState == "blocked" {
                reorgPending = nil
            }
        case nil:
            break
        }
    }

    /// Loads the trim lamp. Opening the panel does not plan or copy.
    func loadTrim() async {
        do {
            trim = try await client.trimStatus()
        } catch {
            trim = nil
        }
    }

    /// Start plans eligible groups and copies. A busy reorg is left untouched.
    func startTrim() async {
        do {
            let reply = try await client.trimStart()
            applyTrim(reply, idle: "Trim did not start.")
        } catch {
            trimNotice = "Trim did not start."
        }
    }

    func pauseTrim() async {
        do {
            let reply = try await client.trimPause()
            applyTrim(reply, idle: "Trim did not pause.")
        } catch {
            trimNotice = "Trim did not pause."
        }
    }

    func continueTrim() async {
        do {
            let reply = try await client.trimContinue()
            applyTrim(reply, idle: "Trim did not continue.")
        } catch {
            trimNotice = "Trim did not continue."
        }
    }

    private func applyTrim(_ reply: TrimCall, idle: String) {
        if reply.error == "busy" {
            trimNotice = "Trim waits until Reorganize is idle."
            return
        }
        if let status = reply.status {
            trim = status
            trimNotice = nil
            return
        }
        trimNotice = idle
    }

    /// Lists the duplicates store. The Photos grid rows stay as they are.
    func loadDuplicates(notice: String? = nil) async {
        do {
            let page = try await client.duplicates()
            duplicateGroups = page.groups
            if let notice {
                duplicateNotice = notice
            }
            await loadDuplicateThumbnails()
        } catch {
            duplicateGroups = []
        }
    }

    /// Lists matching groups, including copies that are still in their folders.
    /// The running helper ignores found=1 and returns the store, so an empty list uses the trim counts.
    func findDuplicates() async {
        await loadTrim()
        do {
            let page = try await client.duplicates(found: true)
            duplicateGroups = page.groups
            await loadDuplicateThumbnails()
            duplicateNotice = DuplicateCopy.findResult(
                groups: page.groups.count,
                eligible: trim?.eligible,
                waiting: trim?.waiting
            )
        } catch {
            duplicateNotice = DuplicateCopy.findUnreachable
        }
    }

    /// Journal-moves one active file into the store. The bytes are not unlinked in place.
    func moveToDuplicates(_ asset: LibraryAsset) async {
        do {
            let reply = try await client.moveToDuplicates(uid: asset.uid)
            if reply.error != nil {
                notice = "The file stayed in the library."
                return
            }
            notice = nil
            await reload()
        } catch {
            notice = "The file stayed in the library."
        }
    }

    func restoreDuplicate(_ asset: LibraryAsset) async {
        do {
            let reply = try await client.restoreAsset(uid: asset.uid)
            if reply.error != nil {
                duplicateNotice = "The file was not restored."
                return
            }
            await loadDuplicates()
            duplicateNotice = "Restored and pinned."
        } catch {
            duplicateNotice = "The file was not restored."
        }
    }

    func setPin(_ asset: LibraryAsset, pinned: Bool) async {
        do {
            let reply = try await client.pinAsset(uid: asset.uid, pinned: pinned)
            if reply.error != nil {
                duplicateNotice = "The pin was not saved."
                return
            }
            await loadDuplicates()
            duplicateNotice = nil
        } catch {
            duplicateNotice = "The pin was not saved."
        }
    }

    /// Unlinks one store file after the dialog named `filename`.
    func purgeDuplicate(_ asset: LibraryAsset, filename: String) async {
        do {
            let reply = try await client.purgeAsset(uid: asset.uid, confirmFilename: filename)
            if reply.error != nil {
                duplicateNotice = "The file was not deleted."
                return
            }
            await loadDuplicates()
            duplicateNotice = nil
        } catch {
            duplicateNotice = "The file was not deleted."
        }
    }

    /// Deletes every file in the store only when `confirm` is exactly DELETE.
    func purgeAllDuplicates(confirm: String) async {
        guard confirm == "DELETE" else {
            duplicateNotice = "Type DELETE to delete every duplicate."
            return
        }
        do {
            let reply = try await client.purgeAllDuplicates(confirm: confirm)
            if reply.error != nil {
                duplicateNotice = "The duplicates were not deleted."
                return
            }
            await loadDuplicates()
            duplicateNotice = nil
        } catch {
            duplicateNotice = "The duplicates were not deleted."
        }
    }

    /// The Delete key does not restore, pin, or purge.
    func deleteKey() {}

    /// Stores the typed name with `name_source` user. The photos stay where they are.
    func renameEvent(uid: String, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let updated = try await client.renameEvent(uid: uid, name: trimmed)
            if let index = events.firstIndex(where: { $0.uid == uid }) {
                events[index] = updated
            } else {
                events.append(updated)
            }
        } catch {
            notice = "The name was not saved."
        }
    }

    /// Reduces the first visible still that has no preview yet. The page order is the folder on screen.
    /// The helper's own queue stays oldest-first. This pass does not wait for it.
    func previewVisibleOne() async -> Bool {
        guard let asset = rows.first(where: needsVisiblePreview) else { return false }
        previewTried.insert(asset.uid)
        guard let url = fileURL(for: asset) else { return true }
        let facts: Data
        do {
            facts = try MacCheckpoint.payloads(for: url).facts
        } catch {
            return true
        }
        do {
            guard try await client.putFacts(uid: asset.uid, body: facts) == 200 else { return true }
        } catch {
            return true
        }
        var updated = asset
        let prefix = String(asset.uid.prefix(2))
        updated.thumbRel = ".zimage/cache/thumbs/\(prefix)/\(asset.uid).jpg"
        if updated.phase == "discovered" || updated.phase == nil {
            updated.phase = "thumbed"
        }
        replace(updated)
        await storePreview(for: updated)
        return true
    }

    private func needsVisiblePreview(_ asset: LibraryAsset) -> Bool {
        if previewTried.contains(asset.uid) { return false }
        return isStill(asset) && asset.thumbRel == nil && (asset.decodeSupport == nil || asset.decodeSupport == "unknown")
    }

    /// Scores one `needs_mac` still. A 404 is ignored. Each uid is tried once this session.
    func checkpointOne() async -> Bool {
        guard let asset = rows.first(where: needsCheckpoint) else { return false }
        checkpointed.insert(asset.uid)
        guard let url = fileURL(for: asset) else { return true }
        let payloads: (facts: Data, detail: Data)
        do {
            payloads = try MacCheckpoint.payloads(for: url)
        } catch {
            return true
        }
        do {
            let factsStatus = try await client.putFacts(uid: asset.uid, body: payloads.facts)
            if factsStatus == 404 { return true }
            _ = try await client.putDetail(uid: asset.uid, body: payloads.detail)
        } catch {
            return true
        }
        return true
    }

    private func needsCheckpoint(_ asset: LibraryAsset) -> Bool {
        if checkpointed.contains(asset.uid) { return false }
        guard isStill(asset) else { return false }
        if asset.detailSource == "needs_mac" { return true }
        return asset.decodeSupport == "needs_mac" && asset.detailScore == nil
    }

    private func replace(_ asset: LibraryAsset) {
        if let index = rows.firstIndex(where: { $0.uid == asset.uid }) {
            rows[index] = asset
        }
        if let index = reviewRows.firstIndex(where: { $0.uid == asset.uid }) {
            reviewRows[index] = asset
        }
    }

    /// Scales the cell. The helper thumbnail URL stays the same.
    func setPreviewPoints(_ points: Double) {
        previewPoints = PreviewSize.clamped(points)
    }

    func openSelected() {
        guard let selectedUID, let asset = rows.first(where: { $0.uid == selectedUID }) else { return }
        openInEditor(asset)
    }

    /// A still opens in ZImage. A video opens in QuickTime Player.
    func openPrimary(_ asset: LibraryAsset) {
        if isVideo(asset) {
            openInQuickTime(asset)
            return
        }
        openInEditor(asset)
    }

    func openInQuickTime(_ asset: LibraryAsset) {
        guard isVideo(asset), let url = fileURL(for: asset) else { return }
        selectedUID = asset.uid
        if let openVideo {
            openVideo(url)
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: LibraryItemMenu.quickTimeBundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
    }

    var quickTimeAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: LibraryItemMenu.quickTimeBundleID) != nil
    }

    func fileURL(for asset: LibraryAsset) -> URL? {
        guard let relPath = asset.relPath else { return nil }
        return libraryRoot.appending(path: relPath)
    }

    func openInEditor(_ asset: LibraryAsset) {
        guard canOpenInEditor(asset), let url = fileURL(for: asset) else { return }
        EditorHandoff.openFile(url, with: openFile)
    }

    func showInFinder(_ asset: LibraryAsset) {
        guard let url = fileURL(for: asset) else { return }
        selectedUID = asset.uid
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Applications that can open this file. ZImage is first for a still. QuickTime Player is first for a video.
    func openWithTargets(for asset: LibraryAsset) -> [LibraryOpenTarget] {
        let others = fileURL(for: asset).map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
        let zimage = NSWorkspace.shared.urlForApplication(withBundleIdentifier: EditorHandoff.editorBundleID)
        let names = { (url: URL) in FileManager.default.displayName(atPath: url.path) }
        if isVideo(asset) {
            let quickTime = NSWorkspace.shared.urlForApplication(withBundleIdentifier: LibraryItemMenu.quickTimeBundleID)
            return LibraryItemMenu.videoApplications(quickTime: quickTime, others: others, editor: zimage, names: names)
        }
        return LibraryItemMenu.applications(zimage: zimage, others: others, names: names)
    }

    func open(_ asset: LibraryAsset, with application: URL) {
        selectedUID = asset.uid
        if isZImageApplication(application) {
            openInEditor(asset)
            return
        }
        guard let url = fileURL(for: asset) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
    }

    func sizeLabel(for asset: LibraryAsset) -> String {
        guard let url = fileURL(for: asset) else { return LibraryItemMenu.sizeUnavailable }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return LibraryItemMenu.sizeLabel(bytes: bytes)
    }

    private func isZImageApplication(_ application: URL) -> Bool {
        if let bundle = Bundle(url: application), bundle.bundleIdentifier == EditorHandoff.editorBundleID {
            return true
        }
        return application.standardizedFileURL.path == NSWorkspace.shared.urlForApplication(withBundleIdentifier: EditorHandoff.editorBundleID)?.standardizedFileURL.path
    }

    func canOpenInEditor(_ asset: LibraryAsset) -> Bool {
        if isVideo(asset) { return false }
        let media = asset.mediaClass?.lowercased() ?? ""
        let ext = asset.ext?.lowercased() ?? ""
        if media == "pdf" || ext == "pdf" { return true }
        if media == "image" || media == "raw" { return true }
        return false
    }

    func isVideo(_ asset: LibraryAsset) -> Bool {
        if asset.mediaClass?.lowercased() == "video" { return true }
        let ext = asset.ext?.lowercased() ?? ""
        return LibraryItemMenu.videoExtensions.contains(ext)
    }

    func filename(for asset: LibraryAsset) -> String {
        guard let relPath = asset.relPath else { return asset.uid }
        return URL(fileURLWithPath: relPath).lastPathComponent
    }

    /// True while a visible still has no preview yet. `unknown` is a row the helper is allowed to try again.
    var awaitsPreviews: Bool {
        rows.contains { asset in
            isStill(asset) && asset.thumbRel == nil && (asset.decodeSupport == nil || asset.decodeSupport == "unknown")
        }
    }

    /// Shown under the slider while the page is still squares, and after oversized files stay empty.
    var previewStatus: String? {
        if awaitsPreviews {
            return "Reduced previews are still being written. These squares fill in as each one is stored."
        }
        if rows.contains(where: { isStill($0) && $0.thumbRel == nil && $0.decodeSupport != nil }) {
            return "Some photos are over 32 million pixels or could not be reduced. Those squares stay empty."
        }
        return nil
    }

    func cellBadge(for asset: LibraryAsset) -> String? {
        if isVideo(asset) { return "Video" }
        if isStill(asset), asset.thumbRel == nil, let support = asset.decodeSupport, support != "unknown" {
            return "No preview"
        }
        return nil
    }

    private func isStill(_ asset: LibraryAsset) -> Bool {
        let media = asset.mediaClass?.lowercased() ?? ""
        return media == "image" || media == "raw"
    }

    private func loadThumbnails() async {
        for asset in rows {
            if asset.thumbRel == nil {
                cells[asset.uid] = LibraryGridCell(
                    imageData: nil,
                    thumbnailURL: nil,
                    badge: cellBadge(for: asset),
                    placeholder: true
                )
                continue
            }
            if fetchedThumbs.contains(asset.uid) { continue }
            let url = thumbnailURL(uid: asset.uid)
            thumbnailRequestCount += 1
            do {
                let data = try await client.thumbnail(uid: asset.uid)
                fetchedThumbs.insert(asset.uid)
                cells[asset.uid] = LibraryGridCell(
                    imageData: data,
                    thumbnailURL: url,
                    badge: cellBadge(for: asset),
                    placeholder: false
                )
            } catch {
                cells[asset.uid] = LibraryGridCell(
                    imageData: nil,
                    thumbnailURL: nil,
                    badge: cellBadge(for: asset),
                    placeholder: true
                )
            }
        }
    }

    private func storePreview(for asset: LibraryAsset) async {
        let url = thumbnailURL(uid: asset.uid)
        thumbnailRequestCount += 1
        do {
            let data = try await client.thumbnail(uid: asset.uid)
            fetchedThumbs.insert(asset.uid)
            cells[asset.uid] = LibraryGridCell(
                imageData: data,
                thumbnailURL: url,
                badge: cellBadge(for: asset),
                placeholder: false
            )
        } catch {
            cells[asset.uid] = LibraryGridCell(
                imageData: nil,
                thumbnailURL: nil,
                badge: cellBadge(for: asset),
                placeholder: true
            )
        }
    }

    private func loadDuplicateThumbnails() async {
        for asset in duplicateGroups.flatMap(\.members) {
            if asset.thumbRel == nil {
                cells[asset.uid] = LibraryGridCell(
                    imageData: nil,
                    thumbnailURL: nil,
                    badge: cellBadge(for: asset),
                    placeholder: true
                )
                continue
            }
            if fetchedDuplicateThumbs.contains(asset.uid) { continue }
            let url = thumbnailURL(uid: asset.uid)
            duplicateThumbCount += 1
            do {
                let data = try await client.thumbnail(uid: asset.uid)
                fetchedDuplicateThumbs.insert(asset.uid)
                cells[asset.uid] = LibraryGridCell(
                    imageData: data,
                    thumbnailURL: url,
                    badge: cellBadge(for: asset),
                    placeholder: false
                )
            } catch {
                cells[asset.uid] = LibraryGridCell(
                    imageData: nil,
                    thumbnailURL: nil,
                    badge: cellBadge(for: asset),
                    placeholder: true
                )
            }
        }
    }

    private func thumbnailURL(uid: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = client.credentials.host
        parts.port = client.credentials.port
        parts.path = "/v1/assets/\(uid)/thumbnail"
        return parts.url
    }
}
