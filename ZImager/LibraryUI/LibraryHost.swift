import AppKit
import Foundation

/// Helper session for the Server page. The separate ZImage Library app is unchanged.
@MainActor
enum LibraryHost {
    /// A stored IPv4 host and keychain pin build a pinned session. Otherwise the grid stays offline and does not dial.
    static func client() -> HelperClient {
        let host = UserDefaults.standard.string(forKey: LibraryAppClient.hostDefaultsKey) ?? ""
        guard HelperClient.isIPv4(host),
              let secret = try? KeychainTokenStore.load(host: host),
              let pin = Data(base64Encoded: secret.pinBase64) else {
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

    @discardableResult
    static func pickLibraryFolder(browser: LibraryBrowser) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Library Base Folder"
        panel.message = "Choose the PhotoVideoAudio folder on the share."
        panel.directoryURL = browser.libraryRoot
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try? LibraryFolderBookmark.store(url, defaults: .standard)
        browser.adoptLibraryRoot(url)
        return url
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
            browser.connect(client)
            await browser.reload()
        } catch let error as HelperError {
            browser.notice = error.message
        } catch {
            browser.notice = LibraryPairing.missingToken
        }
    }
}
