import AppKit
import Foundation

/// Helper session for the Server page. The separate ZImage Library app is unchanged.
@MainActor
enum LibraryHost {
    /// A stored IPv4 host and keychain pin build a pinned session. Otherwise the grid stays offline and does not dial.
    static func client() -> HelperClient {
        HelperServerList.migrate(defaults: .standard)
        let listed = HelperServerList.active(defaults: .standard)
        let host = listed?.host ?? UserDefaults.standard.string(forKey: LibraryAppClient.hostDefaultsKey) ?? ""
        guard HelperClient.isIPv4(host),
              let secret = try? KeychainTokenStore.load(host: host),
              let pin = Data(base64Encoded: secret.pinBase64) else {
            if listed != nil {
                KeychainTokenStore.forgetCurrent()
            }
            return LibraryAppClient.offline()
        }
        KeychainTokenStore.rememberCurrent(host: host)
        let pinned = PinnedHelperSession(pin: pin)
        return HelperClient(
            credentials: HelperCredentials(host: host, pin: pin, token: secret.token),
            send: { request in
                try await pinned.send(request)
            }
        )
    }

    /// The folder panel only. Adding a server uses this so a cancelled install leaves the current server in place.
    static func chooseFolder(browser: LibraryBrowser) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Library Base Folder"
        panel.message = "Choose the PhotoVideoAudio folder on the share."
        panel.directoryURL = browser.libraryRoot
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    @discardableResult
    static func pickLibraryFolder(browser: LibraryBrowser) -> URL? {
        guard let url = chooseFolder(browser: browser) else { return nil }
        let base = HelperInstallPaths.libraryBase(forChosen: url)
        adoptChosenFolder(base, browser: browser)
        return base
    }

    /// Points the active server at this folder. A new folder keeps that server's host.
    static func adoptChosenFolder(_ url: URL, browser: LibraryBrowser) {
        let defaults = UserDefaults.standard
        try? LibraryFolderBookmark.store(url, defaults: defaults)
        browser.adoptLibraryRoot(url)
        HelperServerList.migrate(defaults: defaults)
        if var existing = HelperServerList.load(defaults: defaults).first(where: { sameFolder($0, as: url) }) {
            if let data = try? LibraryFolderBookmark.data(for: url) {
                existing.bookmark = data
                HelperServerList.upsert(existing, defaults: defaults)
            } else {
                _ = HelperServerList.select(existing.id, defaults: defaults)
            }
            return
        }
        guard var row = HelperServerList.active(defaults: defaults) else {
            let volume = LibraryFolderBookmark.volumePath(of: url)
            let nas = HelperInstallPaths.suggestedNASPath(libraryPath: url.path, volumePath: volume)
            let host = defaults.string(forKey: LibraryAppClient.hostDefaultsKey) ?? ""
            try? remember(root: url, nasPath: nas, host: host)
            return
        }
        if let data = try? LibraryFolderBookmark.data(for: url) {
            row.bookmark = data
        }
        let volume = LibraryFolderBookmark.volumePath(of: url)
        row.nasPath = HelperInstallPaths.suggestedNASPath(libraryPath: url.path, volumePath: volume)
        HelperServerList.upsert(row, defaults: defaults)
    }

    static func pairWithHelper(browser: LibraryBrowser) {
        let root: URL
        if LibraryFolderBookmark.resolve(defaults: .standard) == nil {
            guard let picked = pickLibraryFolder(browser: browser) else { return }
            root = picked
        } else {
            root = browser.libraryRoot
        }
        Task {
            await pair(browser: browser, root: root)
        }
    }

    private static func pair(browser: LibraryBrowser, root: URL) async {
        browser.notice = nil
        do {
            let material = try LibraryPairing.material(inLibraryRoot: root)
            guard let source = LibraryPairing.mountSource(forPath: root.path),
                  let mountHost = LibraryPairing.mountHost(fromMountSource: source) else {
                browser.notice = HelperError.notIPv4.message
                return
            }
            let ipv4 = try LibraryPairing.firstIPv4(mountHost: mountHost, resolve: HelperClient.resolveIPv4)
            let pinned = PinnedHelperSession(pin: Data())
            let client = HelperClient(
                credentials: HelperCredentials(host: ipv4, token: material.token),
                send: { request in
                    try await pinned.send(request)
                }
            )
            try await client.claim(pairingToken: material.token, authorize: !material.fromPairingFile)
            try client.rememberPin(pinned.acceptedPin)
            let secret = StoredSecret(token: material.token, pinBase64: pinned.acceptedPin.base64EncodedString())
            try KeychainTokenStore.save(host: ipv4, secret: secret)
            UserDefaults.standard.set(ipv4, forKey: LibraryAppClient.hostDefaultsKey)
            notePaired(host: ipv4, root: root)
            browser.connect(client)
            await browser.reload()
        } catch let error as HelperError {
            browser.notice = error.message
        } catch {
            browser.notice = LibraryPairing.missingToken
        }
    }

    static func notePaired(host: String, root: URL) {
        let volume = LibraryFolderBookmark.volumePath(of: root)
        let nas = HelperInstallPaths.suggestedNASPath(libraryPath: root.path, volumePath: volume)
        let current = HelperServerList.active(defaults: .standard)?.nasPath ?? ""
        let path = HelperInstallPaths.cleanNASPath(current) ?? nas
        try? remember(root: root, nasPath: path, host: host)
    }

    static func remember(root: URL, nasPath: String, host: String) throws {
        let defaults = UserDefaults.standard
        HelperServerList.migrate(defaults: defaults)
        let bookmark = try LibraryFolderBookmark.data(for: root)
        var rows = HelperServerList.load(defaults: defaults)
        if let index = rows.firstIndex(where: { sameFolder($0, as: root) }) {
            rows[index].bookmark = bookmark
            rows[index].nasPath = nasPath
            if HelperClient.isIPv4(host) {
                rows[index].host = host
            }
            HelperServerList.upsert(rows[index], defaults: defaults)
            return
        }
        let row = HelperServerRecord(
            id: UUID().uuidString,
            name: HelperServerList.proposedName(for: root, among: rows),
            nasPath: nasPath,
            bookmark: bookmark,
            host: HelperClient.isIPv4(host) ? host : ""
        )
        HelperServerList.upsert(row, defaults: defaults)
    }

    static func activate(_ row: HelperServerRecord, browser: LibraryBrowser) async {
        guard HelperServerList.select(row.id, defaults: .standard) != nil,
              let url = LibraryFolderBookmark.resolve(defaults: .standard) else {
            browser.notice = "ZImager could not open this server's folder."
            return
        }
        browser.adoptLibraryRoot(url)
        browser.connect(client())
        await browser.reload()
    }

    /// Drops the server from this Mac. The helper, photos, and catalog stay on the share.
    static func forgetActive(browser: LibraryBrowser) async {
        guard let row = HelperServerList.active(defaults: .standard) else { return }
        if HelperClient.isIPv4(row.host) {
            KeychainTokenStore.delete(host: row.host)
        }
        _ = HelperServerList.remove(id: row.id, defaults: .standard)
        if let url = LibraryFolderBookmark.resolve(defaults: .standard) {
            browser.adoptLibraryRoot(url)
        }
        browser.connect(client())
        await browser.reload()
    }

    private static func sameFolder(_ row: HelperServerRecord, as root: URL) -> Bool {
        guard let url = LibraryFolderBookmark.url(from: row.bookmark) else { return false }
        return url.standardizedFileURL.path == root.standardizedFileURL.path
    }
}
