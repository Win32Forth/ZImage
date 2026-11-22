import AppKit
import Darwin
import Foundation
import SwiftUI

/// Photos lists stills and videos together. Review lists the park. Duplicates lists the store. The path stays `Photos/_Duplicates`.
enum LibrarySidebar {
    static let items = ["Photos", "Review", "Duplicates"]

    /// A folder click shows that folder's stills and videos.
    static func sectionAfterTreePick(_: String?) -> String {
        "Photos"
    }

    static func media(for _: String) -> String {
        "photo"
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

/// Right-click actions for one library file. Edit Image is the first command for a still.
/// A video leads with QuickTime Player.
enum LibraryItemMenu {
    static let editImage = "Edit Image"
    static let openWithQuickTime = "Open with QuickTime Player"
    static let quickTimeBundleID = "com.apple.QuickTimePlayerX"
    static let showInFinder = "Show in Finder"
    static let openWith = "Open With"
    static let rename = "Rename"
    static let sizeUnavailable = "Size unavailable"
    static let noDate = "No date"

    static let commandOrder = [editImage, showInFinder, openWith]
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

func cleanFolderNotice(removed: Int, kept: Int) -> String {
    switch (removed, kept) {
    case (0, 0):
        return "This folder has no leftover records."
    case (_, 0):
        return removed == 1 ? "Removed 1 leftover record." : "Removed \(removed) leftover records."
    case (0, 1):
        return "1 record was left in place."
    case (0, _):
        return "\(kept) records were left in place."
    default:
        let removedLine = removed == 1 ? "Removed 1 leftover record." : "Removed \(removed) leftover records."
        let keptLine = kept == 1 ? "1 record was left in place." : "\(kept) records were left in place."
        return removedLine + " " + keptLine
    }
}

func rescanProgressCaption(_ meter: TouchupMeter) -> String {
    if meter.total <= 0 {
        if meter.done > 0 {
            return "\(meter.title), \(DuplicateCopy.count(meter.done)) files"
        }
        return meter.title
    }
    return "\(meter.title), \(DuplicateCopy.count(meter.done)) of \(DuplicateCopy.count(meter.total))"
}

func rescanFinishedNotice(added: Int, removed: Int) -> String {
    switch (added, removed) {
    case (0, 0):
        return "No files were added or removed."
    case (_, 0):
        return added == 1 ? "Added 1 file." : "Added \(added) files."
    case (0, _):
        return removed == 1 ? "Removed 1 deleted file." : "Removed \(removed) deleted files."
    default:
        let add = added == 1 ? "Added 1 file." : "Added \(added) files."
        let drop = removed == 1 ? "Removed 1 deleted file." : "Removed \(removed) deleted files."
        return add + " " + drop
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

    /// The parked shelf. A folder named `_Removed` anywhere else is not this shelf.
    static func isRemovedShelf(_ folder: String) -> Bool {
        folder == "Photos/_Removed"
    }
}

/// Deletes the files parked in `Photos/_Removed`. The folder itself stays.
enum RemovedShelf {
    struct Result: Equatable {
        var deleted = 0
        var failed = 0
        var missing = false
    }

    static func deleteContents(libraryRoot: URL) -> Result {
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let shelf = root
            .appendingPathComponent("Photos", isDirectory: true)
            .appendingPathComponent("_Removed", isDirectory: true)
        let resolved = shelf.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(rootPrefix),
              resolved.lastPathComponent == "_Removed",
              resolved.deletingLastPathComponent().lastPathComponent == "Photos" else {
            return Result(failed: 1)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return Result(missing: true)
        }
        let shelfPrefix = resolved.path.hasSuffix("/") ? resolved.path : resolved.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: resolved,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return Result(failed: 1)
        }
        var files: [URL] = []
        var directories: [URL] = []
        for case let item as URL in enumerator {
            let link = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(shelfPrefix) else {
                enumerator.skipDescendants()
                continue
            }
            if link {
                files.append(item)
                enumerator.skipDescendants()
                continue
            }
            let resolvedItem = item.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedItem.hasPrefix(shelfPrefix) else {
                enumerator.skipDescendants()
                continue
            }
            let directory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if directory {
                directories.append(item)
            } else {
                files.append(item)
            }
        }
        var result = Result()
        for file in files {
            do {
                try FileManager.default.removeItem(at: file)
                result.deleted += 1
            } catch {
                result.failed += 1
            }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if (try? FileManager.default.removeItem(at: directory)) == nil {
                result.failed += 1
            }
        }
        return result
    }
}

/// Moves selected files into a folder the user names.
/// The named folder is created under Photos. The subfolder box puts it under the folder on screen.
enum FolderMove {
    struct Outcome: Equatable {
        var moved = 0
        var stayed = 0
        var directories: [String] = []
        /// Where each file is after the step. A failed move is left out.
        var placed: [String] = []
    }

    static func folderName(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "." || trimmed == ".." { return nil }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("\0") { return nil }
        if trimmed.unicodeScalars.contains(where: { $0.value < 32 }) { return nil }
        if trimmed == "_Removed" || trimmed == "_Duplicates" || trimmed == "_Review" { return nil }
        return trimmed
    }

    struct FileOutcome: Equatable {
        var moved = 0
        var stayed = 0
        var directories: [URL] = []
    }

    /// Where a Disk file would land. Unchecked uses the opened root, the way Server uses Photos.
    /// Checked uses the folder on screen. The file must already be inside that folder.
    static func diskDestination(root: URL, openFolder: URL, file: URL, folderName raw: String, subfolder: Bool) -> URL? {
        guard let name = folderName(raw) else { return nil }
        let rootKey = FolderEntry.cacheKey(for: root)
        let openKey = FolderEntry.cacheKey(for: openFolder)
        let fileKey = FolderEntry.cacheKey(for: file)
        guard openKey == rootKey || openKey.hasPrefix(rootKey + "/") else { return nil }
        guard fileKey.hasPrefix(openKey + "/") else { return nil }
        let base = subfolder ? openFolder : root
        let dest = base.appendingPathComponent(name, isDirectory: true)
        let destKey = FolderEntry.cacheKey(for: dest)
        guard destKey == rootKey || destKey.hasPrefix(rootKey + "/") else { return nil }
        return dest
    }

    /// Moves Disk files into the named folders. A file already there stays put.
    static func perform(files: [(source: URL, directory: URL)]) -> FileOutcome {
        var outcome = FileOutcome()
        var seen: [String] = []
        for item in files {
            let parentKey = FolderEntry.cacheKey(for: item.source.deletingLastPathComponent())
            let directoryKey = FolderEntry.cacheKey(for: item.directory)
            if parentKey == directoryKey {
                outcome.stayed += 1
                continue
            }
            guard let claimed = claim(directory: item.directory, fileName: item.source.lastPathComponent) else {
                outcome.stayed += 1
                continue
            }
            do {
                try FileManager.default.createDirectory(at: item.directory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item.source, to: claimed)
                outcome.moved += 1
                if !seen.contains(directoryKey) {
                    seen.append(directoryKey)
                    outcome.directories.append(item.directory)
                }
            } catch {
                outcome.stayed += 1
            }
        }
        return outcome
    }

    /// Directory under the library root.
    /// Unchecked lands in `Photos/<name>`. Checked lands in the open folder.
    static func directory(displayFolder: String, fileRelPath: String, folderName raw: String, subfolder: Bool = false) -> String? {
        guard let name = folderName(raw) else { return nil }
        guard fileRelPath == displayFolder || fileRelPath.hasPrefix(displayFolder + "/") else { return nil }
        let fileParts = fileRelPath.split(separator: "/").map(String.init)
        guard fileParts.count >= 2, fileParts.first == "Photos",
              fileParts.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        let openParts = displayFolder.split(separator: "/").map(String.init)
        guard openParts.first == "Photos", openParts.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        if subfolder {
            return displayFolder + "/" + name
        }
        return "Photos/\(name)"
    }

    /// The open folder, then any destination that sits outside it.
    static func rescanPrefixes(displayFolder: String, destinations: [String]) -> [String] {
        var prefixes = [displayFolder]
        for dest in destinations {
            let covered = prefixes.contains { dest == $0 || dest.hasPrefix($0 + "/") }
            if !covered {
                prefixes.append(dest)
            }
        }
        return prefixes
    }

    static func finishedNotice(name: String, outcome: Outcome) -> String {
        if outcome.moved == 0 {
            return outcome.stayed == 1 ? "The file stayed where it is." : "The files stayed where they are."
        }
        let place = outcome.directories.count == 1 ? (outcome.directories[0]) : name
        if outcome.stayed == 0 {
            return outcome.moved == 1 ? "Moved 1 file to \(place)." : "Moved \(outcome.moved.formatted()) files to \(place)."
        }
        let stayed = outcome.stayed == 1 ? "1 stayed." : "\(outcome.stayed.formatted()) stayed."
        return "Moved \(outcome.moved.formatted()) files to \(place). \(stayed)"
    }

    /// Moves each file into its destination directory. An existing name gets `-2`, `-3`, and so on.
    static func perform(libraryRoot: URL, items: [(sourceRel: String, destDir: String)]) -> Outcome {
        var outcome = Outcome()
        var seen: [String] = []
        for item in items {
            guard let source = fileInsideLibrary(libraryRoot: libraryRoot, relative: item.sourceRel),
                  let directory = directoryInsideLibrary(libraryRoot: libraryRoot, relative: item.destDir) else {
                outcome.stayed += 1
                continue
            }
            // Already in that folder. A second move would rename it to name-2.
            if (item.sourceRel as NSString).deletingLastPathComponent == item.destDir {
                outcome.stayed += 1
                outcome.placed.append(item.sourceRel)
                continue
            }
            guard let claimed = claim(directory: directory, fileName: source.lastPathComponent) else {
                outcome.stayed += 1
                continue
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source, to: claimed)
                outcome.moved += 1
                outcome.placed.append(item.destDir + "/" + claimed.lastPathComponent)
                if !seen.contains(item.destDir) {
                    seen.append(item.destDir)
                }
            } catch {
                outcome.stayed += 1
            }
        }
        outcome.directories = seen
        return outcome
    }

    /// Writes a new file under Photos. An existing name gets `-2`. The relative path is returned.
    static func writeNewFile(libraryRoot: URL, directory: String, fileName: String, data: Data) -> String? {
        guard !data.isEmpty, data.count <= 2_000_000 else { return nil }
        guard let folder = directoryInsideLibrary(libraryRoot: libraryRoot, relative: directory),
              let claimed = claim(directory: folder, fileName: fileName) else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: claimed, options: .atomic)
            return directory + "/" + claimed.lastPathComponent
        } catch {
            return nil
        }
    }

    private static func claim(directory: URL, fileName: String) -> URL? {
        guard fileName != ".", fileName != "..", !fileName.contains("/") else { return nil }
        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension
        for number in 1..<1000 {
            let name: String
            if number == 1 {
                name = fileName
            } else if ext.isEmpty {
                name = "\(stem)-\(number)"
            } else {
                name = "\(stem)-\(number).\(ext)"
            }
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func fileInsideLibrary(libraryRoot: URL, relative: String) -> URL? {
        guard let parent = directoryInsideLibrary(libraryRoot: libraryRoot, relative: (relative as NSString).deletingLastPathComponent) else {
            return nil
        }
        let name = (relative as NSString).lastPathComponent
        guard name != ".", name != "..", !name.contains("/") else { return nil }
        return parent.appendingPathComponent(name)
    }

    /// Resolves existing components. A folder that is not on disk yet stays under its parent.
    private static func directoryInsideLibrary(libraryRoot: URL, relative: String) -> URL? {
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.first == "Photos", parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            return nil
        }
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var url = root
        for part in parts {
            url = url.appendingPathComponent(part, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(rootPrefix) else { return nil }
                url = resolved
            }
        }
        guard url.path.hasPrefix(rootPrefix) else { return nil }
        return url
    }
}

/// Two stills that can be joined, or the sentence that says why not.
enum MergePairLookup {
    case ready(first: URL, second: URL, directory: URL, folder: String)
    case refused(String)
}

/// One page of the catalog grid. Cells scale the stored preview JPEG.
@MainActor
@Observable
final class LibraryBrowser {
    static let pageLimit = 200

    private var client: HelperClient
    let session: LibrarySession
    var notice: String?
    /// True while Remove from library is moving the current batch.
    private(set) var removalBusy = false
    /// True while Set date is writing the date and moving the current batch.
    private(set) var dateBusy = false
    /// True while Organize is reading the open folder.
    private(set) var organizeBusy = false
    /// The Organize bar. Nil hides it.
    private(set) var organizeMeter: TouchupMeter?
    /// True while Clean is deleting empty folders, or leftover catalog rows are being dropped.
    private(set) var cleanBusy = false
    /// True while Rescan is walking the displayed folder.
    private(set) var rescanBusy = false
    /// True while Move to Folder is moving the current batch, or a folder rename is writing the catalog.
    private(set) var moveBusy = false
    /// True while the merged TIFF is being written. The preview does not set this.
    private(set) var mergeBusy = false
    /// True while Build previews is storing previews for the folder on screen.
    private(set) var folderPreviewBuildBusy = false
    /// The line under Build. Nil until the button has been used.
    private(set) var folderPreviewBuildNote: String?
    /// The folder list that owns the build. A newer list leaves this pass.
    @ObservationIgnored private var previewBuildKey: String?
    /// Bumped after Move to Folder writes a directory, so the folder tree rereads that parent.
    private(set) var folderTreeRevision = 0
    /// Parents whose child lists are stale. Empty until a move lands files in a directory.
    private(set) var folderTreeParents: [String] = []
    /// The folder walk bar. Nil hides it.
    private(set) var rescanMeter: TouchupMeter?
    private var rescanGeneration = 0
    private(set) var rows: [LibraryAsset] = []
    private(set) var reviewRows: [LibraryAsset] = []
    private(set) var events: [LibraryEvent] = []
    private(set) var reorg: ReorgStatus?
    var reorgPrefix = "Photos"
    /// Relative folder shown in the Photos and Videos grids. Review and Duplicates ignore it.
    var displayFolder = DisplayFolder.root
    /// Text in the Server folder name field. Find copies this into `nameFilter`.
    var nameQuery = ""
    /// Applied name filter. The helper matches it inside the displayed folder.
    var nameFilter = ""
    /// Page of the folder photo grid. Zero is the first 200 photos.
    private(set) var folderPage = 0
    /// Photos in the open folder, once every page has been read. Nil while that count is unfinished.
    private(set) var folderPhotoTotal: Int?
    /// True while later pages are still being read.
    private(set) var folderPageCounting = false
    private var stillPages: [[LibraryAsset]] = []
    private var pageCursors: [String?] = []
    private var folderVideos: [LibraryAsset] = []
    private var folderListKey = ""
    /// The page a click asked for before it had been read. `Int.max` means the last page.
    private var requestedPage: Int?
    /// Photos, Review, or Duplicates. Previous and Next walk this list.
    var librarySection = "Photos"
    private(set) var reorgNotice: String?
    private(set) var reorgPending: ReorgPending?
    /// Seconds the panel has been counting, stepped every status check.
    private(set) var reorgTick = 0
    private(set) var reorgStatusFault: String?
    private(set) var trim: TrimStatus?
    private(set) var trimNotice: String?
    private(set) var duplicateGroups: [DuplicateGroup] = []
    private(set) var scan: DuplicateScan?
    /// Latest startup task from the helper memory buffer. The toolbar reads this in Server mode.
    private(set) var helperPass: DuplicateScan?
    private(set) var duplicateNotice: String?
    private(set) var duplicateThumbCount = 0
    private(set) var cells: [String: LibraryGridCell] = [:]
    private(set) var previewPoints: Double = PreviewSize.defaultPoints
    private(set) var thumbnailRequestCount = 0
    var libraryRoot: URL
    var selectedUID: String?
    /// Shift-click in a folder grid fills this from the anchor through the clicked photo.
    var selectedUIDs: Set<String> = []
    /// Click order. The first id is the left or the top when two photos are merged.
    var selectionOrder: [String] = []
    var selectionAnchorUID: String?
    /// Edited folder JPEG, preferred over the helper thumbnail.
    var editedJPEG: [String: Data] = [:]
    var selectedEventUID: String?
    var openFile: (URL, String) -> Void
    /// Opens a catalog still with its asset id, so a flattened TIFF can be the edit base immediately.
    var openCatalogFile: ((URL, String, String) -> Void)?
    /// Double-click plays the movie here. The QuickTime menu item does not use this.
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
        previewBuildKey = nil
        folderPreviewBuildBusy = false
        folderPreviewBuildNote = nil
        selectedUID = nil
        selectedUIDs = []
        selectionOrder = []
        selectionAnchorUID = nil
        editedJPEG = [:]
        selectedEventUID = nil
        notice = nil
        rescanGeneration += 1
        rescanBusy = false
        moveBusy = false
        organizeBusy = false
        cleanBusy = false
        organizeMeter = nil
        mergeBusy = false
        rescanMeter = nil
        reorg = nil
        reorgNotice = nil
        reorgPending = nil
        reorgStatusFault = nil
        reorgPrefix = "Photos"
        displayFolder = DisplayFolder.root
        nameQuery = ""
        nameFilter = ""
        resetFolderPages()
        trim = nil
        trimNotice = nil
        duplicateGroups = []
        duplicateNotice = nil
        fetchedDuplicateThumbs = []
    }

    func applyNameFilter() {
        nameFilter = nameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearNameFilter() {
        nameQuery = ""
        nameFilter = ""
    }

    /// `photo` lists stills and videos in the selected folder. `video` is the movie list alone.
    func reload(media: String? = nil) async {
        let folder = (media == "photo" || media == "video") ? displayFolder : nil
        let name = nameFilter.isEmpty ? nil : nameFilter
        if media == "photo" {
            await reloadFolderGrid(under: folder, name: name)
            return
        }
        await session.refresh(media: media, under: folder, name: name)
        if Task.isCancelled { return }
        var loaded = Array(session.rows.prefix(Self.pageLimit))
        if media == "video" {
            loaded = loaded.filter { isVideo($0) }.sorted { captureKey($0) < captureKey($1) }
        }
        rows = loaded
        trimSelectionToRows()
        await loadThumbnails()
    }

    var showsFolderPager: Bool {
        if let folderPhotoTotal, !folderPageCounting { return folderPhotoTotal > FolderPage.limit }
        return stillPages.count > 1
    }

    var folderPagerTitle: String {
        if let folderPhotoTotal, !folderPageCounting {
            return "\(folderPhotoTotal.formatted()) photos"
        }
        return "Counting photos…"
    }

    var folderPagerRange: String {
        guard stillPages.indices.contains(folderPage) else { return "" }
        return FolderPage.range(
            page: folderPage,
            countOnPage: stillPages[folderPage].count,
            total: folderPageCounting ? nil : folderPhotoTotal
        )
    }

    var folderPageCanGoBack: Bool { folderPage > 0 }

    var folderPageCanGoForward: Bool {
        if folderPage + 1 < stillPages.count { return true }
        return folderPageCounting
    }

    func showFirstFolderPage() async {
        await showFolderPage(0)
    }

    func showPreviousFolderPage() async {
        guard folderPage > 0 else { return }
        await showFolderPage(folderPage - 1)
    }

    func showNextFolderPage() async {
        if folderPage + 1 < stillPages.count {
            await showFolderPage(folderPage + 1)
            return
        }
        guard folderPageCounting else { return }
        requestedPage = folderPage + 1
    }

    func showLastFolderPage() async {
        if !folderPageCounting, let total = folderPhotoTotal {
            await showFolderPage(FolderPage.pageCount(total: total) - 1)
            return
        }
        requestedPage = .max
    }

    private func showFolderPage(_ index: Int) async {
        guard stillPages.indices.contains(index) else { return }
        folderPage = index
        applyFolderRows()
        await loadThumbnails()
    }

    private func reloadFolderGrid(under folder: String?, name: String?) async {
        let key = "photo|\(folder ?? "")|\(name ?? "")"
        let fresh = key != folderListKey
        if fresh {
            previewBuildKey = nil
            folderPreviewBuildBusy = false
            folderPreviewBuildNote = nil
            folderListKey = key
            folderPage = 0
            requestedPage = nil
            stillPages = []
            pageCursors = []
            folderVideos = []
            folderPhotoTotal = nil
            folderPageCounting = false
            rows = []
        }
        if name != nil {
            notice = "Searching this folder…"
        }
        var dropped = false
        if fresh || name != nil {
            let savedPage = folderPage
            await walkFolderPhotos(under: folder, name: name, key: key)
            if folderListKey != key || Task.isCancelled { return }
            if !fresh {
                folderPage = min(savedPage, max(0, stillPages.count - 1))
                applyFolderRows()
            }
        } else {
            let outcome = await refreshVisibleFolderPage(under: folder, name: name, key: key)
            dropped = outcome == .dropped
            // An empty cursor page cannot prove the earlier pages are gone. Read the folder again.
            if dropped, folderListKey.isEmpty, !Task.isCancelled {
                folderListKey = key
                await walkFolderPhotos(under: folder, name: name, key: key)
            }
        }
        guard folderListKey == key, !Task.isCancelled else { return }
        if name != nil { notice = nil }
        if fresh || dropped { trimSelectionToRows() }
        await loadThumbnails()
    }

    /// Reads every photo page. The first 200 are shown as soon as they arrive.
    /// A newer folder load owns `folderListKey`. This walk stops without writing over it.
    private func walkFolderPhotos(under folder: String?, name: String?, key: String) async {
        stillPages = []
        pageCursors = []
        folderPhotoTotal = nil
        folderPageCounting = true
        var cursor: String?
        var seenCursors: Set<String> = []
        var seenUIDs: Set<String> = []
        var buffer: [LibraryAsset] = []
        var tailCursor: String?
        var counted = 0
        var failed = false
        while folderListKey == key && !Task.isCancelled {
            let page: LibraryPage
            do {
                page = try await client.assets(media: "photo", under: folder, name: name, cursor: cursor)
            } catch {
                if folderListKey == key {
                    failed = stillPages.isEmpty && buffer.isEmpty
                }
                break
            }
            if folderListKey != key || Task.isCancelled { break }
            if stillPages.isEmpty && buffer.isEmpty {
                session.markReachable()
            }
            let requestCursor = cursor
            for row in page.rows {
                guard !isVideo(row), seenUIDs.insert(row.uid).inserted else { continue }
                if let name, !FolderNameFilter.matches(FolderNameFilter.fileName(in: row.relPath ?? ""), query: name) {
                    continue
                }
                if buffer.isEmpty { tailCursor = requestCursor }
                buffer.append(row)
                counted += 1
                if buffer.count == FolderPage.limit {
                    stillPages.append(buffer)
                    pageCursors.append(tailCursor)
                    buffer.removeAll()
                    tailCursor = nil
                    await publishArrivedPage(key: key)
                    if folderListKey != key || Task.isCancelled { break }
                }
            }
            if folderListKey != key || Task.isCancelled { break }
            let next = page.nextCursor
            if next.isEmpty || page.rows.isEmpty || !seenCursors.insert(next).inserted { break }
            cursor = next
        }
        if folderListKey != key || Task.isCancelled {
            abandonFolderList(key: key, name: name)
            return
        }
        if failed {
            folderPageCounting = false
            await session.refresh(media: "photo", under: folder, name: name)
            guard folderListKey == key, !Task.isCancelled else {
                abandonFolderList(key: key, name: name)
                return
            }
            rows = Array(session.rows.filter { !isVideo($0) }.prefix(FolderPage.limit))
            return
        }
        if !buffer.isEmpty {
            stillPages.append(buffer)
            pageCursors.append(tailCursor)
        }
        let videos = await loadFolderVideos(under: folder, name: name)
        guard folderListKey == key, !Task.isCancelled else {
            abandonFolderList(key: key, name: name)
            return
        }
        folderVideos = videos
        folderPhotoTotal = counted
        folderPageCounting = false
        if let requestedPage {
            if requestedPage == .max {
                folderPage = max(0, stillPages.count - 1)
            } else if stillPages.indices.contains(requestedPage) {
                folderPage = requestedPage
            }
            self.requestedPage = nil
        } else if folderPage >= stillPages.count {
            folderPage = max(0, stillPages.count - 1)
        }
        applyFolderRows()
    }

    private func publishArrivedPage(key: String) async {
        guard folderListKey == key, !Task.isCancelled else { return }
        let arrived = stillPages.count - 1
        let show = folderPage == arrived || (folderPage == 0 && arrived == 0) || requestedPage == arrived
        guard show else { return }
        if requestedPage == arrived {
            folderPage = arrived
            requestedPage = nil
        }
        applyFolderRows()
        await loadThumbnails()
    }

    /// A failed fetch keeps the page. An empty page drops the cached list so the caller can read the folder again.
    private enum FolderPageRefresh {
        case kept
        case replaced
        case dropped
    }

    private func refreshVisibleFolderPage(under folder: String?, name: String?, key: String) async -> FolderPageRefresh {
        guard name == nil, stillPages.indices.contains(folderPage) else { return .kept }
        let pageIndex = folderPage
        let cursor = pageCursors.indices.contains(pageIndex) ? pageCursors[pageIndex] : nil
        let stills: [LibraryAsset]
        let nextCursor: String
        do {
            let page = try await client.assets(media: "photo", under: folder, name: nil, cursor: cursor)
            guard folderListKey == key, !Task.isCancelled else { return .kept }
            session.markReachable()
            stills = page.rows.filter { !isVideo($0) }
            nextCursor = page.nextCursor
        } catch {
            return .kept
        }
        guard stillPages.indices.contains(pageIndex), folderListKey == key else { return .kept }
        if stills.isEmpty {
            folderListKey = ""
            stillPages = []
            pageCursors = []
            folderVideos = []
            folderPhotoTotal = 0
            folderPageCounting = false
            folderPage = 0
            requestedPage = nil
            rows = []
            return .dropped
        }
        let previous = Dictionary(uniqueKeysWithValues: stillPages[pageIndex].map { ($0.uid, $0) })
        stillPages[pageIndex] = stills.map { fresh in
            guard fresh.thumbRel == nil, let kept = previous[fresh.uid]?.thumbRel else { return fresh }
            var merged = fresh
            merged.thumbRel = kept
            return merged
        }
        let ended = stills.count < FolderPage.limit || nextCursor.isEmpty
        if ended {
            let drop = pageIndex + 1
            if drop < stillPages.count {
                stillPages.removeSubrange(drop...)
            }
            if drop < pageCursors.count {
                pageCursors.removeSubrange(drop...)
            }
            folderPhotoTotal = stillPages.reduce(0) { $0 + $1.count }
            folderPageCounting = false
            if folderPage >= stillPages.count {
                folderPage = max(0, stillPages.count - 1)
            }
        }
        if pageIndex == 0 {
            let videos = await loadFolderVideos(under: folder, name: nil)
            guard folderListKey == key, !Task.isCancelled else { return .replaced }
            folderVideos = videos
        }
        applyFolderRows()
        return .replaced
    }

    /// Videos on the first photo page. A name walks every video page. An open folder keeps the first 200.
    private func loadFolderVideos(under folder: String?, name: String?) async -> [LibraryAsset] {
        var matched: [LibraryAsset] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var seenUIDs: Set<String> = []
        let walkAll = name != nil
        while !Task.isCancelled {
            let page: LibraryPage
            do {
                page = try await client.assets(media: "video", under: folder, name: name, cursor: cursor)
            } catch {
                break
            }
            for row in page.rows where isVideo(row) && seenUIDs.insert(row.uid).inserted {
                if let name, !FolderNameFilter.matches(FolderNameFilter.fileName(in: row.relPath ?? ""), query: name) {
                    continue
                }
                matched.append(row)
            }
            let next = page.nextCursor
            if !walkAll || next.isEmpty || page.rows.isEmpty || !seenCursors.insert(next).inserted { break }
            cursor = next
        }
        return matched
    }

    private func applyFolderRows() {
        let page = stillPages.isEmpty ? 0 : min(folderPage, stillPages.count - 1)
        folderPage = page
        let stills = stillPages.indices.contains(page) ? stillPages[page] : []
        let videos = page == 0 ? folderVideos : []
        rows = (stills + videos).sorted { left, right in
            (left.relPath ?? left.uid).localizedStandardCompare(right.relPath ?? right.uid) == .orderedAscending
        }
    }

    /// Drops an unfinished count so the next open reads the folder again.
    /// A newer load owns the key and is left alone.
    private func abandonFolderList(key: String, name: String?) {
        guard folderListKey == key else { return }
        folderListKey = ""
        folderPageCounting = false
        if name != nil { notice = nil }
    }

    private func resetFolderPages() {
        folderPage = 0
        folderPhotoTotal = nil
        folderPageCounting = false
        stillPages = []
        pageCursors = []
        folderVideos = []
        folderListKey = ""
        requestedPage = nil
    }

    private func trimSelectionToRows() {
        let alive = Set(rows.map(\.uid))
        selectedUIDs = selectedUIDs.intersection(alive)
        selectionOrder = selectionOrder.filter { selectedUIDs.contains($0) }
        if let selectedUID, !alive.contains(selectedUID) {
            self.selectedUID = nil
        }
        if let anchor = selectionAnchorUID, !selectedUIDs.contains(anchor) {
            selectionAnchorUID = selectedUID
        }
    }

    private func captureKey(_ asset: LibraryAsset) -> String {
        let time = asset.captureTime ?? ""
        return time.isEmpty ? "9999" : time
    }

    /// Loads one reduced JPEG for the selected Review row. The grid request counter stays as it is.
    func ensurePreview(for uid: String?) async {
        guard let uid else { return }
        if cells[uid]?.imageData != nil { return }
        let asset = reviewRows.first { $0.uid == uid }
            ?? rows.first { $0.uid == uid }
            ?? duplicateGroups.lazy.flatMap(\.members).first { $0.uid == uid }
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

    /// Selected files that can take a typed date. Parked copies stay where they are.
    func dateTargets() -> [LibraryAsset] {
        let pool = sectionAssets()
        var chosen = pool.filter { selectedUIDs.contains($0.uid) }
        if chosen.isEmpty, let selectedUID, let one = pool.first(where: { $0.uid == selectedUID }) {
            chosen = [one]
        }
        return chosen.filter { !parkedInLibrary($0) }
    }

    /// Selected files in the folder on screen. One selected row is enough.
    func moveTargets() -> [LibraryAsset] {
        var chosen = rows.filter { selectedUIDs.contains($0.uid) }
        if chosen.isEmpty, let selectedUID, let one = rows.first(where: { $0.uid == selectedUID }) {
            chosen = [one]
        }
        return chosen.filter { $0.relPath != nil }
    }

    /// Moves the selection into the named folder, then rescans so the catalog follows the files.
    /// `subfolder` creates that folder inside the folder on screen. Otherwise it is created under Photos.
    func moveSelected(to typed: String, subfolder: Bool = false) async {
        guard !moveBusy, !mergeBusy, !dateBusy, !organizeBusy, !removalBusy, !cleanBusy, !rescanBusy else { return }
        guard let name = FolderMove.folderName(typed) else {
            notice = "Type a folder name."
            return
        }
        let assets = moveTargets()
        guard !assets.isEmpty else {
            notice = "Select a file to move."
            return
        }
        var items: [(sourceRel: String, destDir: String)] = []
        for asset in assets {
            guard let rel = asset.relPath,
                  let dir = FolderMove.directory(
                    displayFolder: displayFolder,
                    fileRelPath: rel,
                    folderName: name,
                    subfolder: subfolder
                  ) else {
                continue
            }
            items.append((rel, dir))
        }
        guard !items.isEmpty else {
            notice = "Those files are not in this folder."
            return
        }
        moveBusy = true
        let total = items.count
        var outcome = FolderMove.Outcome()
        let root = libraryRoot
        for (index, item) in items.enumerated() {
            let place = item.destDir
            notice = "Moving \(index + 1) of \(total) to \(place)."
            await Task.yield()
            let step = await Task.detached(priority: .userInitiated) {
                FolderMove.perform(libraryRoot: root, items: [item])
            }.value
            outcome.moved += step.moved
            outcome.stayed += step.stayed
            for dir in step.directories where !outcome.directories.contains(dir) {
                outcome.directories.append(dir)
            }
        }
        outcome.stayed += assets.count - items.count
        moveBusy = false
        if outcome.moved > 0 {
            refreshFolderTree(for: outcome.directories)
        }
        let done = FolderMove.finishedNotice(name: name, outcome: outcome)
        let prefixes = FolderMove.rescanPrefixes(displayFolder: displayFolder, destinations: outcome.directories)
        await rescanMovedFolders(prefixes, notice: done)
    }

    /// Writes the typed date on every selected file and moves each one into its date folder.
    func setCaptureDate(_ text: String) async {
        guard !dateBusy, !organizeBusy, !removalBusy, !cleanBusy, !rescanBusy, !moveBusy, !mergeBusy else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let wire = LibraryItemMenu.captureRequest(trimmed) else {
            notice = "The date was not saved. Use YYYY-MM-DD or a four-digit year."
            return
        }
        let assets = dateTargets()
        guard !assets.isEmpty else {
            notice = "The date was not saved."
            return
        }
        dateBusy = true
        defer { dateBusy = false }
        var moved = 0
        var stayed = 0
        let total = assets.count
        for (index, asset) in assets.enumerated() {
            notice = "Moving \(index + 1) of \(total) to its date folder."
            await Task.yield()
            do {
                let reply = try await client.placeCaptureDate(uid: asset.uid, captureTime: wire)
                if reply.error != nil {
                    stayed += 1
                } else {
                    moved += 1
                }
            } catch {
                stayed += total - moved - stayed
                break
            }
        }
        if stayed == 0 {
            notice = moved == 1 ? "Moved to its date folder." : "Moved \(moved) files to their date folders."
        } else if moved == 0 {
            notice = total == 1 ? "The date was not saved." : "The dates were not saved."
        } else {
            notice = "\(moved) moved to their date folders. \(stayed) stayed."
        }
        await reload(media: "photo")
    }

    /// The first page of stills in the open folder. Later pages wait for the next Organize.
    func canOrganizeFirstPage() -> Bool {
        librarySection == "Photos" && FolderOrganize.allows(displayFolder) && !organizePage().isEmpty
    }

    /// Yes reads the first page. Continue reads that page and the pages after it.
    /// A photo with no date goes to Photos/_Review. A dated photo goes to Photos/YYYY/YYYY-MM-DD.
    /// A photo already in that year and day folder stays. A matching file date can raise catalog confidence from 0.00 to 1.00.
    /// A moved duplicate leaves its preview in Photos/_Duplicates.
    func organizeDisplayFolder(repeating: Bool) async {
        guard !organizeBusy, !dateBusy, !removalBusy, !cleanBusy, !rescanBusy, !moveBusy, !mergeBusy else { return }
        guard librarySection == "Photos", FolderOrganize.allows(displayFolder) else {
            notice = "Organize runs on a folder of photos."
            return
        }
        guard nameFilter.isEmpty else {
            notice = "Clear the name filter before Organize."
            return
        }
        guard !organizePage().isEmpty else {
            notice = "This folder has no photos on the first page."
            return
        }
        organizeBusy = true
        defer {
            organizeBusy = false
            organizeMeter = nil
        }
        if repeating {
            showOrganize(status: "Reading this folder", done: 0, total: 0)
            resetFolderPages()
            await reload(media: "photo")
        }
        var folderCount = (!folderPageCounting ? folderPhotoTotal : nil) ?? organizePage().count
        var reviewed = 0
        var dated = 0
        var duplicates = 0
        var stayed = 0
        var confirmed = 0
        var confidenceMissed = false
        var acceptConfirm = true
        var pages = 0
        var pageIndex = 0
        var seen: Set<String> = []
        var needsReload = false
        while librarySection == "Photos", FolderOrganize.allows(displayFolder), nameFilter.isEmpty {
            if !folderPageCounting, let folderPhotoTotal, folderPhotoTotal > folderCount {
                folderCount = folderPhotoTotal
            }
            let targets = organizePage(at: pageIndex)
            if targets.isEmpty { break }
            pages += 1
            let step = await organizeOnePage(
                targets,
                folderCount: folderCount,
                seen: &seen,
                acceptConfirm: &acceptConfirm
            )
            reviewed += step.reviewed
            dated += step.dated
            duplicates += step.duplicates
            stayed += step.stayed
            confirmed += step.confirmed
            if step.confidenceMissed { confidenceMissed = true }
            let running = FolderOrganize.summary(
                reviewed: reviewed,
                dated: dated,
                duplicates: duplicates,
                stayed: stayed,
                confirmed: confirmed,
                pages: pages,
                confidenceMissed: confidenceMissed
            )
            let moved = step.reviewed + step.dated + step.duplicates > 0
            if moved {
                let prefixes = FolderMove.rescanPrefixes(displayFolder: displayFolder, destinations: step.destinations)
                organizeMeter = nil
                await refreshOrganizedFolders(prefixes, notice: running, previews: step.carried)
                needsReload = false
                pageIndex = 0
            } else {
                needsReload = needsReload || step.confirmed > 0
                pageIndex += 1
            }
            let progressed = step.reviewed + step.dated + step.confirmed > 0
            if !repeating || !progressed { break }
        }
        let done = FolderOrganize.summary(
            reviewed: reviewed,
            dated: dated,
            duplicates: duplicates,
            stayed: stayed,
            confirmed: confirmed,
            pages: max(pages, 1),
            confidenceMissed: confidenceMissed
        )
        if pages == 0 {
            notice = "This folder has no photos on the first page."
            return
        }
        if needsReload {
            organizeMeter = nil
            await refreshOrganizedFolders([], notice: done, previews: [])
        }
        notice = done
    }

    private struct OrganizePageStep {
        var reviewed = 0
        var dated = 0
        var duplicates = 0
        var stayed = 0
        var confirmed = 0
        var confidenceMissed = false
        var destinations: [String] = []
        var carried: [(path: String, jpeg: Data)] = []
    }

    private enum OrganizeConfirm {
        case marked
        case refused
        case unavailable
    }

    /// One page. A photo already in its year and day folder is left there.
    /// Confidence 0.00 becomes 1.00 when DateTimeOriginal, DateTimeDigitized, or DateTime matches that folder.
    private func organizeOnePage(
        _ targets: [LibraryAsset],
        folderCount: Int,
        seen: inout Set<String>,
        acceptConfirm: inout Bool
    ) async -> OrganizePageStep {
        var step = OrganizePageStep()
        let root = libraryRoot
        for asset in targets {
            guard let rel = asset.relPath, let source = fileURL(for: asset) else {
                step.stayed += 1
                markOrganized(asset.uid, status: "Skipping a file with no path", seen: &seen, folderCount: folderCount)
                continue
            }
            let fileName = (rel as NSString).lastPathComponent
            if parkedInLibrary(asset) {
                step.stayed += 1
                markOrganized(asset.uid, status: "Leaving \(fileName) in place", seen: &seen, folderCount: folderCount)
                continue
            }
            let catalog = asset.captureTime
            let knownPreview = displayImageData(uid: asset.uid) ?? cells[asset.uid]?.imageData
            let thumbRel = asset.thumbRel
            let confidence = asset.captureConfidence
            markOrganized(asset.uid, status: "Reading the date", seen: &seen, folderCount: folderCount)
            let scan = await Task.detached(priority: .userInitiated) { () -> (day: FolderOrganize.Day?, matches: Bool, preview: Data?) in
                let lines = ReviewHeaderFacts.read(source).lines
                let day = FolderOrganize.day(catalog: catalog, headerLines: lines)
                let matches = day.map { FolderOrganize.headerMatches(day: $0, headerLines: lines) } ?? false
                if let day, FolderOrganize.alreadyPlaced(path: rel, day: day) {
                    return (day, matches, nil)
                }
                var preview = knownPreview
                if preview == nil || (preview?.count ?? 0) > 2_000_000, let thumbRel {
                    preview = try? Data(contentsOf: root.appending(path: thumbRel))
                }
                if let current = preview, current.count > 2_000_000 {
                    preview = nil
                }
                if preview == nil {
                    preview = FolderOrganize.previewJPEG(from: source)
                }
                return (day, matches, preview)
            }.value
            if let day = scan.day, FolderOrganize.alreadyPlaced(path: rel, day: day) {
                if acceptConfirm, FolderOrganize.confidenceIsZero(confidence), scan.matches {
                    markOrganized(asset.uid, status: "Setting catalog confidence for \(fileName)", seen: &seen, folderCount: folderCount)
                    switch await confirmPlacedDate(uid: asset.uid, day: day) {
                    case .marked:
                        step.confirmed += 1
                        noteConfirmed(asset.uid, day: day)
                    case .refused:
                        break
                    case .unavailable:
                        step.confidenceMissed = true
                        acceptConfirm = false
                    }
                }
                step.stayed += 1
                markOrganized(asset.uid, status: "Leaving \(fileName) in its date folder", seen: &seen, folderCount: folderCount)
                continue
            }
            let directory = FolderOrganize.folder(for: scan.day)
            let preview = scan.preview
            markOrganized(asset.uid, status: "Moving \(fileName) to \(directory)", seen: &seen, folderCount: folderCount)
            let move = await Task.detached(priority: .userInitiated) { () -> (placed: String?, moved: Bool, reference: String?) in
                let outcome = FolderMove.perform(libraryRoot: root, items: [(rel, directory)])
                guard let placed = outcome.placed.first, outcome.moved > 0 else {
                    return (nil, false, nil)
                }
                let placedURL = root.appending(path: placed)
                let size = Int64((try? placedURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                let neighbors = FolderOrganize.neighbors(of: placedURL.deletingLastPathComponent())
                let duplicate = FolderOrganize.isDuplicate(
                    sourceName: fileName,
                    placedName: placedURL.lastPathComponent,
                    placedSize: size,
                    neighbors: neighbors
                )
                var reference: String?
                if duplicate, let preview {
                    reference = FolderMove.writeNewFile(
                        libraryRoot: root,
                        directory: FolderOrganize.duplicatesFolder,
                        fileName: FolderOrganize.referenceFileName(placedPath: placed),
                        data: preview
                    )
                }
                return (placed, true, reference)
            }.value
            if move.moved, let placed = move.placed {
                if scan.day == nil {
                    step.reviewed += 1
                } else {
                    step.dated += 1
                }
                if let preview = scan.preview {
                    step.carried.append((placed, preview))
                }
                let parent = (placed as NSString).deletingLastPathComponent
                if !step.destinations.contains(parent) {
                    step.destinations.append(parent)
                }
            } else {
                step.stayed += 1
            }
            if move.reference != nil {
                step.duplicates += 1
                if !step.destinations.contains(FolderOrganize.duplicatesFolder) {
                    step.destinations.append(FolderOrganize.duplicatesFolder)
                }
            }
            markOrganized(asset.uid, status: "Moving \(fileName) to \(directory)", seen: &seen, folderCount: folderCount)
        }
        return step
    }

    private func markOrganized(_ uid: String, status: String, seen: inout Set<String>, folderCount: Int) {
        seen.insert(uid)
        let done = folderCount > 0 ? min(seen.count, folderCount) : seen.count
        showOrganize(status: status, done: done, total: folderCount)
    }

    /// Sets catalog confidence to 1. A helper without this route answers as unavailable.
    private func confirmPlacedDate(uid: String, day: FolderOrganize.Day) async -> OrganizeConfirm {
        let stamp = String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
        do {
            let call = try await client.confirmCaptureDate(uid: uid, captureTime: stamp)
            if call.error != nil { return .refused }
            if call.asset?.captureConfidence == 1 { return .marked }
            return .refused
        } catch {
            return .unavailable
        }
    }

    /// The grid shows 1.00 before the folder is read again. The file stays in its date folder.
    private func noteConfirmed(_ uid: String, day: FolderOrganize.Day) {
        let stamp = String(format: "%04d-%02d-%02dT00:00:00Z", day.year, day.month, day.day)
        for page in stillPages.indices {
            guard let index = stillPages[page].firstIndex(where: { $0.uid == uid }) else { continue }
            stillPages[page][index].captureConfidence = 1
            stillPages[page][index].captureSource = "user"
            stillPages[page][index].captureTime = stamp
        }
        guard let index = rows.firstIndex(where: { $0.uid == uid }) else { return }
        rows[index].captureConfidence = 1
        rows[index].captureSource = "user"
        rows[index].captureTime = stamp
    }

    private func organizePage() -> [LibraryAsset] {
        organizePage(at: 0)
    }

    private func organizePage(at index: Int) -> [LibraryAsset] {
        if stillPages.indices.contains(index) {
            let page = stillPages[index].filter { isStill($0) }
            if !page.isEmpty { return page }
        }
        if index == 0 {
            return Array(rows.filter { isStill($0) }.prefix(FolderPage.limit))
        }
        return []
    }

    private func showOrganize(status: String, done: Int, total: Int) {
        let fraction = total > 0 ? min(1, max(0, Double(done) / Double(total))) : nil
        let meter = TouchupMeter(title: "Organize. \(status)", done: done, total: total, fraction: fraction)
        organizeMeter = meter
        notice = rescanProgressCaption(meter)
    }

    /// Walks the folders that gained or lost a file, then puts each saved preview on the moved photo.
    private func refreshOrganizedFolders(_ prefixes: [String], notice done: String, previews: [(path: String, jpeg: Data)]) async {
        guard !prefixes.isEmpty else {
            notice = done
            resetFolderPages()
            await reload(media: "photo")
            notice = done
            return
        }
        guard !rescanBusy else {
            notice = done
            return
        }
        rescanBusy = true
        rescanGeneration += 1
        let generation = rescanGeneration
        var catalogued = true
        for folder in prefixes {
            guard generation == rescanGeneration else { return }
            rescanMeter = TouchupMeter(title: "Rescanning \(folder)", done: 0, total: 0, fraction: nil)
            let ok = await runFolderRescan(generation: generation, folder: folder, announce: false, reloadGrid: false)
            if !ok {
                catalogued = false
                break
            }
        }
        guard generation == rescanGeneration else { return }
        rescanMeter = nil
        rescanBusy = false
        if catalogued {
            for (index, item) in previews.enumerated() {
                showOrganize(status: "Saving the preview", done: index, total: max(previews.count, 1))
                await restoreMovedPreview(path: item.path, jpeg: item.jpeg)
            }
        }
        organizeMeter = nil
        let line = catalogued ? done : done + " The folder was not rescanned."
        notice = line
        resetFolderPages()
        await reload(media: "photo")
        notice = line
    }

    /// The moved file has a new catalog row. The preview JPEG is stored on that row when the helper can see the path.
    private func restoreMovedPreview(path: String, jpeg: Data) async {
        guard let body = FolderOrganize.previewFacts(jpeg: jpeg) else { return }
        guard let page = try? await client.assets(matching: path) else { return }
        guard let asset = page.rows.first(where: { $0.relPath == path }) else { return }
        _ = try? await client.putFacts(uid: asset.uid, body: body)
    }

    /// Deletes `folder` and the folders inside it when they contain no files. Photos stays.
    func cleanEmptyDisplayFolder(_ folder: String) async {
        guard !cleanBusy, !removalBusy, !dateBusy, !organizeBusy, !rescanBusy, !moveBusy, !mergeBusy else { return }
        guard librarySection == "Photos", EmptyFolderClean.allows(folder) else {
            notice = "Clean runs on a folder inside Photos."
            return
        }
        cleanBusy = true
        defer { cleanBusy = false }
        notice = "Cleaning empty folders."
        await Task.yield()
        let root = libraryRoot
        let outcome = await Task.detached(priority: .userInitiated) {
            EmptyFolderClean.removeEmpty(libraryRoot: root, folder: folder)
        }.value
        let line = outcome.missing ? "That folder could not be opened." : EmptyFolderClean.summary(removed: outcome.removed.count, failed: outcome.failed, files: outcome.removedFiles)
        notice = line
        guard !outcome.removed.isEmpty else { return }
        refreshFolderTree(for: outcome.removed)
        let gone = Set(outcome.removed)
        var next = displayFolder
        while next != DisplayFolder.root && (gone.contains(next) || gone.contains(where: { next.hasPrefix($0 + "/") })) {
            let parent = (next as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == next {
                next = DisplayFolder.root
                break
            }
            next = parent
        }
        guard next != displayFolder else { return }
        displayFolder = next
        resetFolderPages()
        await reload(media: "photo")
        notice = line
    }

    /// Drops leftover catalog rows in the open folder. A row goes only when its file is gone and another file here has the same name and size.
    func cleanDisplayFolder() async {
        guard !cleanBusy, !removalBusy, !dateBusy, !organizeBusy, !moveBusy, !mergeBusy else { return }
        cleanBusy = true
        defer { cleanBusy = false }
        notice = "Cleaning leftover records."
        await Task.yield()
        do {
            let reply = try await client.cleanFolder(prefix: displayFolder)
            if reply.error == "busy" {
                notice = "Folder cleanup waits until the helper is idle."
                return
            }
            if reply.error != nil {
                notice = "Folder cleanup did not run."
                return
            }
            let removed = reply.removed ?? 0
            let kept = reply.kept ?? 0
            notice = cleanFolderNotice(removed: removed, kept: kept)
            if removed > 0 {
                await reload(media: "photo")
            }
        } catch {
            notice = "Folder cleanup did not run."
        }
    }

    /// Deletes every file in Photos/_Removed, then asks the helper to drop those catalog rows.
    func deleteAllRemoved() async {
        guard DisplayFolder.isRemovedShelf(displayFolder) else { return }
        guard !removalBusy, !rescanBusy, !dateBusy, !organizeBusy, !cleanBusy, !moveBusy, !mergeBusy else { return }
        removalBusy = true
        notice = "Deleting photos in Photos/_Removed."
        let root = libraryRoot
        let result = await Task.detached(priority: .userInitiated) {
            RemovedShelf.deleteContents(libraryRoot: root)
        }.value
        removalBusy = false
        guard DisplayFolder.isRemovedShelf(displayFolder) else { return }
        if result.missing || (result.deleted == 0 && result.failed > 0) {
            notice = "Photos/_Removed could not be opened."
            return
        }
        // The catalog page still on screen is the folder from before this delete.
        resetFolderPages()
        rows = []
        trimSelectionToRows()
        if result.failed > 0 {
            notice = "Deleted \(result.deleted.formatted()) files. \(result.failed.formatted()) stayed in Photos/_Removed."
        } else if result.deleted == 0 {
            notice = "Photos/_Removed is already empty."
        } else if result.deleted == 1 {
            notice = "Deleted 1 file from Photos/_Removed."
        } else {
            notice = "Deleted \(result.deleted.formatted()) files from Photos/_Removed."
        }
        rescanDisplayFolder()
    }

    /// Catalogs the displayed folder and its subfolders, and deletes rows whose files are gone.
    func rescanDisplayFolder() {
        guard !rescanBusy, !removalBusy, !dateBusy, !organizeBusy, !cleanBusy, !moveBusy, !mergeBusy else { return }
        rescanBusy = true
        rescanGeneration += 1
        let generation = rescanGeneration
        let folder = displayFolder
        notice = nil
        rescanMeter = TouchupMeter(title: "Rescanning \(folder)", done: 0, total: 0, fraction: nil)
        Task { await runFolderRescan(generation: generation, folder: folder) }
    }

    /// Asks the folder tree to list these directories under their parents.
    private func refreshFolderTree(for directories: [String]) {
        var parents: [String] = []
        for directory in directories {
            let parent = (directory as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != directory, !parents.contains(parent) else { continue }
            parents.append(parent)
        }
        guard !parents.isEmpty else { return }
        folderTreeParents = parents
        folderTreeRevision += 1
    }

    /// Walks each folder that gained or lost a file. The move notice stays when the walks finish.
    private func rescanMovedFolders(_ prefixes: [String], notice done: String) async {
        guard !prefixes.isEmpty else {
            notice = done
            return
        }
        guard !rescanBusy else {
            notice = done
            return
        }
        rescanBusy = true
        rescanGeneration += 1
        let generation = rescanGeneration
        var catalogued = true
        for folder in prefixes {
            guard generation == rescanGeneration else { return }
            rescanMeter = TouchupMeter(title: "Rescanning \(folder)", done: 0, total: 0, fraction: nil)
            let ok = await runFolderRescan(generation: generation, folder: folder, announce: false, reloadGrid: false)
            if !ok {
                catalogued = false
                break
            }
        }
        guard generation == rescanGeneration else { return }
        rescanMeter = nil
        rescanBusy = false
        let line = catalogued ? done : done + " The folder was not rescanned."
        notice = line
        // A cursor refresh of the page on screen misses files the scan just added, and keeps a page that lost files.
        resetFolderPages()
        await reload(media: "photo")
        notice = line
    }

    private func runFolderRescan(generation: Int, folder: String, announce: Bool = true, reloadGrid: Bool = true) async -> Bool {
        switch await client.startFolderRescan(prefix: folder) {
        case .unsupported:
            if announce {
                finishRescan(generation: generation, notice: "This helper cannot rescan a folder yet.")
            }
            return false
        case .busy:
            if announce {
                finishRescan(generation: generation, notice: "A folder rescan is already running.")
            }
            return false
        case .offline:
            if announce {
                finishRescan(generation: generation, notice: "The folder was not rescanned.")
            }
            return false
        case .status:
            return await followFolderRescan(generation: generation, folder: folder, announce: announce, reloadGrid: reloadGrid)
        }
    }

    private func followFolderRescan(generation: Int, folder: String, announce: Bool = true, reloadGrid: Bool = true) async -> Bool {
        var misses = 0
        var lastAdded = -1
        var lastRemoved = -1
        var lastReload = Date.distantPast
        while generation == rescanGeneration {
            switch await client.folderRescanStatus() {
            case .status(let status):
                misses = 0
                guard generation == rescanGeneration else { return false }
                applyRescanMeter(status, folder: folder)
                let changed = status.added != lastAdded || status.removed != lastRemoved
                if reloadGrid, changed, displayFolder == folder, Date().timeIntervalSince(lastReload) > 2 {
                    lastAdded = status.added
                    lastRemoved = status.removed
                    lastReload = Date()
                    await reload(media: "photo")
                }
                if status.runState == "running" {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                if reloadGrid, displayFolder == folder {
                    await reload(media: "photo")
                }
                if status.runState == "failed" {
                    let line = status.error == "prefix" ? "That folder cannot be rescanned." : "The folder was not rescanned."
                    if announce {
                        finishRescan(generation: generation, notice: line)
                    }
                    return false
                }
                if announce {
                    finishRescan(generation: generation, notice: rescanFinishedNotice(added: status.added, removed: status.removed))
                }
                return true
            case .unsupported:
                if announce {
                    finishRescan(generation: generation, notice: "This helper cannot rescan a folder yet.")
                }
                return false
            case .busy, .offline:
                misses += 1
                if misses >= 5 {
                    if announce {
                        finishRescan(generation: generation, notice: "The folder was not rescanned.")
                    }
                    return false
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return false
    }

    private func applyRescanMeter(_ status: FolderScanStatus, folder: String) {
        let prefix = status.prefix.isEmpty ? folder : status.prefix
        let title = "Rescanning \(prefix)"
        if status.total > 0 {
            let fraction = min(1, max(0, Double(status.done) / Double(status.total)))
            rescanMeter = TouchupMeter(title: title, done: status.done, total: status.total, fraction: fraction)
        } else {
            rescanMeter = TouchupMeter(title: title, done: status.done, total: 0, fraction: nil)
        }
    }

    private func finishRescan(generation: Int, notice: String) {
        guard generation == rescanGeneration else { return }
        rescanMeter = nil
        rescanBusy = false
        self.notice = notice
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

    /// Reads the startup buffer. The call does not start a scan.
    func refreshHelperPass() async {
        switch await client.duplicateScanStatus() {
        case .status(let status):
            helperPass = status
        case .unsupported:
            helperPass = nil
        case .busy, .offline:
            break
        }
    }

    func clearHelperPass() {
        helperPass = nil
    }

    /// Asks the helper to preview this folder before it continues through the library.
    func showFocus(_ prefix: String? = nil) async {
        await client.setFocus(prefix: prefix ?? displayFolder)
    }

    func clearFocus() async {
        await client.setFocus(prefix: "")
    }

    /// Reads the helper's scan line. Opening the panel does not start a scan.
    func refreshScan() async {
        switch await client.duplicateScanStatus() {
        case .status(let status):
            await adoptScan(status)
        case .unsupported, .busy, .offline:
            break
        }
    }

    /// Compares the library again, then lists the groups that comparison recorded.
    /// A helper without the scan route still lists whatever its startup pass stored.
    func findDuplicates() async {
        await loadTrim()
        switch await client.startDuplicateScan() {
        case .unsupported:
            await listFoundGroups()
            if duplicateGroups.isEmpty {
                duplicateNotice = DuplicateCopy.scanNeedsHelper
            }
        case .busy:
            duplicateNotice = DuplicateCopy.scanBusy
        case .offline:
            duplicateNotice = DuplicateCopy.findUnreachable
        case .status(let status):
            if status.runState == "running" {
                scan = status
                await watchScan()
            } else if status.runState == "completed" {
                scan = status
                await listFoundGroups()
            } else if status.runState == "failed" {
                scan = status
                duplicateNotice = DuplicateCopy.scanStopped(status)
            } else {
                scan = status
            }
        }
    }

    func watchScan() async {
        while scan?.runState == "running" {
            switch await client.duplicateScanStatus() {
            case .status(let status):
                await adoptScan(status)
            case .unsupported, .busy, .offline:
                duplicateNotice = DuplicateCopy.findUnreachable
                return
            }
            if scan?.runState == "running" {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func adoptScan(_ status: DuplicateScan) async {
        let wasRunning = scan?.runState == "running"
        scan = status
        if wasRunning && status.runState == "completed" {
            await listFoundGroups()
        } else if status.runState == "failed" {
            duplicateNotice = DuplicateCopy.scanStopped(status)
        } else if wasRunning && status.runState != "running" {
            duplicateNotice = "The scan ended before it finished."
        }
    }

    /// Lists matching groups, including copies that are still in their folders.
    /// The running helper ignores found=1 and returns the store, so an empty list uses the trim counts.
    private func listFoundGroups() async {
        do {
            let page = try await client.duplicates(found: true)
            duplicateGroups = page.groups
            await loadDuplicateThumbnails()
            if let recorded = scan?.groups, scan?.runState == "completed", recorded > page.groups.count {
                duplicateNotice = "Found \(DuplicateCopy.count(recorded)) matching groups. This list shows the first \(page.groups.count)."
            } else {
                duplicateNotice = DuplicateCopy.findResult(
                    groups: page.groups.count,
                    eligible: trim?.eligible,
                    waiting: trim?.waiting
                )
            }
        } catch {
            duplicateNotice = DuplicateCopy.findUnreachable
        }
    }

    /// Files already parked, purged, or in the duplicates store stay where they are.
    func parkedInLibrary(_ asset: LibraryAsset) -> Bool {
        if asset.placement == "removed" || asset.placement == "purged" || asset.placement == "duplicates" {
            return true
        }
        let path = asset.relPath ?? ""
        return path == "Photos/_Removed" || path.hasPrefix("Photos/_Removed/")
            || path == "Photos/_Duplicates" || path.hasPrefix("Photos/_Duplicates/")
    }

    /// The right-clicked cell is removed alone. A click inside the selection removes every selected row that can move.
    func libraryRemovalTargets(clicked: LibraryAsset) -> [LibraryAsset] {
        let chosen: [LibraryAsset]
        if selectedUIDs.contains(clicked.uid) {
            chosen = rows.filter { selectedUIDs.contains($0.uid) }
        } else {
            chosen = [clicked]
        }
        return chosen.filter { !parkedInLibrary($0) }
    }

    /// Journal-moves each file into Photos/_Removed, one at a time. A failure leaves that file in place.
    func removeFromLibrary(_ assets: [LibraryAsset]) async {
        guard !assets.isEmpty, !removalBusy, !dateBusy, !organizeBusy, !cleanBusy, !rescanBusy, !moveBusy, !mergeBusy else { return }
        removalBusy = true
        defer { removalBusy = false }
        var moved = 0
        var stayed = 0
        let total = assets.count
        for (index, asset) in assets.enumerated() {
            notice = "Moving \(index + 1) of \(total) to Photos/_Removed."
            await Task.yield()
            do {
                let reply = try await client.removeFromLibrary(uid: asset.uid)
                if reply.error != nil {
                    stayed += 1
                } else {
                    moved += 1
                }
            } catch {
                stayed += total - moved - stayed
                break
            }
        }
        if stayed == 0 {
            notice = moved == 1 ? "Moved to Photos/_Removed." : "Moved \(moved) files to Photos/_Removed."
        } else if moved == 0 {
            notice = total == 1 ? "The file stayed in the library." : "The files stayed in the library."
        } else {
            notice = "\(moved) moved to Photos/_Removed. \(stayed) stayed in the library."
        }
        await reload(media: "photo")
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

    /// Stays asleep while this page's previews are done. Wakes when the page changes.
    func waitForAnotherFolderPage() async {
        let page = folderPage
        while !Task.isCancelled && folderPage == page && !awaitsPreviews {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// How many photographs are reduced at once. Each reduction runs off the main thread.
    private static let previewWorkers = 4

    /// Stores a preview for each still in the open folder that does not already have one.
    /// A photo with a stored thumbnail is left as it is. Videos are left out.
    /// A name filter is refused. The sensor converter is not run.
    func buildMissingFolderPreviews() async {
        guard !folderPreviewBuildBusy else { return }
        if !nameFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            folderPreviewBuildNote = FolderPreviewBuild.filterNote
            return
        }
        let key = folderListKey
        previewBuildKey = key
        folderPreviewBuildBusy = true
        defer {
            if previewBuildKey == key {
                folderPreviewBuildBusy = false
                previewBuildKey = nil
            }
        }
        if folderPageCounting {
            folderPreviewBuildNote = FolderPreviewBuild.reading
        }
        while folderPageCounting {
            if folderListKey != key || previewBuildKey != key { 
                folderPreviewBuildNote = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if folderListKey != key || previewBuildKey != key {
            folderPreviewBuildNote = nil
            return
        }
        let stills = stillPages.flatMap { $0 }.filter { isStill($0) }
        let missing = stills.filter { lacksStoredPreview($0) }
        if missing.isEmpty {
            folderPreviewBuildNote = FolderPreviewBuild.finished(photos: stills.count, built: 0, missed: 0)
            return
        }
        folderPreviewBuildNote = FolderPreviewBuild.progress(done: 0, total: missing.count)
        var built = 0
        var missed = 0
        for (index, asset) in missing.enumerated() {
            if folderListKey != key || previewBuildKey != key {
                folderPreviewBuildNote = nil
                return
            }
            if await storeBuiltPreview(asset) {
                built += 1
            } else {
                missed += 1
            }
            if folderListKey != key || previewBuildKey != key {
                folderPreviewBuildNote = nil
                return
            }
            folderPreviewBuildNote = FolderPreviewBuild.progress(done: index + 1, total: missing.count)
            await Task.yield()
        }
        if folderListKey != key || previewBuildKey != key {
            folderPreviewBuildNote = nil
            return
        }
        folderPreviewBuildNote = FolderPreviewBuild.finished(photos: stills.count, built: built, missed: missed)
    }

    private func lacksStoredPreview(_ asset: LibraryAsset) -> Bool {
        guard isStill(asset) else { return false }
        if asset.thumbRel != nil { return false }
        if editedJPEG[asset.uid] != nil { return false }
        if cells[asset.uid]?.imageData != nil { return false }
        return true
    }

    /// ImageIO facts when the file can be reduced. An X3F uses its embedded preview.
    private func storeBuiltPreview(_ asset: LibraryAsset) async -> Bool {
        guard asset.thumbRel == nil, let url = fileURL(for: asset) else { return false }
        let body: Data? = await Task.detached {
            FolderPreviewFacts.body(for: url)
        }.value
        guard let body else { return false }
        do {
            guard try await client.putFacts(uid: asset.uid, body: body) == 200 else { return false }
        } catch {
            return false
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

    /// Reduces the first visible still that has no preview yet. The page order is the folder on screen.
    /// The helper previews that same folder ahead of the rest of the library.
    func previewVisibleOne() async -> Bool {
        guard let asset = rows.first(where: needsVisiblePreview) else { return false }
        await previewAsset(asset)
        return true
    }

    /// Reduces up to four visible stills together. The page order is the folder on screen.
    func previewVisibleBatch() async -> Int {
        await previewBatch(onScreen: true)
    }

    /// Reduces the next still on a page that is not on screen. The page the user is looking at stays put.
    func previewNextFolderStill() async -> Bool {
        guard let asset = nextOffscreenPreview() else { return false }
        await previewAsset(asset)
        return true
    }

    /// Reduces up to four stills on pages that are not on screen.
    func previewOffscreenBatch() async -> Int {
        await previewBatch(onScreen: false)
    }

    private func previewBatch(onScreen: Bool) async -> Int {
        var picked: [LibraryAsset] = []
        while picked.count < Self.previewWorkers {
            let asset = onScreen ? rows.first(where: needsVisiblePreview) : nextOffscreenPreview()
            guard let asset else { break }
            previewTried.insert(asset.uid)
            picked.append(asset)
        }
        guard !picked.isEmpty else { return 0 }
        await withTaskGroup(of: Void.self) { group in
            for asset in picked {
                group.addTask { await self.previewAsset(asset) }
            }
        }
        return picked.count
    }

    /// Pages after the one on screen come first. Earlier pages follow.
    private func nextOffscreenPreview() -> LibraryAsset? {
        guard !stillPages.isEmpty else { return nil }
        let current = min(max(folderPage, 0), stillPages.count - 1)
        var order: [[LibraryAsset]] = []
        if current + 1 < stillPages.count {
            order.append(contentsOf: stillPages[(current + 1)...])
        }
        if current > 0 {
            order.append(contentsOf: stillPages[..<current])
        }
        for page in order {
            if let asset = page.first(where: needsVisiblePreview) {
                return asset
            }
        }
        return nil
    }

    private func previewAsset(_ asset: LibraryAsset) async {
        previewTried.insert(asset.uid)
        guard let url = fileURL(for: asset) else { return }
        let facts: Data
        do {
            facts = try await Task.detached {
                try MacCheckpoint.payloads(for: url).facts
            }.value
        } catch {
            return
        }
        do {
            guard try await client.putFacts(uid: asset.uid, body: facts) == 200 else { return }
        } catch {
            return
        }
        var updated = asset
        let prefix = String(asset.uid.prefix(2))
        updated.thumbRel = ".zimage/cache/thumbs/\(prefix)/\(asset.uid).jpg"
        if updated.phase == "discovered" || updated.phase == nil {
            updated.phase = "thumbed"
        }
        replace(updated)
        await storePreview(for: updated)
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
            payloads = try await Task.detached {
                try MacCheckpoint.payloads(for: url)
            }.value
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
        for page in stillPages.indices {
            if let index = stillPages[page].firstIndex(where: { $0.uid == asset.uid }) {
                stillPages[page][index] = asset
            }
        }
        if let index = folderVideos.firstIndex(where: { $0.uid == asset.uid }) {
            folderVideos[index] = asset
        }
    }

    /// Scales the cell. The helper thumbnail URL stays the same.
    func setPreviewPoints(_ points: Double) {
        previewPoints = PreviewSize.clamped(points)
    }

    func displayImageData(uid: String) -> Data? {
        editedJPEG[uid] ?? cells[uid]?.imageData
    }

    func selectRow(_ uid: String, shift: Bool, extend: Bool = false, order: [String]) {
        let choice = GridSelection.choose(
            order: order,
            anchor: selectionAnchorUID,
            clicked: uid,
            shift: shift,
            extend: extend,
            existing: selectedUIDs
        )
        selectionOrder = SelectionOrder.update(
            previous: selectionOrder,
            gridOrder: order,
            anchor: selectionAnchorUID,
            clicked: uid,
            shift: shift,
            extend: extend,
            keys: choice.keys
        )
        selectedUIDs = choice.keys
        selectionAnchorUID = choice.anchor
        selectedUID = choice.primary
    }

    /// Selected stills in click order. A row chosen without a click follows the page.
    func mergeTargets() -> [LibraryAsset] {
        let pool = rows.filter { isStill($0) && selectedUIDs.contains($0.uid) && fileURL(for: $0) != nil }
        var ordered: [LibraryAsset] = []
        for uid in selectionOrder {
            if let asset = pool.first(where: { $0.uid == uid }) {
                ordered.append(asset)
            }
        }
        for asset in pool where !ordered.contains(where: { $0.uid == asset.uid }) {
            ordered.append(asset)
        }
        return ordered
    }

    func mergeFolderPair() -> (first: String, second: String)? {
        let assets = mergeTargets()
        guard assets.count == 2 else { return nil }
        return (filename(for: assets[0]), filename(for: assets[1]))
    }

    /// The two selected stills, in click order, when they can be previewed.
    func mergePair() -> MergePairLookup {
        guard !mergeBusy, !moveBusy, !dateBusy, !organizeBusy, !removalBusy, !cleanBusy, !rescanBusy else {
            return .refused("An export is already running.")
        }
        let assets = mergeTargets()
        guard assets.count == 2 else { return .refused("Select two photos.") }
        guard let firstRel = assets[0].relPath, let secondRel = assets[1].relPath,
              let firstURL = fileURL(for: assets[0]), let secondURL = fileURL(for: assets[1]) else {
            return .refused("The photos could not be read.")
        }
        let parent = (firstRel as NSString).deletingLastPathComponent
        guard parent == (secondRel as NSString).deletingLastPathComponent else {
            return .refused("Select two photos in the same folder.")
        }
        let firstPath = firstURL.standardizedFileURL.resolvingSymlinksInPath()
        let secondPath = secondURL.standardizedFileURL.resolvingSymlinksInPath()
        guard firstPath != secondPath else { return .refused("Select two different photos.") }
        let folder = parent.isEmpty ? displayFolder : parent
        return .ready(
            first: firstURL,
            second: secondURL,
            directory: firstURL.deletingLastPathComponent(),
            folder: folder
        )
    }

    /// Holds the other folder actions while the TIFF is written.
    func claimMergeWrite() -> Bool {
        guard !mergeBusy, !moveBusy, !dateBusy, !organizeBusy, !removalBusy, !cleanBusy, !rescanBusy else {
            notice = "An export is already running."
            return false
        }
        mergeBusy = true
        notice = "Merging the two photos."
        return true
    }

    /// A flattened TIFF is already beside its photograph. The catalog walk adds that file.
    func catalogAddedFile(_ name: String, in folder: String) {
        let line = "Duplicated as \(name)."
        guard !folder.isEmpty else {
            notice = line
            return
        }
        Task { await rescanMovedFolders([folder], notice: line) }
    }

    /// Clears the write and rescans the folder that received the TIFF.
    func finishMergeWrite(_ result: Result<String, PhotoMergeFailure>, folder: String) async {
        mergeBusy = false
        switch result {
        case .success(let name):
            await rescanMovedFolders([folder], notice: "Merged into \(name).")
        case .failure(let error):
            notice = error.message
        }
    }

    /// A review-list click keeps one photo selected.
    func focusSelection(_ uid: String?) {
        selectedUID = uid
        if let uid {
            selectedUIDs = [uid]
            selectionAnchorUID = uid
            selectionOrder = [uid]
        } else {
            selectedUIDs = []
            selectionAnchorUID = nil
            selectionOrder = []
        }
    }

    /// Photos, Review, or Duplicates, whichever section is on screen.
    func sectionAssets() -> [LibraryAsset] {
        switch librarySection {
        case "Review":
            return reviewRows
        case "Duplicates":
            return duplicateGroups.flatMap(\.members)
        default:
            return rows
        }
    }

    /// The one selected still Copy settings can read.
    func primarySettingsStill() -> LibraryAsset? {
        guard let selectedUID,
              let asset = sectionAssets().first(where: { $0.uid == selectedUID }),
              isSettingsStill(asset) else { return nil }
        return asset
    }

    func isSettingsStill(_ asset: LibraryAsset) -> Bool {
        guard !isVideo(asset), fileURL(for: asset) != nil else { return false }
        let media = asset.mediaClass?.lowercased() ?? ""
        return media == "image" || media == "raw" || media.isEmpty
    }

    /// The clicked still, or every selected still when that click is inside the selection.
    /// A nil click is the Edit menu and uses the whole selection.
    func settingsPasteTargets(clicked: LibraryAsset?) -> [LibraryAsset] {
        if let clicked {
            if selectedUIDs.contains(clicked.uid) {
                return rotatableStills(in: sectionAssets())
            }
            return isSettingsStill(clicked) ? [clicked] : []
        }
        return rotatableStills(in: sectionAssets())
    }

    func rotatableStills(in pool: [LibraryAsset]) -> [LibraryAsset] {
        var seen = Set<String>()
        return pool.filter { asset in
            guard selectedUIDs.contains(asset.uid), seen.insert(asset.uid).inserted else { return false }
            guard !isVideo(asset), fileURL(for: asset) != nil else { return false }
            let media = asset.mediaClass?.lowercased() ?? ""
            return media == "image" || media == "raw" || media.isEmpty
        }
    }

    func installEditedPreview(file: URL, jpeg: Data?) {
        let key = FolderEntry.cacheKey(for: file)
        let pool = rows + reviewRows + duplicateGroups.flatMap(\.members)
        for asset in pool {
            guard let url = fileURL(for: asset), FolderEntry.cacheKey(for: url) == key else { continue }
            if let jpeg {
                editedJPEG[asset.uid] = jpeg
            } else {
                editedJPEG.removeValue(forKey: asset.uid)
            }
        }
    }

    func openSelected() {
        guard let selectedUID, let asset = rows.first(where: { $0.uid == selectedUID }) else { return }
        openInEditor(asset)
    }

    /// A still opens in the editor. A video plays in the image view when `openVideo` is set.
    func openPrimary(_ asset: LibraryAsset) {
        if isVideo(asset) {
            guard let url = fileURL(for: asset) else { return }
            selectedUID = asset.uid
            if let openVideo {
                openVideo(url)
                return
            }
            openInQuickTime(asset)
            return
        }
        openInEditor(asset)
    }

    func openInQuickTime(_ asset: LibraryAsset) {
        guard isVideo(asset), let url = fileURL(for: asset) else { return }
        selectedUID = asset.uid
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
        if let relative = asset.relPath, let openCatalogFile {
            openCatalogFile(url, asset.uid, relative)
            return
        }
        EditorHandoff.openFile(url, with: openFile)
    }

    func showInFinder(_ asset: LibraryAsset) {
        guard let url = fileURL(for: asset) else { return }
        selectedUID = asset.uid
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Gives one folder under Photos a new name. The catalog keeps each photo's id.
    /// Videos and photos are the same catalog rows. The folder moves back when the helper
    /// refuses the new name. A lost reply leaves the new name in place.
    func renameFolder(_ relative: String, to typed: String) async {
        guard !moveBusy, !mergeBusy, !dateBusy, !organizeBusy, !removalBusy, !cleanBusy, !rescanBusy else {
            notice = "An export is already running."
            return
        }
        guard FolderRename.catalogAllows(relative) else {
            notice = FolderRename.keptMessage(relative: relative)
            return
        }
        guard let source = FolderRename.libraryDirectory(libraryRoot: libraryRoot, relative: relative) else {
            notice = "The folder could not be renamed."
            return
        }
        let label = folderRenameLabel(typed)
        switch FolderRename.perform(source: source, typed: typed) {
        case .failure(let problem):
            if let message = FolderRename.message(for: problem, name: label) {
                notice = message
            }
        case .success(let dest):
            guard let newRel = DisplayFolder.prefix(selected: dest, libraryRoot: libraryRoot), newRel != relative else {
                _ = FolderRename.restore(from: dest, to: source)
                notice = "The folder could not be renamed."
                return
            }
            moveBusy = true
            notice = "Renaming \(dest.lastPathComponent)…"
            defer { moveBusy = false }
            switch await followRenamedFolder(from: relative, to: newRel) {
            case .updated:
                await adoptRenamedCatalogFolder(from: relative, to: newRel)
                notice = "Renamed to \(dest.lastPathComponent)."
            case .unsettled:
                await adoptRenamedCatalogFolder(from: relative, to: newRel)
                notice = "Renamed to \(dest.lastPathComponent). The catalog may still be catching up."
            case .restore:
                if FolderRename.restore(from: dest, to: source) {
                    notice = "The folder stayed as it is. The catalog could not follow the new name."
                } else {
                    await adoptRenamedCatalogFolder(from: relative, to: newRel)
                    notice = "Renamed to \(dest.lastPathComponent). The catalog could not follow the new name."
                }
            }
        }
    }

    /// Records a folder the Disk tree already renamed. Asset ids stay. The caller moves the folder back on failure.
    func recordRenamedFolder(from old: URL, to dest: URL) async -> LibraryFolderRenameFollow {
        guard let oldRel = DisplayFolder.prefix(selected: old, libraryRoot: libraryRoot) else {
            return .outside
        }
        guard FolderRename.catalogAllows(oldRel),
              let newRel = DisplayFolder.prefix(selected: dest, libraryRoot: libraryRoot),
              newRel != oldRel else {
            return .failed
        }
        let held = moveBusy
        if !held { moveBusy = true }
        defer { if !held { moveBusy = false } }
        switch await followRenamedFolder(from: oldRel, to: newRel) {
        case .updated:
            await adoptRenamedCatalogFolder(from: oldRel, to: newRel)
            return .updated
        case .unsettled:
            await adoptRenamedCatalogFolder(from: oldRel, to: newRel)
            return .unsettled
        case .restore:
            return .failed
        }
    }

    /// Asks the helper to follow a directory that is already at its new name.
    /// A timed-out reply is asked once more. The directory stays put when that reply
    /// also fails to arrive, and when the second reply says the name is taken.
    private func followRenamedFolder(from oldRel: String, to newRel: String) async -> RenamedFolderReply {
        switch await client.renameFolder(from: oldRel, to: newRel) {
        case .updated:
            return .updated
        case .timedOut:
            switch await client.renameFolder(from: oldRel, to: newRel) {
            case .updated, .refused:
                return .updated
            case .timedOut, .offline:
                return .unsettled
            case .unsupported:
                return .restore
            }
        case .offline, .refused, .unsupported:
            return .restore
        }
    }

    private enum RenamedFolderReply {
        case updated
        case restore
        case unsettled
    }

    private func folderRenameLabel(_ typed: String) -> String {
        if case .success(let cleaned) = FolderRename.cleaned(typed) {
            return cleaned
        }
        return typed
    }

    /// The open folder and the rows on screen follow a renamed directory. A reload reads the new path.
    private func adoptRenamedCatalogFolder(from oldRel: String, to newRel: String) async {
        func shiftAsset(_ asset: inout LibraryAsset) {
            guard let path = asset.relPath,
                  let next = FolderRename.shiftedRelative(path, from: oldRel, to: newRel) else { return }
            asset.relPath = next
        }
        for index in rows.indices { shiftAsset(&rows[index]) }
        for index in reviewRows.indices { shiftAsset(&reviewRows[index]) }
        for page in stillPages.indices {
            for index in stillPages[page].indices { shiftAsset(&stillPages[page][index]) }
        }
        for index in folderVideos.indices { shiftAsset(&folderVideos[index]) }
        for group in duplicateGroups.indices {
            if var keeper = duplicateGroups[group].keeper {
                shiftAsset(&keeper)
                duplicateGroups[group].keeper = keeper
            }
            for index in duplicateGroups[group].members.indices {
                shiftAsset(&duplicateGroups[group].members[index])
            }
        }
        let previous = displayFolder
        if let next = FolderRename.shiftedRelative(previous, from: oldRel, to: newRel) {
            displayFolder = next
        }
        refreshFolderTree(for: [newRel])
        if displayFolder != previous {
            resetFolderPages()
            await reload(media: "photo")
        }
    }

    /// Gives one catalog file a new name in its current folder. The asset id stays.
    /// A folder rescan is not used, because that inserts a second row for the new name.
    func rename(_ asset: LibraryAsset, to typed: String) {
        guard !mergeBusy, !moveBusy, !dateBusy, !organizeBusy, !removalBusy, !cleanBusy, !rescanBusy else {
            notice = "An export is already running."
            return
        }
        guard let url = fileURL(for: asset), let relative = asset.relPath else {
            notice = "The file could not be renamed."
            return
        }
        switch FileRename.perform(source: url, typed: typed) {
        case .failure(let problem):
            let label: String
            if case .success(let cleaned) = FileRename.cleaned(typed) {
                label = cleaned
            } else {
                label = typed
            }
            if let message = FileRename.message(for: problem, name: label) {
                notice = message
            }
        case .success(let dest):
            let newRel = FileRename.relocatedPath(relative, fileName: dest.lastPathComponent)
            let originalName = url.lastPathComponent
            moveBusy = true
            notice = "Renaming \(dest.lastPathComponent)…"
            Task {
                await self.finishRenamedFile(
                    originalName: originalName,
                    dest: dest,
                    oldRel: relative,
                    newRel: newRel
                )
            }
        }
    }

    /// Records a file the Disk grid already renamed. The caller moves the file back when this fails.
    func recordRenamedFile(from old: URL, to dest: URL) async -> LibraryFolderRenameFollow {
        guard let oldRel = DisplayFolder.prefix(selected: old, libraryRoot: libraryRoot),
              let newRel = DisplayFolder.prefix(selected: dest, libraryRoot: libraryRoot),
              oldRel != newRel else {
            return .outside
        }
        let held = moveBusy
        if !held { moveBusy = true }
        defer { if !held { moveBusy = false } }
        switch await followRenamedFile(from: oldRel, to: newRel) {
        case .updated:
            await adoptRenamedFile(from: oldRel, to: newRel)
            return .updated
        case .unsettled:
            await adoptRenamedFile(from: oldRel, to: newRel)
            return .unsettled
        case .restore:
            return .failed
        }
    }

    private func finishRenamedFile(
        originalName: String,
        dest: URL,
        oldRel: String,
        newRel: String
    ) async {
        defer { moveBusy = false }
        let name = dest.lastPathComponent
        switch await followRenamedFile(from: oldRel, to: newRel) {
        case .updated:
            await adoptRenamedFile(from: oldRel, to: newRel)
            notice = "Renamed to \(name)."
        case .unsettled:
            await adoptRenamedFile(from: oldRel, to: newRel)
            notice = "Renamed to \(name). The catalog may still be catching up."
        case .restore:
            if case .success = FileRename.perform(source: dest, typed: originalName) {
                notice = "The file stayed as it is. The catalog could not follow the new name."
            } else {
                notice = "Renamed to \(name). The catalog could not follow the new name."
            }
        }
    }

    /// Asks the helper to follow a file that is already at its new name.
    /// A timed-out reply is asked once more. The file stays put when that reply
    /// also fails to arrive, and when the second reply says the name is taken.
    private func followRenamedFile(from oldRel: String, to newRel: String) async -> RenamedFolderReply {
        switch await client.renameFile(from: oldRel, to: newRel) {
        case .updated:
            return .updated
        case .timedOut:
            switch await client.renameFile(from: oldRel, to: newRel) {
            case .updated, .refused:
                return .updated
            case .timedOut, .offline:
                return .unsettled
            case .unsupported:
                return .restore
            }
        case .offline, .refused, .unsupported:
            return .restore
        }
    }

    /// The open folder reads the new file name. The same asset id stays on the row.
    private func adoptRenamedFile(from oldRel: String, to newRel: String) async {
        let ext = (newRel as NSString).pathExtension
        func shift(_ asset: inout LibraryAsset) {
            guard asset.relPath == oldRel else { return }
            asset.relPath = newRel
            asset.ext = ext
        }
        rows.removeAll { $0.relPath == newRel }
        for index in rows.indices { shift(&rows[index]) }
        reviewRows.removeAll { $0.relPath == newRel }
        for index in reviewRows.indices { shift(&reviewRows[index]) }
        for page in stillPages.indices {
            stillPages[page].removeAll { $0.relPath == newRel }
            for index in stillPages[page].indices { shift(&stillPages[page][index]) }
        }
        folderVideos.removeAll { $0.relPath == newRel }
        for index in folderVideos.indices { shift(&folderVideos[index]) }
        for group in duplicateGroups.indices {
            if duplicateGroups[group].keeper?.relPath == newRel {
                duplicateGroups[group].keeper = nil
            }
            if var keeper = duplicateGroups[group].keeper {
                shift(&keeper)
                duplicateGroups[group].keeper = keeper
            }
            duplicateGroups[group].members.removeAll { $0.relPath == newRel }
            for index in duplicateGroups[group].members.indices {
                shift(&duplicateGroups[group].members[index])
            }
        }
        resetFolderPages()
        await reload(media: "photo")
    }

    /// Applications that can open this file. ZImager is first for a still. QuickTime Player is first for a video.
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

    /// Stills in the section on screen, in the order the grid shows them.
    func listedImages() -> [LibraryAsset] {
        let pool: [LibraryAsset]
        switch librarySection {
        case "Review":
            pool = reviewRows
        case "Duplicates":
            pool = duplicateGroups.flatMap(\.members)
        default:
            pool = rows
        }
        return pool.filter { canOpenInEditor($0) }
    }

    func canStepImage(by delta: Int, matching url: URL?) -> Bool {
        guard let url, let index = listedImages().firstIndex(where: { sameFile($0, as: url) }) else { return false }
        return listedImages().indices.contains(index + delta)
    }

    /// Opens the still delta places away and selects it in the grid.
    func stepImage(by delta: Int, matching url: URL?) {
        let images = listedImages()
        guard let url, let index = images.firstIndex(where: { sameFile($0, as: url) }) else { return }
        let next = index + delta
        guard images.indices.contains(next) else { return }
        let asset = images[next]
        selectRow(asset.uid, shift: false, order: images.map(\.uid))
        openInEditor(asset)
    }

    private func sameFile(_ asset: LibraryAsset, as url: URL) -> Bool {
        guard let file = fileURL(for: asset) else { return false }
        return FolderEntry.cacheKey(for: file) == FolderEntry.cacheKey(for: url)
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
        if stillPages.contains(where: { $0.contains(where: needsVisiblePreview) }) {
            return "Making previews for the rest of this folder."
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

    private func rememberEditedFile(for asset: LibraryAsset) {
        guard editedJPEG[asset.uid] == nil, let url = fileURL(for: asset) else { return }
        if let data = FolderPreviewCache.readEditedJPEG(for: url) {
            editedJPEG[asset.uid] = data
            return
        }
        let working = libraryRoot
            .appendingPathComponent(".zimage", isDirectory: true)
            .appendingPathComponent("edits", isDirectory: true)
            .appendingPathComponent(asset.uid + ".zjpg")
        guard FileManager.default.isReadableFile(atPath: working.path),
              let data = FolderPreviewCache.storeEditedJPEG(fromWorkingFile: working, for: url) else { return }
        editedJPEG[asset.uid] = data
    }

    private func loadThumbnails() async {
        for asset in rows {
            rememberEditedFile(for: asset)
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
            rememberEditedFile(for: asset)
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
