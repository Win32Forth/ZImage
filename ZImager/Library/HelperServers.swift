import Foundation

/// The helper build this copy of ZImager installs. It matches buildinfo.Version in the helper.
enum HelperRelease {
    static let version = "1.9.0"

    /// A missing report is an older helper that does not say which build it is.
    static func needsUpdate(running: String?) -> Bool {
        guard let running, !running.isEmpty else { return true }
        return running != version
    }
}

/// True only when the port check saw a refusal. An unknown result must not replace a running helper.
enum HelperReplace {
    static func allowed(portListening: Bool?) -> Bool {
        portListening == false
    }
}

struct HelperServerRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var nasPath: String
    var bookmark: Data
    var host: String
    /// `main`, `mirror`, or empty when this server is not in a mirror pair.
    var duty: String = ""
    /// The main server id, when this record is the mirror.
    var follows: String = ""

    init(id: String, name: String, nasPath: String, bookmark: Data, host: String, duty: String = "", follows: String = "") {
        self.id = id
        self.name = name
        self.nasPath = nasPath
        self.bookmark = bookmark
        self.host = host
        self.duty = duty
        self.follows = follows
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        nasPath = try values.decode(String.self, forKey: .nasPath)
        bookmark = try values.decode(Data.self, forKey: .bookmark)
        host = try values.decode(String.self, forKey: .host)
        duty = try values.decodeIfPresent(String.self, forKey: .duty) ?? ""
        follows = try values.decodeIfPresent(String.self, forKey: .follows) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(nasPath, forKey: .nasPath)
        try values.encode(bookmark, forKey: .bookmark)
        try values.encode(host, forKey: .host)
        try values.encode(duty, forKey: .duty)
        try values.encode(follows, forKey: .follows)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, nasPath, bookmark, host, duty, follows
    }
}

/// Saved servers. The active id selects which host and folder ZImager uses.
enum HelperServerList {
    static let serversKey = "ZImageLibrary.servers"
    static let activeKey = "ZImageLibrary.activeServer"

    static func load(defaults: UserDefaults) -> [HelperServerRecord] {
        guard let data = defaults.data(forKey: serversKey),
              let rows = try? JSONDecoder().decode([HelperServerRecord].self, from: data) else {
            return []
        }
        return rows
    }

    static func save(_ rows: [HelperServerRecord], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        defaults.set(data, forKey: serversKey)
    }

    static func activeID(defaults: UserDefaults) -> String? {
        defaults.string(forKey: activeKey)
    }

    static func active(defaults: UserDefaults) -> HelperServerRecord? {
        let rows = load(defaults: defaults)
        if let id = activeID(defaults: defaults), let row = rows.first(where: { $0.id == id }) {
            return row
        }
        return rows.first
    }

    /// One record from the older single host and folder bookmark, when the list is still empty.
    static func migrate(defaults: UserDefaults) {
        guard load(defaults: defaults).isEmpty,
              let bookmark = defaults.data(forKey: LibraryFolderBookmark.defaultsKey) else {
            return
        }
        let host = defaults.string(forKey: LibraryAppClient.hostDefaultsKey) ?? ""
        let url = LibraryFolderBookmark.resolve(defaults: defaults)
        let name = url.map { proposedName(for: $0, among: []) } ?? "Server"
        let volume = url.flatMap { LibraryFolderBookmark.volumePath(of: $0) }
        let nas = url.map { HelperInstallPaths.suggestedNASPath(libraryPath: $0.path, volumePath: volume) } ?? ""
        let row = HelperServerRecord(
            id: UUID().uuidString,
            name: name,
            nasPath: nas,
            bookmark: bookmark,
            host: HelperClient.isIPv4(host) ? host : ""
        )
        save([row], defaults: defaults)
        defaults.set(row.id, forKey: activeKey)
    }

    static func upsert(_ row: HelperServerRecord, defaults: UserDefaults) {
        var rows = load(defaults: defaults)
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
        save(rows, defaults: defaults)
        defaults.set(row.id, forKey: activeKey)
        apply(row, defaults: defaults)
    }

    static func select(_ id: String, defaults: UserDefaults) -> HelperServerRecord? {
        guard let row = load(defaults: defaults).first(where: { $0.id == id }) else { return nil }
        defaults.set(id, forKey: activeKey)
        apply(row, defaults: defaults)
        return row
    }

    static func remove(id: String, defaults: UserDefaults) -> HelperServerRecord? {
        var rows = load(defaults: defaults)
        rows.removeAll { $0.id == id }
        save(rows, defaults: defaults)
        guard let next = rows.first else {
            defaults.removeObject(forKey: activeKey)
            defaults.removeObject(forKey: LibraryAppClient.hostDefaultsKey)
            return nil
        }
        defaults.set(next.id, forKey: activeKey)
        apply(next, defaults: defaults)
        return next
    }

    static func uniqueName(_ name: String, among rows: [HelperServerRecord]) -> String {
        let base = name.isEmpty ? "Server" : name
        let taken = Set(rows.map(\.name))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Folder name, with the SMB host in front when the share is mounted. Two PhotoVideoAudio shares stay distinct.
    static func proposedName(for root: URL, among rows: [HelperServerRecord]) -> String {
        uniqueName(baseName(for: root), among: rows)
    }

    static func baseName(for root: URL) -> String {
        let folder = root.lastPathComponent.isEmpty ? "Server" : root.lastPathComponent
        guard let source = LibraryPairing.mountSource(forPath: root.path),
              let host = LibraryPairing.mountHost(fromMountSource: source) else {
            return folder
        }
        let short = shortMountHost(host)
        if short.isEmpty { return folder }
        return "\(short) · \(folder)"
    }

    static func shortMountHost(_ host: String) -> String {
        let smb = "._smb._tcp.local"
        if host.hasSuffix(smb) { return String(host.dropLast(smb.count)) }
        if host.hasSuffix(".local") { return String(host.dropLast(".local".count)) }
        return host
    }

    static func store(_ rows: [HelperServerRecord], defaults: UserDefaults) {
        save(rows, defaults: defaults)
        guard let id = activeID(defaults: defaults),
              let row = rows.first(where: { $0.id == id }) else { return }
        defaults.set(row.duty, forKey: MirrorRoster.dutyKey)
    }

    private static func apply(_ row: HelperServerRecord, defaults: UserDefaults) {
        defaults.set(row.bookmark, forKey: LibraryFolderBookmark.defaultsKey)
        defaults.set(row.duty, forKey: MirrorRoster.dutyKey)
        if HelperClient.isIPv4(row.host) {
            defaults.set(row.host, forKey: LibraryAppClient.hostDefaultsKey)
        } else {
            defaults.removeObject(forKey: LibraryAppClient.hostDefaultsKey)
        }
    }
}

enum HelperInstallPaths {
    /// The helper scans a `Photos` folder inside the library base. Choosing that folder itself uses its parent.
    static func libraryBase(forChosen url: URL) -> URL {
        guard url.lastPathComponent.caseInsensitiveCompare("Photos") == .orderedSame else { return url }
        let parent = url.deletingLastPathComponent()
        guard parent.path != "/", parent.lastPathComponent != "Volumes" else { return url }
        guard containsYearFolder(url) else { return url }
        return parent
    }

    /// A year folder such as `1998` means this directory is the photo library, not the folder that contains it.
    static func containsYearFolder(_ url: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        for name in names {
            guard name.count == 4, name.allSatisfy(\.isNumber) else { continue }
            var isDirectory: ObjCBool = false
            let path = url.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return true
            }
        }
        return false
    }

    /// The Mac mount `/Volumes/BackupData/PhotoVideoAudio` becomes `/volume1/BackupData/PhotoVideoAudio`.
    static func suggestedNASPath(libraryPath: String, volumePath: String?) -> String {
        let library = trimSlash(libraryPath)
        let volume: String?
        if let volumePath {
            volume = trimSlash(volumePath)
        } else {
            volume = nil
        }
        if let volume {
            if library == volume {
                return "/volume1/" + (library as NSString).lastPathComponent
            }
            if library.hasPrefix(volume + "/") {
                let suffix = String(library.dropFirst(volume.count))
                return "/volume1/" + (volume as NSString).lastPathComponent + suffix
            }
        }
        return "/volume1/" + (library as NSString).lastPathComponent
    }

    /// A Synology path the boot task can run. Empty when the text is not a single absolute path.
    static func cleanNASPath(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//"), trimmed != "/", !trimmed.hasSuffix("/") else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        // A leading slash leaves one empty component at the front. A later empty component is `//`.
        guard let first = parts.first, first.isEmpty, parts.count >= 2 else { return nil }
        if parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return nil }
        return trimmed
    }

    static let stopTaskName = "zimage-helper-stop"

    static func taskCommand(nasPath: String) -> String {
        let root = nasPath.hasSuffix("/") ? String(nasPath.dropLast()) : nasPath
        return "sh " + shellQuote(root + "/.zimage/bin/" + HelperPackage.scriptName)
    }

    /// A DSM script that stops the helper on this server. It does not remove photos or the catalog.
    /// The launcher script is named zimage-helper. After it starts, the process is the CPU binary.
    static func stopCommand(nasPath: String) -> String {
        let root = nasPath.hasSuffix("/") ? String(nasPath.dropLast()) : nasPath
        let pid = shellQuote(root + "/.zimage/helper.pid")
        let arm = HelperPackage.armName
        let intel = HelperPackage.intelName
        return """
        PIDFILE=\(pid)
        # The running program is \(arm) or \(intel). Linux shortens those names to 15 characters.
        is_helper() {
          exe=$(readlink "/proc/$1/exe" 2>/dev/null) || exe=
          comm=$(cat "/proc/$1/comm" 2>/dev/null) || comm=
          argv0=$(tr '\\0' '\\n' < "/proc/$1/cmdline" 2>/dev/null | head -n 1) || argv0=
          case "$exe" in
            *\(arm)*|*\(intel)*) return 0 ;;
          esac
          case "$argv0" in
            *\(arm)*|*\(intel)*) return 0 ;;
          esac
          case "$comm" in
            zimage-helper-a*|zimage-helper-x*) return 0 ;;
          esac
          return 1
        }
        stop_one() {
          sig=$1
          target=$2
          [ -n "$target" ] || return 0
          [ "$target" = "$$" ] && return 0
          [ "$target" = "$PPID" ] && return 0
          is_helper "$target" || return 0
          kill "$sig" "$target" 2>/dev/null || true
        }
        stop_helper() {
          sig=$1
          if [ -f "$PIDFILE" ]; then
            stop_one "$sig" "$(cat "$PIDFILE")"
          fi
          for dir in /proc/[0-9]*; do
            [ -d "$dir" ] || continue
            stop_one "$sig" "${dir#/proc/}"
          done
        }
        stop_helper -TERM
        sleep 1
        stop_helper -KILL
        """
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func trimSlash(_ path: String) -> String {
        if path.count > 1, path.hasSuffix("/") { return String(path.dropLast()) }
        return path
    }
}

enum HelperPackage {
    static let scriptName = "zimage-helper"
    static let armName = "zimage-helper-aarch64"
    static let intelName = "zimage-helper-x86_64"
    static let versionName = "VERSION"

    static func script() -> String {
        """
        #!/bin/sh
        # Started by DSM Task Scheduler. ZImager copies this file onto the share.
        set -e
        HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
        ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
        CATALOG="$ROOT/.zimage/catalog"
        mkdir -p "$CATALOG"
        chattr +C "$CATALOG" 2>/dev/null || true
        ARCH=$(uname -m)
        case "$ARCH" in
          aarch64|arm64) BIN="$HERE/\(armName)" ;;
          x86_64|amd64) BIN="$HERE/\(intelName)" ;;
          *)
            echo "ZImager has no helper for CPU $ARCH." >&2
            exit 1
            ;;
        esac
        if [ ! -f "$ROOT/.zimage/config.yaml" ]; then
          cat > "$ROOT/.zimage/config.yaml" << EOF
        listen: "0.0.0.0:8742"
        library_root_local: "$ROOT"
        scope_relative: "Photos"
        cache_operating_bytes: 200000000000
        cache_hard_bytes: 1000000000000
        EOF
        fi
        chmod 0700 "$BIN" 2>/dev/null || true
        export GOMEMLIMIT=160MiB
        exec "$BIN" -config "$ROOT/.zimage/config.yaml"
        """
    }

    static func binDirectory(libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(".zimage", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    static func programInstalled(at libraryRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: binDirectory(libraryRoot: libraryRoot).appendingPathComponent(scriptName).path)
    }

    /// True when this share already has a helper program whose VERSION file is missing or older.
    static func offerUpdate(at libraryRoot: URL) -> Bool {
        let version = versionFile(at: libraryRoot)
        guard programInstalled(at: libraryRoot) || version != nil else { return false }
        return HelperRelease.needsUpdate(running: version)
    }

    static func versionFile(at libraryRoot: URL) -> String? {
        let url = binDirectory(libraryRoot: libraryRoot).appendingPathComponent(versionName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func install(libraryRoot: URL, arm: URL, intel: URL, version: String) throws {
        let bin = binDirectory(libraryRoot: libraryRoot)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try copyFile(arm, to: bin.appendingPathComponent(armName))
        try copyFile(intel, to: bin.appendingPathComponent(intelName))
        let scriptURL = bin.appendingPathComponent(scriptName)
        try script().write(to: scriptURL, atomically: true, encoding: .utf8)
        try (version + "\n").write(to: bin.appendingPathComponent(versionName), atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Removes the helper program. The catalog, photos, and token stay.
    static func removeProgram(at libraryRoot: URL) throws {
        let bin = binDirectory(libraryRoot: libraryRoot)
        for name in [scriptName, armName, intelName, versionName] {
            let url = bin.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func copyFile(_ source: URL, to dest: URL) throws {
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }
}

extension LibraryFolderBookmark {
    static func volumePath(of url: URL) -> String? {
        guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
        return volume.path
    }
}
