import AppKit
import CryptoKit
import Darwin
import Foundation
import Security
import SwiftUI

// The Mac has no catalog file. This client keeps one in-memory page and drops it on quit.
// ZImage Library presents that page. The editor compiles this type so the tests have a host,
// and does not mount the library pane.

enum LibraryCopy {
    static let staleBanner = "Helper offline. This grid is the last response and is not a saved catalog."
    static let emptyTitle = "Helper offline."
    static let recoveryHint = "Open DSM Task Scheduler and confirm the boot task still runs .zimage/bin/zimage-helper."
}

enum HelperError: Error, Equatable {
    case notIPv4
    case hostChanged
    case pinChanged
    case offline
    case unauthorized
    case keychain

    var message: String {
        switch self {
        case .notIPv4:
            "Helper address is not IPv4"
        case .hostChanged:
            "Helper address changed. Pair again."
        case .pinChanged:
            "Helper certificate changed. Pair again."
        case .offline:
            LibraryCopy.emptyTitle
        case .unauthorized:
            "Helper refused the token."
        case .keychain:
            "The helper token could not be saved."
        }
    }
}

struct HelperCredentials: Equatable, Sendable {
    var host: String
    var port: Int
    var pin: Data
    var token: String

    init(host: String, port: Int = 8742, pin: Data = Data(), token: String = "") {
        self.host = host
        self.port = port
        self.pin = pin
        self.token = token
    }
}

struct HelperResponse: Equatable, Sendable {
    var status: Int
    var body: Data
}

struct LibraryAsset: Decodable, Equatable, Sendable {
    var uid: String
    var relPath: String?
    var ext: String?
    var mediaClass: String?
    var detailScore: Double?
    var nativePixels: Int?
    var isKeeper: Bool?
    var placement: String?
    var pinned: Bool?
    var phase: String?
    var thumbRel: String?
    var decodeSupport: String?
    var captureConfidence: Double?
    var captureTime: String?
    var captureSource: String?
    var width: Int?
    var height: Int?
    var detailSource: String?

    init(
        uid: String,
        relPath: String? = nil,
        ext: String? = nil,
        mediaClass: String? = nil,
        detailScore: Double? = nil,
        nativePixels: Int? = nil,
        isKeeper: Bool? = nil,
        placement: String? = nil,
        pinned: Bool? = nil,
        phase: String? = nil,
        thumbRel: String? = nil,
        decodeSupport: String? = nil,
        captureConfidence: Double? = nil,
        captureTime: String? = nil,
        captureSource: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        detailSource: String? = nil
    ) {
        self.uid = uid
        self.relPath = relPath
        self.ext = ext
        self.mediaClass = mediaClass
        self.detailScore = detailScore
        self.nativePixels = nativePixels
        self.isKeeper = isKeeper
        self.placement = placement
        self.pinned = pinned
        self.phase = phase
        self.thumbRel = thumbRel
        self.decodeSupport = decodeSupport
        self.captureConfidence = captureConfidence
        self.captureTime = captureTime
        self.captureSource = captureSource
        self.width = width
        self.height = height
        self.detailSource = detailSource
    }
}

struct LibraryPage: Decodable, Equatable, Sendable {
    var rows: [LibraryAsset]
    var nextCursor: String
}

struct LibraryEvent: Decodable, Equatable, Sendable {
    var uid: String
    var name: String
    var nameSource: String
    var slug: String
}

private struct LibraryEventPage: Decodable {
    var rows: [LibraryEvent]
}

struct HelperHealth: Decodable, Equatable, Sendable {
    var status: String
    var schemaVersion: Int
    var libraryRootOK: Bool
    var manualOpsClear: Bool
    var reorgSafeToReboot: Bool
    var trimSafeToReboot: Bool
}

struct ReorgStatus: Decodable, Equatable, Sendable {
    var reorgSafeToReboot: Bool
    var runState: String
    var phase: String
    var pauseRequested: Bool
    var move: Int
    var alreadyPlaced: Int
    var park: Int
    var leave: Int
    /// True while the helper is publishing the four counts for the folder it is counting.
    var counting: Bool?
    /// Files the helper has looked at in this count.
    var seen: Int?
    var cacheBytes: Int64
    var rssBytes: Int64
    var lastRecovery: String
}

struct ReorgPlan: Decodable, Equatable, Sendable {
    var move: Int
    var alreadyPlaced: Int
    var park: Int
    var leave: Int
    var prefix: String
}

struct ReorgCall: Equatable, Sendable {
    var status: ReorgStatus?
    var plan: ReorgPlan?
    var error: String?
}

struct TrimStatus: Decodable, Equatable, Sendable {
    var safeToReboot: Bool
    var runState: String
    var pauseRequested: Bool
    var eligible: Int
    var moved: Int
    var waiting: Int
}

struct DuplicateScan: Decodable, Equatable, Sendable {
    var runState: String
    var phase: String
    var done: Int
    var total: Int
    var groups: Int
    var passPhase: String
    var passDone: Int
    var passTotal: Int

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        runState = try values.decodeIfPresent(String.self, forKey: .runState) ?? ""
        phase = try values.decodeIfPresent(String.self, forKey: .phase) ?? ""
        done = try values.decodeIfPresent(Int.self, forKey: .done) ?? 0
        total = try values.decodeIfPresent(Int.self, forKey: .total) ?? 0
        groups = try values.decodeIfPresent(Int.self, forKey: .groups) ?? 0
        passPhase = try values.decodeIfPresent(String.self, forKey: .passPhase) ?? ""
        passDone = try values.decodeIfPresent(Int.self, forKey: .passDone) ?? 0
        passTotal = try values.decodeIfPresent(Int.self, forKey: .passTotal) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case runState, phase, done, total, groups, passPhase, passDone, passTotal
    }
}

enum ScanCall: Equatable, Sendable {
    case status(DuplicateScan)
    case unsupported
    case busy
    case offline
}

struct TrimCall: Equatable, Sendable {
    var status: TrimStatus?
    var error: String?
}

struct DuplicateGroup: Decodable, Equatable, Sendable {
    var uid: String
    var keeper: LibraryAsset?
    var members: [LibraryAsset]
}

struct DuplicatePage: Decodable, Equatable, Sendable {
    var groups: [DuplicateGroup]
    var nextCursor: String
}

struct AssetCall: Equatable, Sendable {
    var asset: LibraryAsset?
    var error: String?
}

struct PurgeAllCall: Equatable, Sendable {
    var purged: Int?
    var error: String?
}

struct FolderCleanCall: Equatable, Sendable {
    var removed: Int?
    var kept: Int?
    var error: String?
}

enum DuplicateCopy {
    static let keeper = "Keeper"
    static let emptyList = "This list shows copies gathered into Photos/_Duplicates. Find duplicates looks for matches. Start gathers the extra copies into this list."
    static let findUnreachable = "Find duplicates got no answer from the helper."
    static let gathered = "Gathered copies are listed here."
    static let scanNeedsHelper = "This helper cannot start a new scan. It records matches only while it is starting up."
    static let scanBusy = "Scan waits until Reorganize and Gather are idle."

    static func count(_ value: Int) -> String {
        let digits = String(value)
        var out = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 {
                out.append(",")
            }
            out.append(character)
        }
        return out
    }

    static func scanLine(_ scan: DuplicateScan?) -> String? {
        guard let scan, scan.runState == "running" else { return nil }
        if scan.total <= 0 {
            switch scan.phase {
            case "comparing":
                return "Preparing to compare photos."
            case "saving":
                return "Saving groups."
            default:
                return "Checking previews for pictures that still need a fingerprint."
            }
        }
        let place = "\(count(scan.done)) of \(count(scan.total))"
        switch scan.phase {
        case "comparing":
            return "Comparing photos, \(place)."
        case "saving":
            return "Saving groups, \(place)."
        default:
            return "Hashing previews, \(place)."
        }
    }

    /// Startup task from the helper's memory buffer. An empty phase hides the line.
    static func passLine(_ scan: DuplicateScan?) -> String? {
        guard let scan, !scan.passPhase.isEmpty else { return nil }
        let name = passName(scan.passPhase)
        if scan.passTotal > 0 {
            let of = passEstimate(scan.passPhase) ? "of about" : "of"
            return "\(name), \(count(scan.passDone)) \(of) \(count(scan.passTotal))."
        }
        if scan.passDone > 0 {
            return "\(name), \(count(scan.passDone)) looked at."
        }
        return "\(name)."
    }

    private static func passEstimate(_ phase: String) -> Bool {
        phase == "inventory" || phase == "relink" || phase == "cache"
    }

    private static func passName(_ phase: String) -> String {
        switch phase {
        case "cache":
            return "Checking the preview cache"
        case "previews":
            return "Making previews"
        case "relink":
            return "Checking files already in the catalog"
        case "presence":
            return "Recording which files are present"
        case "match":
            return "Matching files to the catalog"
        case "inventory":
            return "Looking through Photos"
        case "dating":
            return "Reading dates"
        case "hashing":
            return "Hashing previews"
        case "neighbors":
            return "Matching nearby dates"
        case "events":
            return "Naming events"
        case "scoring":
            return "Scoring sharpness"
        case "comparing":
            return "Comparing photos"
        case "saving":
            return "Saving groups"
        case "planning":
            return "Planning folders"
        case "folder":
            return "Making previews for the folder on screen"
        default:
            return "Working"
        }
    }

    static func scanStopped(_ scan: DuplicateScan) -> String {
        if scan.total > 0 {
            return "The scan stopped at \(count(scan.done)) of \(count(scan.total))."
        }
        return "The scan stopped before it finished."
    }

    static func findResult(groups: Int, eligible: Int?, waiting: Int?) -> String {
        if groups > 0 {
            return "Found \(count(groups)) matching groups. Start gathers the extra copies into Photos/_Duplicates."
        }
        let ready = eligible ?? 0
        let pending = waiting ?? 0
        if ready > 0 {
            return "No copies are in this list yet. \(ready) groups are ready. Start gathers the extra copies into Photos/_Duplicates."
        }
        if pending > 0 {
            return "No group is ready to gather. \(pending) groups are still waiting for a sharpness score."
        }
        return "No matching groups are recorded yet. Matches are added as previews are made."
    }

    static func activity(_ state: String?) -> String? {
        switch state {
        case "running", "pause_requested", "recovering":
            return "Gathering copies."
        case "paused":
            return "Gathering is paused."
        case "blocked":
            return "Gathering stopped. The helper could not copy the next file."
        default:
            return nil
        }
    }

    static func inStore(_ path: String?) -> Bool {
        guard let path else { return false }
        return path == "Photos/_Duplicates" || path.hasPrefix("Photos/_Duplicates/")
    }

    static func placeLine(_ path: String?) -> String? {
        guard let path, !inStore(path) else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "." { return nil }
        return parent
    }

    static func score(_ value: Double) -> String {
        String(format: "Score %.1f", value)
    }

    static func megapixels(_ pixels: Int) -> String {
        String(format: "%.1f MP", Double(pixels) / 1_000_000)
    }

    static func captions(score: Double?, pixels: Int?) -> [String] {
        var lines: [String] = []
        if let score {
            lines.append(self.score(score))
        }
        if let pixels {
            lines.append(megapixels(pixels))
        }
        return lines
    }
}

private struct ReorgErrorBody: Decodable {
    var error: String?
}

struct StoredSecret: Equatable, Codable, Sendable {
    var token: String
    var pinBase64: String
}

struct MemoryTokenStore {
    private var items: [String: StoredSecret] = [:]

    mutating func save(host: String, secret: StoredSecret) {
        items[host] = secret
    }

    func load(host: String) -> StoredSecret? {
        items[host]
    }
}

/// Keychain item for the helper. The account is the IPv4 host. Service name is fixed.
/// A shared access group lets the editor read the item the library saved.
enum KeychainTokenStore {
    static let service = "ZImage NAS Helper"
    static let accessGroup = "X5YCJL3LJ8.com.Win32Forth.ZImage"
    static let currentAccount = "current"

    static func save(host: String, secret: StoredSecret) throws {
        let data = try JSONEncoder().encode(secret)
        try write(account: host, data: data, group: false)
        try? write(account: host, data: data, group: true)
        rememberCurrent(host: host)
    }

    static func load(host: String) throws -> StoredSecret? {
        if let data = try read(account: host, group: true) {
            return try JSONDecoder().decode(StoredSecret.self, from: data)
        }
        guard let data = try read(account: host, group: false) else { return nil }
        return try JSONDecoder().decode(StoredSecret.self, from: data)
    }

    /// Copies the stored host into the shared group so the editor can find it.
    static func rememberCurrent(host: String) {
        guard HelperClient.isIPv4(host) else { return }
        guard let pointer = try? JSONEncoder().encode(CurrentHost(host: host)) else { return }
        try? write(account: currentAccount, data: pointer, group: true)
    }

    static func currentHost() -> String? {
        guard let data = try? read(account: currentAccount, group: true),
              let stored = try? JSONDecoder().decode(CurrentHost.self, from: data),
              HelperClient.isIPv4(stored.host) else {
            return nil
        }
        return stored.host
    }

    private struct CurrentHost: Codable {
        var host: String
    }

    private static func write(account: String, data: Data, group: Bool) throws {
        SecItemDelete(base(account, group: group) as CFDictionary)
        var add = base(account, group: group)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw HelperError.keychain }
    }

    private static func read(account: String, group: Bool) throws -> Data? {
        var query = base(account, group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound || status == errSecMissingEntitlement { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw HelperError.keychain }
        return data
    }

    private static func base(_ account: String, group: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if group {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

enum PairingFile {
    static func token(inLibraryRoot root: URL) throws -> String {
        let url = root.appendingPathComponent(".zimage").appendingPathComponent("PAIRING-TOKEN")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CertificateTrust {
    /// An empty pin learns the certificate. A stored pin must match, or the connection is refused.
    static func decide(pin: inout Data, certificateDER der: Data) -> Bool {
        guard let hash = CertificatePin.sha256(certificateDER: der), !hash.isEmpty else { return false }
        if pin.isEmpty {
            pin = hash
            return true
        }
        return pin == hash
    }
}

enum CertificatePin {
    /// SHA-256 of the certificate's subjectPublicKeyInfo, the same bytes Go exposes as RawSubjectPublicKeyInfo.
    static func sha256(certificateDER der: Data) -> Data? {
        var index = 0
        guard let certificate = readTLV(der, &index), certificate.tag == 0x30 else { return nil }
        var inner = 0
        guard let tbs = readTLV(certificate.content, &inner), tbs.tag == 0x30 else { return nil }
        var cursor = 0
        var children: [TLV] = []
        while cursor < tbs.content.count {
            guard let child = readTLV(tbs.content, &cursor) else { return nil }
            children.append(child)
        }
        let spkiIndex = children.first?.tag == 0xA0 ? 6 : 5
        guard children.indices.contains(spkiIndex), children[spkiIndex].tag == 0x30 else { return nil }
        return Data(SHA256.hash(data: children[spkiIndex].full))
    }

    private struct TLV {
        var tag: UInt8
        var full: Data
        var content: Data
    }

    private static func readTLV(_ data: Data, _ index: inout Int) -> TLV? {
        let start = index
        guard index < data.count else { return nil }
        let tag = data[index]
        index += 1
        guard index < data.count else { return nil }
        var length = Int(data[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, index + count <= data.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(data[index])
                index += 1
            }
        }
        guard index + length <= data.count else { return nil }
        let content = data.subdata(in: index..<(index + length))
        let full = data.subdata(in: start..<(index + length))
        index += length
        return TLV(tag: tag, full: full, content: content)
    }
}

/// Reorg and Trim stay off until the user presses Start in a later PR.
struct FeatureFlags: Sendable {
    var reorgExecution = false
    var trimExecution = false
}

enum EditorHandoff {
    static let editorBundleID = "com.Win32Forth.ZImage"

    static func openFile(_ url: URL, with open: (URL, String) -> Void) {
        open(url, Self.editorBundleID)
    }

    /// A running editor wins over whichever ZImage.app Launch Services has registered.
    static func applicationURL(running: [URL], registered: URL?) -> URL? {
        running.first ?? registered
    }

    @MainActor
    static func openInEditor(_ url: URL) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: editorBundleID)
        let preferred = apps.first(where: \.isActive) ?? apps.first
        let running = preferred?.bundleURL.map { [$0] } ?? []
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editorBundleID)
        guard let appURL = applicationURL(running: running, registered: registered) else { return }
        preferred?.activate(options: [.activateAllWindows])
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
    }
}

final class HelperClient {
    private(set) var credentials: HelperCredentials
    private let send: (URLRequest) async throws -> HelperResponse

    init(credentials: HelperCredentials, send: @escaping (URLRequest) async throws -> HelperResponse) {
        self.credentials = credentials
        self.send = send
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = UInt8(part), String(value) == part else { return false }
            return true
        }
    }

    /// Keeps the first IPv4 address. A name with only IPv6 records is refused and is not dialed.
    static func firstIPv4(from addresses: [String]) throws -> String {
        for address in addresses where isIPv4(address) {
            return address
        }
        throw HelperError.notIPv4
    }

    static func resolveIPv4(host: String) throws -> String {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, nil, &hints, &result)
        defer {
            if let result {
                freeaddrinfo(result)
            }
        }
        guard code == 0, var cursor = result else { throw HelperError.notIPv4 }
        while true {
            if cursor.pointee.ai_family == AF_INET, let address = cursor.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let named = getnameinfo(
                    address,
                    cursor.pointee.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if named == 0 {
                    let numeric = String(cString: buffer)
                    if isIPv4(numeric) {
                        return numeric
                    }
                }
            }
            guard let next = cursor.pointee.ai_next else { break }
            cursor = next
        }
        throw HelperError.notIPv4
    }

    func prepareDial(to host: String) throws {
        guard Self.isIPv4(host) else { throw HelperError.notIPv4 }
        guard host == credentials.host else { throw HelperError.hostChanged }
    }

    func acceptCertificate(_ der: Data) throws {
        guard let hash = CertificatePin.sha256(certificateDER: der) else {
            throw HelperError.pinChanged
        }
        if credentials.pin.isEmpty {
            credentials.pin = hash
            return
        }
        guard credentials.pin == hash else { throw HelperError.pinChanged }
    }

    func rememberPin(_ pin: Data) throws {
        if credentials.pin.isEmpty {
            guard !pin.isEmpty else { throw HelperError.pinChanged }
            credentials.pin = pin
            return
        }
        guard credentials.pin == pin else { throw HelperError.pinChanged }
    }

    func thumbnail(uid: String) async throws -> Data {
        let response = try await perform(path: "/v1/assets/\(uid)/thumbnail", method: "GET", body: nil, authorize: true, timeout: 60)
        guard response.status == 200 else { throw HelperError.offline }
        return response.body
    }

    func assets() async throws -> LibraryPage {
        try await assets(media: nil)
    }

    /// `photo` omits videos. `video` is the movie list, earliest capture day first.
    /// `under` limits the page to paths that contain that folder. The running helper treats `q` as a path search.
    func assets(media: String?, under folder: String? = nil) async throws -> LibraryPage {
        var items: [URLQueryItem] = []
        if let media {
            items.append(URLQueryItem(name: "media", value: media))
        }
        if let folder, let needle = DisplayFolder.needle(folder) {
            items.append(URLQueryItem(name: "q", value: needle))
        }
        items.append(URLQueryItem(name: "limit", value: "200"))
        var parts = URLComponents()
        parts.queryItems = items
        let query = parts.percentEncodedQuery ?? ""
        return try await page(path: "/v1/assets?\(query)")
    }

    func assets(matching text: String) async throws -> LibraryPage {
        var parts = URLComponents()
        parts.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "limit", value: "200"),
        ]
        let query = parts.percentEncodedQuery ?? ""
        return try await page(path: "/v1/assets?\(query)")
    }

    func events() async throws -> [LibraryEvent] {
        let response = try await perform(path: "/v1/events", method: "GET", body: nil, authorize: true)
        guard response.status == 200 else {
            if response.status == 401 { throw HelperError.unauthorized }
            throw HelperError.offline
        }
        return try JSONDecoder().decode(LibraryEventPage.self, from: response.body).rows
    }

    func renameEvent(uid: String, name: String) async throws -> LibraryEvent {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let response = try await perform(
            path: "/v1/events/\(uid)",
            method: "POST",
            body: body,
            authorize: true,
            contentType: "application/json"
        )
        guard response.status == 200 else {
            if response.status == 401 { throw HelperError.unauthorized }
            throw HelperError.offline
        }
        return try JSONDecoder().decode(LibraryEvent.self, from: response.body)
    }

    func reorgStatus() async throws -> ReorgStatus {
        let response = try await perform(path: "/v1/reorg/status", method: "GET", body: nil, authorize: true)
        guard response.status == 200 else {
            if response.status == 401 { throw HelperError.unauthorized }
            throw HelperError.offline
        }
        return try JSONDecoder().decode(ReorgStatus.self, from: response.body)
    }

    func reorgPlan(prefix: String) async throws -> ReorgCall {
        let body = try JSONSerialization.data(withJSONObject: ["prefix": prefix])
        return try await reorgPost(path: "/v1/reorg/plan", body: body)
    }

    func reorgStart() async throws -> ReorgCall {
        try await reorgPost(path: "/v1/reorg/start", body: nil)
    }

    func reorgPause() async throws -> ReorgCall {
        try await reorgPost(path: "/v1/reorg/pause", body: nil)
    }

    func reorgResume() async throws -> ReorgCall {
        try await reorgPost(path: "/v1/reorg/resume", body: nil)
    }

    private func reorgPost(path: String, body: Data?) async throws -> ReorgCall {
        let response = try await perform(
            path: path,
            method: "POST",
            body: body,
            authorize: true,
            contentType: "application/json"
        )
        if response.status == 401 { throw HelperError.unauthorized }
        if response.status == 200 {
            if path.hasSuffix("/plan") {
                let plan = try JSONDecoder().decode(ReorgPlan.self, from: response.body)
                return ReorgCall(plan: plan)
            }
            let status = try JSONDecoder().decode(ReorgStatus.self, from: response.body)
            return ReorgCall(status: status)
        }
        if let error = (try? JSONDecoder().decode(ReorgErrorBody.self, from: response.body))?.error, !error.isEmpty {
            return ReorgCall(error: error)
        }
        throw HelperError.offline
    }

    func trimStatus() async throws -> TrimStatus {
        let response = try await perform(path: "/v1/trim/status", method: "GET", body: nil, authorize: true)
        guard response.status == 200 else {
            if response.status == 401 { throw HelperError.unauthorized }
            throw HelperError.offline
        }
        return try JSONDecoder().decode(TrimStatus.self, from: response.body)
    }

    func trimStart() async throws -> TrimCall {
        try await trimPost(path: "/v1/trim/start")
    }

    func trimPause() async throws -> TrimCall {
        try await trimPost(path: "/v1/trim/pause")
    }

    func trimContinue() async throws -> TrimCall {
        try await trimPost(path: "/v1/trim/continue")
    }

    private func trimPost(path: String) async throws -> TrimCall {
        let response = try await perform(
            path: path,
            method: "POST",
            body: nil,
            authorize: true,
            contentType: "application/json"
        )
        if response.status == 401 { throw HelperError.unauthorized }
        if response.status == 200 {
            let status = try JSONDecoder().decode(TrimStatus.self, from: response.body)
            return TrimCall(status: status)
        }
        if response.status == 400 || response.status == 409 {
            let error = (try? JSONDecoder().decode(ReorgErrorBody.self, from: response.body))?.error
            return TrimCall(error: error)
        }
        throw HelperError.offline
    }

    /// The folder the helper should preview next. An empty prefix clears it.
    /// A helper without this route, or one that does not answer, is ignored.
    func setFocus(prefix: String) async {
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: ["prefix": prefix])
        } catch {
            return
        }
        do {
            _ = try await perform(
                path: "/v1/focus",
                method: "POST",
                body: body,
                authorize: true,
                timeout: 5,
                contentType: "application/json"
            )
        } catch {
            return
        }
    }

    func duplicateScanStatus() async -> ScanCall {
        await scanCall(method: "GET")
    }

    func startDuplicateScan() async -> ScanCall {
        await scanCall(method: "POST")
    }

    private func scanCall(method: String) async -> ScanCall {
        do {
            let response = try await perform(
                path: "/v1/duplicates/scan",
                method: method,
                body: nil,
                authorize: true
            )
            if response.status == 200 {
                if let status = try? JSONDecoder().decode(DuplicateScan.self, from: response.body) {
                    return .status(status)
                }
                return .offline
            }
            if response.status == 404 {
                return .unsupported
            }
            if response.status == 409 {
                return .busy
            }
            if response.status == 401 {
                return .offline
            }
            return .offline
        } catch {
            return .offline
        }
    }

    func duplicates(found: Bool = false) async throws -> DuplicatePage {
        var path = "/v1/duplicates?limit=200"
        if found {
            path += "&found=1"
        }
        let response = try await perform(path: path, method: "GET", body: nil, authorize: true)
        guard response.status == 200 else {
            if response.status == 401 { throw HelperError.unauthorized }
            throw HelperError.offline
        }
        return try JSONDecoder().decode(DuplicatePage.self, from: response.body)
    }

    func moveToDuplicates(uid: String) async throws -> AssetCall {
        try await assetPost(path: "/v1/assets/\(uid)/to-duplicates", body: nil)
    }

    /// Journal-moves one file into Photos/_Removed. The bytes stay there for a later deletion.
    func removeFromLibrary(uid: String) async throws -> AssetCall {
        try await assetPost(path: "/v1/assets/\(uid)/to-removed", body: nil)
    }

    func restoreAsset(uid: String) async throws -> AssetCall {
        try await assetPost(path: "/v1/assets/\(uid)/restore", body: nil)
    }

    func pinAsset(uid: String, pinned: Bool) async throws -> AssetCall {
        let body = try JSONSerialization.data(withJSONObject: ["pinned": pinned])
        return try await assetPost(path: "/v1/assets/\(uid)/pin", body: body)
    }

    func purgeAsset(uid: String, confirmFilename: String) async throws -> AssetCall {
        let body = try JSONSerialization.data(withJSONObject: ["confirmFilename": confirmFilename])
        return try await assetPost(path: "/v1/assets/\(uid)/purge", body: body)
    }

    /// Tombstones leftover catalog rows under one folder. Files on disk stay.
    func cleanFolder(prefix: String) async throws -> FolderCleanCall {
        let body = try JSONSerialization.data(withJSONObject: ["prefix": prefix])
        let response = try await perform(
            path: "/v1/folders/clean",
            method: "POST",
            body: body,
            authorize: true,
            timeout: 300,
            contentType: "application/json"
        )
        if response.status == 401 { throw HelperError.unauthorized }
        if response.status == 200 {
            struct Counts: Decodable {
                var removed: Int
                var kept: Int
            }
            let counts = try JSONDecoder().decode(Counts.self, from: response.body)
            return FolderCleanCall(removed: counts.removed, kept: counts.kept)
        }
        if response.status == 400 || response.status == 409 {
            let error = (try? JSONDecoder().decode(ReorgErrorBody.self, from: response.body))?.error
            return FolderCleanCall(error: error)
        }
        throw HelperError.offline
    }

    func purgeAllDuplicates(confirm: String) async throws -> PurgeAllCall {
        let body = try JSONSerialization.data(withJSONObject: ["confirm": confirm])
        let response = try await perform(
            path: "/v1/duplicates/purge-all",
            method: "POST",
            body: body,
            authorize: true,
            contentType: "application/json"
        )
        if response.status == 401 { throw HelperError.unauthorized }
        if response.status == 200 {
            let decoded = try JSONDecoder().decode(PurgeCount.self, from: response.body)
            return PurgeAllCall(purged: decoded.purged)
        }
        if response.status == 400 || response.status == 409 {
            let error = (try? JSONDecoder().decode(ReorgErrorBody.self, from: response.body))?.error
            return PurgeAllCall(error: error)
        }
        throw HelperError.offline
    }

    private struct PurgeCount: Decodable {
        var purged: Int
    }

    private func assetPost(path: String, body: Data?) async throws -> AssetCall {
        let response = try await perform(
            path: path,
            method: "POST",
            body: body,
            authorize: true,
            contentType: "application/json"
        )
        if response.status == 401 { throw HelperError.unauthorized }
        if response.status == 200 {
            let asset = try JSONDecoder().decode(LibraryAsset.self, from: response.body)
            return AssetCall(asset: asset)
        }
        if response.status == 400 || response.status == 409 {
            let error = (try? JSONDecoder().decode(ReorgErrorBody.self, from: response.body))?.error
            return AssetCall(error: error)
        }
        throw HelperError.offline
    }

    /// A missing sidecar is nil. The bytes are the stored `.zimg`.
    func edits(uid: String) async throws -> Data? {
        let response = try await perform(path: "/v1/edits/\(uid)", method: "GET", body: nil, authorize: true, timeout: 60)
        if response.status == 404 { return nil }
        guard response.status == 200 else {
            if response.status == 401 { throw HelperError.unauthorized }
            throw HelperError.offline
        }
        return response.body
    }

    func putEdits(uid: String, body: Data) async throws {
        let response = try await perform(
            path: "/v1/edits/\(uid)",
            method: "PUT",
            body: body,
            authorize: true,
            timeout: 60,
            contentType: "application/octet-stream"
        )
        guard response.status == 204 else {
            if response.status == 401 { throw HelperError.unauthorized }
            throw HelperError.offline
        }
    }

    /// Park rows from the server `review=1` query.
    func reviewAssets() async throws -> LibraryPage {
        try await page(path: "/v1/assets?review=1&limit=200")
    }

    /// Stores the typed date and journal-moves that file into its date folder.
    func placeCaptureDate(uid: String, captureTime: String) async throws -> AssetCall {
        let body = try JSONSerialization.data(withJSONObject: ["captureTime": captureTime])
        return try await assetPost(path: "/v1/assets/\(uid)/place", body: body)
    }

    func setCaptureDate(uid: String, captureTime: String) async throws -> LibraryAsset {
        let body = try JSONSerialization.data(withJSONObject: ["captureTime": captureTime])
        let response = try await perform(
            path: "/v1/assets/\(uid)/date",
            method: "POST",
            body: body,
            authorize: true,
            contentType: "application/json"
        )
        guard response.status == 200 else {
            if response.status == 401 { throw HelperError.unauthorized }
            throw HelperError.offline
        }
        return try JSONDecoder().decode(LibraryAsset.self, from: response.body)
    }

    func putFacts(uid: String, body: Data) async throws -> Int {
        try await putJSON(path: "/v1/assets/\(uid)/facts", body: body)
    }

    func putDetail(uid: String, body: Data) async throws -> Int {
        try await putJSON(path: "/v1/assets/\(uid)/detail", body: body)
    }

    private func page(path: String) async throws -> LibraryPage {
        let response = try await perform(path: path, method: "GET", body: nil, authorize: true)
        guard response.status == 200 else {
            if response.status == 401 { throw HelperError.unauthorized }
            throw HelperError.offline
        }
        return try JSONDecoder().decode(LibraryPage.self, from: response.body)
    }

    private func putJSON(path: String, body: Data) async throws -> Int {
        let response = try await perform(
            path: path,
            method: "PUT",
            body: body,
            authorize: true,
            contentType: "application/json"
        )
        return response.status
    }

    func health() async throws -> HelperHealth {
        let response = try await perform(path: "/v1/health", method: "GET", body: nil, authorize: false)
        guard response.status == 200 else { throw HelperError.offline }
        return try JSONDecoder().decode(HelperHealth.self, from: response.body)
    }

    func claim(pairingToken: String, authorize: Bool = false) async throws {
        let response = try await perform(path: "/v1/pair/claim", method: "POST", body: Data(pairingToken.utf8), authorize: authorize)
        guard response.status == 204 else {
            if response.status == 401 || response.status == 409 { throw HelperError.unauthorized }
            throw HelperError.offline
        }
    }

    /// Claim stays a raw body. JSON content type is set only when a caller passes one.
    private func perform(path: String, method: String, body: Data?, authorize: Bool, timeout: TimeInterval = 10, contentType: String? = nil) async throws -> HelperResponse {
        try prepareDial(to: credentials.host)
        guard let url = URL(string: "https://\(credentials.host):\(credentials.port)\(path)") else {
            throw HelperError.notIPv4
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if authorize {
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let response = try await send(request)
            return response
        } catch let error as HelperError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw error
        } catch {
            throw HelperError.offline
        }
    }
}

/// In-memory library page. Writes stay off until the helper answers.
/// Quitting releases this object. Nothing is written to Application Support.
@MainActor
@Observable
final class LibrarySession {
    private(set) var rows: [LibraryAsset] = []
    private(set) var banner: String?
    private(set) var isEmptyOffline = false
    private(set) var writesEnabled = false
    private var hasPage = false
    private var client: HelperClient

    init(client: HelperClient) {
        self.client = client
    }

    func use(_ client: HelperClient) {
        self.client = client
    }

    /// Stills and videos for one folder. Each request stays within the helper's page of 200.
    func refreshPhotosAndVideos(under folder: String?) async {
        do {
            let photos = try await client.assets(media: "photo", under: folder)
            let videos = try await client.assets(media: "video", under: folder)
            rows = (photos.rows + videos.rows).sorted { left, right in
                (left.relPath ?? left.uid).localizedStandardCompare(right.relPath ?? right.uid) == .orderedAscending
            }
            hasPage = true
            banner = nil
            isEmptyOffline = false
            writesEnabled = true
        } catch {
            await refresh(media: "photo", under: folder)
        }
    }

    func refresh(media: String? = nil, under folder: String? = nil) async {
        do {
            let page = try await client.assets(media: media, under: folder)
            rows = page.rows
            hasPage = true
            banner = nil
            isEmptyOffline = false
            writesEnabled = true
        } catch let error as HelperError {
            writesEnabled = false
            switch error {
            case .notIPv4, .hostChanged, .pinChanged:
                banner = error.message
                isEmptyOffline = !hasPage
                if !hasPage { rows = [] }
            case .offline, .unauthorized, .keychain:
                if hasPage {
                    banner = LibraryCopy.staleBanner
                    isEmptyOffline = false
                } else {
                    banner = nil
                    isEmptyOffline = true
                    rows = []
                }
            }
        } catch {
            writesEnabled = false
            if hasPage {
                banner = LibraryCopy.staleBanner
                isEmptyOffline = false
            } else {
                banner = nil
                isEmptyOffline = true
                rows = []
            }
        }
    }
}
