import AppKit
import ImageIO
import SwiftUI

/// A side panel. A typed date is confidence 1.0. It does not open a modal.
struct DateInspector: View {
    @Bindable var browser: LibraryBrowser
    @State private var captureText = ""
    @State private var header = ReviewHeaderFacts(opened: false, lines: [])

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
            Text("Date")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChromePalette.ink)
            if let asset = selectedAsset {
                ForEach(ReviewCatalogFacts.lines(for: asset), id: \.self) { line in
                    inspectorLine(line)
                }
                ForEach(PathCapture.lines(for: asset.relPath), id: \.self) { line in
                    inspectorLine(line)
                }
                ForEach(header.lines, id: \.self) { line in
                    inspectorLine(line)
                }
                if header.opened && !header.hasDate && !selectedIsVideo {
                    inspectorLine("No DateTimeOriginal, DateTimeDigitized, or DateTime tag was in the file header.")
                }
            } else {
                Text("Select a file to see its preview and the date stored for it.")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("YYYY-MM-DD or year", text: $captureText)
                .textFieldStyle(.roundedBorder)
            Button("Set date") {
                let typed = captureText
                Task { await browser.setCaptureDate(typed) }
            }
            .disabled(browser.dateTargets().isEmpty || browser.dateBusy || browser.removalBusy || browser.cleanBusy)
            if showsUserConfidence {
                Text("Confidence 1.0")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityIdentifier("Date inspector")
        .task(id: browser.selectedUID) {
            await showSelection()
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let uid = browser.selectedUID, let data = browser.displayImageData(uid: uid), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 180)
                .accessibilityIdentifier("Review preview")
        } else if browser.selectedUID != nil {
            RoundedRectangle(cornerRadius: 4)
                .fill(ChromePalette.hairline)
                .frame(height: 120)
                .overlay {
                    Text(previewCaption)
                        .font(.system(size: 12))
                        .foregroundStyle(ChromePalette.ink)
                        .multilineTextAlignment(.center)
                        .padding(8)
                }
                .accessibilityIdentifier("Review preview")
        }
    }

    private var previewCaption: String {
        guard let uid = browser.selectedUID, let cell = browser.cells[uid] else {
            return "Loading preview"
        }
        if cell.badge == "No preview" || cell.placeholder {
            return "No preview is stored for this file."
        }
        return "Loading preview"
    }

    private func showSelection() async {
        header = ReviewHeaderFacts(opened: false, lines: [])
        let uid = browser.selectedUID
        captureText = ReviewCatalogFacts.editableDate(selectedAsset?.captureTime)
        await browser.ensurePreview(for: uid)
        guard let uid, browser.selectedUID == uid, let asset = selectedAsset, let url = browser.fileURL(for: asset) else {
            return
        }
        let video = selectedIsVideo
        let facts = await Task.detached(priority: .userInitiated) {
            if video {
                return MovieHeaderFacts.read(url)
            }
            return ReviewHeaderFacts.read(url)
        }.value
        if browser.selectedUID == uid {
            header = facts
        }
    }

    private func inspectorLine(_ line: String) -> some View {
        Text(line)
            .font(.system(size: 12))
            .foregroundStyle(ChromePalette.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var selectedAsset: LibraryAsset? {
        guard let uid = browser.selectedUID else { return nil }
        if let asset = browser.reviewRows.first(where: { $0.uid == uid }) { return asset }
        if let asset = browser.rows.first(where: { $0.uid == uid }) { return asset }
        for group in browser.duplicateGroups {
            if let asset = group.members.first(where: { $0.uid == uid }) {
                return asset
            }
        }
        return nil
    }

    private var showsUserConfidence: Bool {
        if browser.notice == "Confidence 1.0" { return true }
        return selectedAsset?.captureSource == "user" || selectedAsset?.captureConfidence == 1
    }

    private var selectedIsVideo: Bool {
        guard let asset = selectedAsset else { return false }
        if asset.mediaClass == "video" { return true }
        let ext = (asset.ext ?? "").lowercased()
        return LibraryItemMenu.videoExtensions.contains(ext)
    }
}

/// Creation time, duration, picture size, and codec from the movie header.
/// The first 1 MB and the last 1 MB are read. Frames are not decoded.
enum MovieHeaderFacts {
    private nonisolated static let window = 1 << 20
    private nonisolated static let quickTimeEpoch = Date(timeIntervalSince1970: -2_082_844_800)

    nonisolated static func read(_ url: URL) -> ReviewHeaderFacts {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ReviewHeaderFacts(opened: false, lines: ["The file could not be read from the library folder."])
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else {
            return ReviewHeaderFacts(opened: false, lines: ["The file could not be read from the library folder."])
        }
        let head = readRange(handle, offset: 0, count: min(size, UInt64(window)))
        var parsed = parse(head)
        if size > UInt64(window) {
            let tail = readRange(handle, offset: size - UInt64(window), count: UInt64(window))
            parsed.merge(parse(tail))
        }
        return ReviewHeaderFacts(opened: true, lines: parsed.lines())
    }

    private nonisolated static func readRange(_ handle: FileHandle, offset: UInt64, count: UInt64) -> [UInt8] {
        guard count > 0, (try? handle.seek(toOffset: offset)) != nil else { return [] }
        return [UInt8]((try? handle.read(upToCount: Int(count))) ?? Data())
    }

    private nonisolated struct Parsed: Sendable {
        var created: Date?
        var duration: Double?
        var width: Int?
        var height: Int?
        var videoCodec: String?
        var audioCodec: String?

        nonisolated mutating func merge(_ other: Parsed) {
            if created == nil { created = other.created }
            if duration == nil { duration = other.duration }
            if width == nil { width = other.width }
            if height == nil { height = other.height }
            if videoCodec == nil { videoCodec = other.videoCodec }
            if audioCodec == nil { audioCodec = other.audioCodec }
        }

        nonisolated func lines() -> [String] {
            var lines: [String] = []
            if let created {
                lines.append("Container created \(Self.stamp(created))")
            }
            if let duration, duration > 0 {
                lines.append(Self.durationLine(duration))
            }
            if let width, let height, width > 0, height > 0 {
                lines.append("\(width) × \(height)")
            }
            if let videoCodec { lines.append("Video codec \(videoCodec)") }
            if let audioCodec { lines.append("Audio codec \(audioCodec)") }
            if lines.isEmpty {
                lines.append("No duration, picture size, or creation time was in the movie header.")
            }
            return lines
        }

        private nonisolated static func stamp(_ date: Date) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            return String(
                format: "%04d-%02d-%02d %02d:%02d:%02d UTC",
                parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
            )
        }

        private nonisolated static func durationLine(_ seconds: Double) -> String {
            if seconds < 60 {
                return String(format: "Duration %.1f s", seconds)
            }
            let total = Int(seconds.rounded())
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let secs = total % 60
            if hours > 0 {
                return String(format: "Duration %d:%02d:%02d", hours, minutes, secs)
            }
            return String(format: "Duration %d:%02d", minutes, secs)
        }
    }

    private nonisolated static func parse(_ buf: [UInt8]) -> Parsed {
        if let moov = moovPayload(buf) {
            return walk(moov, handler: nil)
        }
        return scan(buf)
    }

    private nonisolated static func moovPayload(_ buf: [UInt8]) -> [UInt8]? {
        let needle: [UInt8] = [0x6D, 0x6F, 0x6F, 0x76]
        var index = 0
        while index + 4 <= buf.count {
            guard let found = indexOf(needle, in: buf, from: index) else { return nil }
            if found >= 4 {
                let size32 = u32(buf, found - 4)
                if size32 == 1, found + 12 <= buf.count {
                    let large = u64(buf, found + 4)
                    if large >= 16 && large < 32 << 20 {
                        let start = found + 12
                        let end = min(buf.count, (found - 4) + Int(min(large, UInt64(buf.count))))
                        if start < end { return Array(buf[start..<end]) }
                    }
                } else if size32 >= 8 && size32 < 32 << 20 {
                    let start = found + 4
                    let end = min(buf.count, (found - 4) + Int(size32))
                    if start < end { return Array(buf[start..<end]) }
                }
            }
            index = found + 4
        }
        return nil
    }

    private nonisolated static func walk(_ buf: [UInt8], handler: String?) -> Parsed {
        var parsed = Parsed()
        var current = handler
        var offset = 0
        while offset + 8 <= buf.count {
            var size = Int(u32(buf, offset))
            let kind = ascii(buf, offset + 4, 4)
            var header = 8
            if size == 1, offset + 16 <= buf.count {
                let large = u64(buf, offset + 8)
                if large > UInt64(Int.max) { break }
                size = Int(large)
                header = 16
            }
            if size < header { break }
            let end = offset + size
            let payloadEnd = min(end, buf.count)
            guard offset + header <= payloadEnd else { break }
            let payload = Array(buf[(offset + header)..<payloadEnd])
            switch kind {
            case "mvhd":
                if let movie = mvhd(payload) {
                    parsed.created = movie.created
                    parsed.duration = movie.duration
                }
            case "tkhd":
                if let size = tkhd(payload), size.width > 0, size.height > 0 {
                    parsed.width = size.width
                    parsed.height = size.height
                }
            case "hdlr":
                if payload.count >= 12 { current = ascii(payload, 8, 4) }
            case "stsd":
                if let codec = stsd(payload) {
                    if current == "vide", parsed.videoCodec == nil { parsed.videoCodec = codec }
                    if current == "soun", parsed.audioCodec == nil { parsed.audioCodec = codec }
                }
            case "moov", "trak", "mdia", "minf", "stbl":
                parsed.merge(walk(payload, handler: current))
            default:
                break
            }
            if end > buf.count { break }
            offset = end
        }
        return parsed
    }

    private nonisolated static func scan(_ buf: [UInt8]) -> Parsed {
        var parsed = Parsed()
        var index = 0
        while index + 8 <= buf.count {
            let kind = ascii(buf, index, 4)
            if kind == "mvhd", let movie = mvhd(Array(buf[(index + 4)...])) {
                if parsed.created == nil { parsed.created = movie.created }
                if parsed.duration == nil { parsed.duration = movie.duration }
            } else if kind == "tkhd", let size = tkhd(Array(buf[(index + 4)...])), size.width > 0, size.height > 0 {
                if parsed.width == nil {
                    parsed.width = size.width
                    parsed.height = size.height
                }
            }
            index += 1
        }
        return parsed
    }

    private nonisolated static func mvhd(_ payload: [UInt8]) -> (created: Date, duration: Double)? {
        guard let version = payload.first else { return nil }
        let seconds: UInt64
        let scale: UInt32
        let duration: UInt64
        if version == 0 {
            guard payload.count >= 20 else { return nil }
            seconds = UInt64(u32(payload, 4))
            scale = u32(payload, 12)
            duration = UInt64(u32(payload, 16))
        } else if version == 1 {
            guard payload.count >= 32 else { return nil }
            seconds = u64(payload, 4)
            scale = u32(payload, 20)
            duration = u64(payload, 24)
        } else {
            return nil
        }
        if seconds == 0 || seconds > 200 * 365 * 24 * 3600 || scale == 0 { return nil }
        let created = quickTimeEpoch.addingTimeInterval(TimeInterval(seconds))
        return (created, Double(duration) / Double(scale))
    }

    private nonisolated static func tkhd(_ payload: [UInt8]) -> (width: Int, height: Int)? {
        guard let version = payload.first else { return nil }
        let start = version == 0 ? 76 : (version == 1 ? 88 : -1)
        guard start >= 0, payload.count >= start + 8 else { return nil }
        let width = Int((Double(u32(payload, start)) / 65536).rounded())
        let height = Int((Double(u32(payload, start + 4)) / 65536).rounded())
        return (width, height)
    }

    private nonisolated static func stsd(_ payload: [UInt8]) -> String? {
        guard payload.count >= 16, u32(payload, 4) >= 1 else { return nil }
        let codec = ascii(payload, 12, 4)
        return codec.isEmpty ? nil : codec
    }

    private nonisolated static func indexOf(_ needle: [UInt8], in buf: [UInt8], from start: Int) -> Int? {
        guard needle.count == 4, start >= 0 else { return nil }
        var index = start
        while index + 4 <= buf.count {
            if buf[index] == needle[0], buf[index + 1] == needle[1], buf[index + 2] == needle[2], buf[index + 3] == needle[3] {
                return index
            }
            index += 1
        }
        return nil
    }

    private nonisolated static func u32(_ buf: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= buf.count else { return 0 }
        return (UInt32(buf[offset]) << 24) | (UInt32(buf[offset + 1]) << 16) | (UInt32(buf[offset + 2]) << 8) | UInt32(buf[offset + 3])
    }

    private nonisolated static func u64(_ buf: [UInt8], _ offset: Int) -> UInt64 {
        guard offset + 8 <= buf.count else { return 0 }
        var value: UInt64 = 0
        for byte in buf[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private nonisolated static func ascii(_ buf: [UInt8], _ offset: Int, _ count: Int) -> String {
        guard offset >= 0, offset + count <= buf.count else { return "" }
        return String(bytes: buf[offset..<(offset + count)], encoding: .ascii) ?? ""
    }
}

enum ReviewCatalogFacts {
    static func lines(for asset: LibraryAsset) -> [String] {
        var lines = [asset.relPath ?? asset.uid]
        if let time = asset.captureTime, !time.isEmpty {
            lines.append("Catalog date \(time)")
        } else {
            lines.append("No date is stored in the catalog.")
        }
        if let source = asset.captureSource, !source.isEmpty {
            lines.append("Catalog source \(source)")
        } else {
            lines.append("No capture source is stored.")
        }
        if let confidence = asset.captureConfidence {
            lines.append(String(format: "Catalog confidence %.2f", confidence))
        } else {
            lines.append("Catalog confidence is not stored.")
        }
        let kind = [asset.mediaClass, asset.ext].compactMap { $0 }.filter { !$0.isEmpty }
        if !kind.isEmpty {
            lines.append(kind.joined(separator: " "))
        }
        if let phase = asset.phase, !phase.isEmpty {
            lines.append("Phase \(phase)")
        }
        return lines
    }

    /// A stored year or calendar day, ready for the date field. An empty catalog date stays blank.
    static func editableDate(_ captureTime: String?) -> String {
        guard let captureTime, !captureTime.isEmpty else { return "" }
        if captureTime.count == 4, captureTime.allSatisfy(\.isNumber) {
            return captureTime
        }
        if captureTime.count >= 10 {
            let day = String(captureTime.prefix(10))
            if day.count == 10, day[day.index(day.startIndex, offsetBy: 4)] == "-", day[day.index(day.startIndex, offsetBy: 7)] == "-" {
                return day
            }
        }
        return captureTime
    }
}

struct ReviewHeaderFacts: Equatable, Sendable {
    var opened: Bool
    var lines: [String]

    var hasDate: Bool {
        lines.contains { $0.hasPrefix("DateTime") }
    }

    nonisolated static func read(_ url: URL) -> ReviewHeaderFacts {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return ReviewHeaderFacts(opened: false, lines: ["The file could not be read from the library folder."])
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ReviewHeaderFacts(opened: true, lines: [])
        }
        var lines: [String] = []
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String, !date.isEmpty {
                lines.append("DateTimeOriginal \(date)")
            }
            if let date = exif[kCGImagePropertyExifDateTimeDigitized] as? String, !date.isEmpty {
                lines.append("DateTimeDigitized \(date)")
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let date = tiff[kCGImagePropertyTIFFDateTime] as? String, !date.isEmpty {
            lines.append("DateTime \(date)")
        }
        if let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 {
            lines.append("\(width) × \(height)")
        }
        return ReviewHeaderFacts(opened: true, lines: lines)
    }
}
