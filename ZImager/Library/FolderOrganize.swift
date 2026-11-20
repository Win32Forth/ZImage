import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One page of a Server folder. Undated stills go to `Photos/_Review`.
/// A catalog date, DateTimeOriginal, DateTimeDigitized, or DateTime goes to `Photos/YYYY/YYYY-MM-DD`.
/// A same-size neighbor, or a renamed collision, leaves a preview JPEG in `Photos/_Duplicates`.
nonisolated enum FolderOrganize {
    static let reviewFolder = "Photos/_Review"
    static let duplicatesFolder = "Photos/_Duplicates"
    private static let previewByteCap = 2_000_000

    struct Day: Equatable, Sendable {
        var year: Int
        var month: Int
        var day: Int

        var folder: String {
            String(format: "Photos/%04d/%04d-%02d-%02d", year, year, month, day)
        }
    }

    struct Neighbor: Equatable, Sendable {
        var name: String
        var size: Int64
    }

    /// Photos, and a folder inside it. The duplicates store and the removal shelf stay put.
    static func allows(_ folder: String) -> Bool {
        let parts = folder.split(separator: "/").map(String.init)
        guard parts.first == "Photos", parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            return false
        }
        if parts.contains("_Duplicates") || parts.contains("_Removed") { return false }
        return true
    }

    static func folder(for day: Day?) -> String {
        day?.folder ?? reviewFolder
    }

    /// The file already lives in Photos/YYYY/YYYY-MM-DD, or in a folder inside that day.
    static func alreadyPlaced(path: String, day: Day) -> Bool {
        path.hasPrefix(day.folder + "/")
    }

    /// DateTimeOriginal, then DateTimeDigitized, then DateTime, when that day is the folder day.
    /// A header that does not match is skipped. DateTime does not read the Original or Digitized line.
    static func headerMatches(day: Day, headerLines: [String]) -> Bool {
        for label in headerLabels {
            guard let value = headerValue(label: label, headerLines: headerLines) else { continue }
            if parse(value) == day { return true }
        }
        return false
    }

    /// Catalog confidence 0.00. A missing confidence is left alone.
    static func confidenceIsZero(_ confidence: Double?) -> Bool {
        confidence == 0
    }

    /// Catalog first, then DateTimeOriginal, DateTimeDigitized, and DateTime.
    /// A day that is not on the calendar is ignored.
    static func day(catalog: String?, headerLines: [String]) -> Day? {
        if let catalog, let day = parse(catalog) { return day }
        for label in headerLabels {
            guard let value = headerValue(label: label, headerLines: headerLines) else { continue }
            if let day = parse(value) { return day }
        }
        return nil
    }

    /// Another file of the same size, or a move that had to pick a new name.
    static func isDuplicate(sourceName: String, placedName: String, placedSize: Int64, neighbors: [Neighbor]) -> Bool {
        if sourceName != placedName { return true }
        guard placedSize > 0 else { return false }
        return neighbors.contains { $0.name != placedName && $0.size == placedSize }
    }

    static func referenceFileName(placedPath: String) -> String {
        let base = (placedPath as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let name = stem.isEmpty ? "photo" : stem
        return name + ".jpg"
    }

    static func neighbors(of directory: URL) -> [Neighbor] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var listed: [Neighbor] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            listed.append(Neighbor(name: url.lastPathComponent, size: Int64(values?.fileSize ?? 0)))
        }
        return listed
    }

    /// A small JPEG for the catalog and for a duplicate reference. Nil when the file cannot be reduced.
    static func previewJPEG(from source: URL) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        let storage = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            storage,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let jpeg = storage as Data
        guard !jpeg.isEmpty, jpeg.count <= previewByteCap else { return nil }
        return jpeg
    }

    /// Facts that store a preview and leave the date and the hash alone.
    static func previewFacts(jpeg: Data) -> Data? {
        guard !jpeg.isEmpty, jpeg.count <= previewByteCap else { return nil }
        let body: [String: String] = [
            "dhash": "",
            "thumbnail": jpeg.base64EncodedString(),
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    static func summary(
        reviewed: Int,
        dated: Int,
        duplicates: Int,
        stayed: Int,
        confirmed: Int = 0,
        pages: Int = 1,
        confidenceMissed: Bool = false
    ) -> String {
        let done = reviewed + dated + stayed
        let photos = done == 1 ? "photo" : "photos"
        let lead = pages > 1
            ? "Organized \(pages) pages, \(done) \(photos)."
            : "Organized the first page, \(done) \(photos)."
        var parts = [lead]
        if reviewed > 0 {
            parts.append(reviewed == 1 ? "1 went to Photos/_Review." : "\(reviewed) went to Photos/_Review.")
        }
        if dated > 0 {
            parts.append(dated == 1 ? "1 went to a date folder." : "\(dated) went to date folders.")
        }
        if duplicates > 0 {
            parts.append(duplicates == 1 ? "1 duplicate preview was saved." : "\(duplicates) duplicate previews were saved.")
        }
        if confirmed > 0 {
            parts.append(confirmed == 1 ? "1 catalog confidence was set to 1.00." : "\(confirmed) catalog confidence values were set to 1.00.")
        }
        if confidenceMissed {
            parts.append("Catalog confidence was not stored.")
        }
        if stayed > 0 {
            parts.append(stayed == 1 ? "1 stayed." : "\(stayed) stayed.")
        }
        return parts.joined(separator: " ")
    }

    private static let headerLabels = ["DateTimeOriginal ", "DateTimeDigitized ", "DateTime "]

    /// The text after that label. The DateTime label leaves Original and Digitized for their own labels.
    private static func headerValue(label: String, headerLines: [String]) -> String? {
        for line in headerLines {
            guard line.hasPrefix(label) else { continue }
            if label == "DateTime ", line.hasPrefix("DateTimeOriginal ") || line.hasPrefix("DateTimeDigitized ") {
                continue
            }
            return String(line.dropFirst(label.count))
        }
        return nil
    }

    private static func parse(_ text: String) -> Day? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let head = trimmed.prefix(10)
        let separator: Character
        if head[head.index(head.startIndex, offsetBy: 4)] == "-", head[head.index(head.startIndex, offsetBy: 7)] == "-" {
            separator = "-"
        } else if head[head.index(head.startIndex, offsetBy: 4)] == ":", head[head.index(head.startIndex, offsetBy: 7)] == ":" {
            separator = ":"
        } else {
            return nil
        }
        let pieces = head.split(separator: separator, omittingEmptySubsequences: false)
        guard pieces.count == 3, let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]) else {
            return nil
        }
        guard (1800...2100).contains(year) else { return nil }
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = calendar.date(from: parts),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            return nil
        }
        return Day(year: year, month: month, day: day)
    }
}
