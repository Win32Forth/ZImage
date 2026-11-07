import AppKit
import SwiftUI

@main
struct ZImageLibraryApp: App {
    @State private var browser: LibraryBrowser
    @State private var section: String? = "Photos"
    @State private var showsEvents = false
    @State private var showsReorg = false
    @AppStorage("ZImageLibrary.sidebarWidth") private var sidebarWidth = Double(LibrarySidebarSpan.initial)

    init() {
        SandboxPreferenceImport.adoptLibraryContainer()
        let root = LibraryFolderBookmark.resolve(defaults: .standard)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        _browser = State(initialValue: LibraryBrowser(
            client: Self.client(),
            libraryRoot: root,
            openFile: { url, _ in
                EditorHandoff.openInEditor(url)
            }
        ))
        if let root = LibraryFolderBookmark.resolve(defaults: .standard) {
            _browser.wrappedValue.adoptLibraryRoot(root)
        }
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Menu {
                        Button("Choose Library Base Folder", action: chooseLibraryFolder)
                            .accessibilityIdentifier("Choose Library Base Folder")
                        Button("Pair with Helper", action: pairWithHelper)
                            .accessibilityIdentifier("Pair with Helper")
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ChromePalette.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.white.opacity(0.72))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(ChromePalette.muted.opacity(0.45), lineWidth: 1)
                            )
                            .accessibilityLabel("Library menu")
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityIdentifier("Library menu")
                    Spacer(minLength: 8)
                    libraryPushButton("Open in ZImage", identifier: "Open in ZImage") {
                        browser.openSelected()
                    }
                    libraryPushButton("Events", identifier: "Events") {
                        showsEvents.toggle()
                    }
                    libraryPushButton("Reorganize", identifier: "Reorganize") {
                        showsReorg.toggle()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Sidebar(selection: $section, browser: browser)
                            .frame(width: LibrarySidebarSpan.clamped(CGFloat(sidebarWidth), available: geo.size.width))
                        LibrarySidebarDivider(
                            width: Binding(
                                get: { CGFloat(sidebarWidth) },
                                set: { sidebarWidth = Double($0) }
                            ),
                            available: geo.size.width
                        )
                        Group {
                            if section == "Review" {
                                ReviewList(browser: browser)
                            } else if section == "Duplicates" {
                                DuplicatesBrowser(browser: browser)
                            } else if section == "Videos" {
                                LibraryGrid(browser: browser, media: "video", showsCaptureDate: true)
                            } else {
                                LibraryGrid(browser: browser, media: "photo")
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showsEvents {
                            EventRename(browser: browser)
                                .frame(width: 280)
                        }
                        if showsReorg {
                            ReorgPanel(browser: browser)
                                .frame(width: 280)
                        }
                    }
                }
            }
            .frame(minWidth: 800, minHeight: 520)
            .background(ChromePalette.panel)
            .background(LibraryWindowButtons())
            .navigationTitle("ZImage Library")
        }
        // The close, minimize, and zoom buttons live in this bar. Hiding it removes them.
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .defaultSize(width: 1100, height: 720)
    }

    /// A stored IPv4 host and keychain pin build a pinned session. Otherwise the grid stays offline and does not dial.
    private static func client() -> HelperClient {
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

    private func chooseLibraryFolder() {
        _ = pickLibraryFolder()
    }

    private func pickLibraryFolder() -> URL? {
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

    private func pairWithHelper() {
        let root: URL
        if LibraryFolderBookmark.resolve(defaults: .standard) == nil {
            guard let picked = pickLibraryFolder() else { return }
            root = picked
        } else {
            root = browser.libraryRoot
        }
        Task {
            await pair(root)
        }
    }

    private func pair(_ root: URL) async {
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

/// Puts the close, minimize, and zoom buttons back on the title bar.
private struct LibraryWindowButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.restore(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.restore(nsView.window) }
    }

    private static func restore(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }
}
