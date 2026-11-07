import Foundation

/// Save edits writes a `catalogRef` sidecar to the helper.
/// Save and Save As stay on `fileRef` and do not call the helper.
nonisolated enum SaveEdits {
    static let maxBytes = 256 * 1024 * 1024

    /// The File menu omits Save edits while the helper is down.
    static func showsCommand(helperUp: Bool) -> Bool {
        helperUp
    }

    /// Save edits stays disabled until the helper is up and the open photo is a catalog asset.
    static func isEnabled(helperUp: Bool, assetUID: String?) -> Bool {
        helperUp && assetUID?.isEmpty == false
    }

    static func fileRefBytes(
        log: HistoryLog,
        original: Data,
        pathHint: String,
        bookmark: Data?,
        uti: String,
        previewJPEG: Data
    ) throws -> Data {
        try ZImgRaw.bytesForSavePanel(
            log: log,
            original: original,
            pathHint: pathHint,
            bookmark: bookmark,
            uti: uti,
            previewJPEG: previewJPEG
        )
    }

    static func catalogBytes(
        log: HistoryLog,
        blake3: String,
        byteSize: Int,
        uti: String,
        assetUID: String,
        relativePathHint: String,
        previewJPEG: Data
    ) throws -> Data {
        try ZImgRaw.encode(ZImgRaw.catalogRefDocument(
            log: log,
            blake3: blake3,
            byteSize: byteSize,
            uti: uti,
            assetUID: assetUID,
            relativePathHint: relativePathHint,
            previewJPEG: previewJPEG
        ))
    }

    /// The longest catalog path that is a suffix of the open file wins.
    static func matchingAsset(filePath: String, rows: [LibraryAsset]) -> LibraryAsset? {
        let path = filePath.replacingOccurrences(of: "\\", with: "/")
        var best: LibraryAsset?
        var bestLength = -1
        for row in rows {
            guard let rel = row.relPath, !rel.isEmpty else { continue }
            let suffix = rel.hasPrefix("/") ? rel : "/" + rel
            if path.hasSuffix(suffix), rel.count > bestLength {
                best = row
                bestLength = rel.count
            }
        }
        return best
    }
}

/// The editor reads the helper the library paired. A missing pin leaves Save edits off.
enum EditorHelper {
    static func client() -> HelperClient? {
        guard let host = KeychainTokenStore.currentHost(),
              HelperClient.isIPv4(host),
              let secret = try? KeychainTokenStore.load(host: host),
              let pin = Data(base64Encoded: secret.pinBase64) else {
            return nil
        }
        let pinned = PinnedHelperSession(pin: pin)
        return HelperClient(
            credentials: HelperCredentials(host: host, pin: pin, token: secret.token),
            send: { request in
                try await pinned.send(request)
            }
        )
    }
}
