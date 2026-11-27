import SwiftUI

/// Picks the main server and the mirror, then starts the copy or clears the pair.
struct MirrorSetupSheet: View {
    let servers: [HelperServerRecord]
    var onStart: (String, String) -> Void
    var onUnlink: () -> Void
    var onClose: () -> Void
    @State private var mainID: String
    @State private var mirrorID: String

    init(
        servers: [HelperServerRecord],
        onStart: @escaping (String, String) -> Void,
        onUnlink: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.servers = servers
        self.onStart = onStart
        self.onUnlink = onUnlink
        self.onClose = onClose
        let main = MirrorRoster.mainRow(in: servers)?.id ?? servers.first?.id ?? ""
        var mirror = MirrorRoster.mirrorRow(in: servers)?.id ?? ""
        if mirror.isEmpty || mirror == main {
            mirror = servers.first { $0.id != main }?.id ?? ""
        }
        _mainID = State(initialValue: main)
        _mirrorID = State(initialValue: mirror)
    }

    private var linked: Bool {
        MirrorRoster.mainRow(in: servers) != nil && MirrorRoster.mirrorRow(in: servers) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mirror Setup")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ChromePalette.ink)
            Text("The mirror keeps the main server's folders and file names. Mirroring copies each file that is missing or a different size, including the edit file and the flattened TIFF. Files that exist only on the mirror stay there.")
                .font(.system(size: 13))
                .foregroundStyle(ChromePalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Main", selection: $mainID) {
                ForEach(servers) { server in
                    Text(server.name).tag(server.id)
                }
            }
            .accessibilityIdentifier("Mirror main server")
            Picker("Mirror", selection: $mirrorID) {
                ForEach(servers) { server in
                    Text(server.name).tag(server.id)
                }
            }
            .accessibilityIdentifier("Mirror mirror server")
            Text("Unlink leaves both libraries in place. The mirror can then be the main server if the main server fails.")
                .font(.system(size: 13))
                .foregroundStyle(ChromePalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Start mirroring") { onStart(mainID, mirrorID) }
                    .disabled(mainID.isEmpty || mirrorID.isEmpty || mainID == mirrorID)
                    .accessibilityIdentifier("Start mirroring")
                Button("Unlink") { onUnlink() }
                    .disabled(!linked)
                    .accessibilityIdentifier("Unlink mirror")
                Spacer()
                Button("Close") { onClose() }
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(ChromePalette.panel)
    }
}

/// Recover and Discard for the folder on the mirror. Build previews stays beside this panel.
struct MirrorPanel: View {
    @Bindable var browser: LibraryBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mirror")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChromePalette.ink)
            Text("A red border means this file is not on the main server. Recover copies it beside the matching name. Discard moves it to Photos/_Removed on this mirror.")
                .font(.system(size: 13))
                .foregroundStyle(ChromePalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Recover photo") {
                Task { await browser.recoverMirrorSelection() }
            }
            .disabled(browser.mirrorBusy || browser.removalBusy || browser.recoverTargets().isEmpty)
            .accessibilityIdentifier("Recover photo")
            .help("Copies the selected photos onto the main server beside the file of the same name.")
            Button("Discard photo") {
                let targets = browser.recoverTargets()
                Task { await browser.removeFromLibrary(targets) }
            }
            .disabled(browser.mirrorBusy || browser.removalBusy || browser.recoverTargets().isEmpty)
            .accessibilityIdentifier("Discard photo")
            .help("Moves the selected photos to Photos/_Removed on this mirror.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityIdentifier("Mirror panel")
    }
}
