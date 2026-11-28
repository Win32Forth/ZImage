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

/// Shown under Spectrum while a mirror photo is open.
/// Edit in Library opens a photo the main server already has.
/// An orphan offers Recover and Edit photo.
struct MirrorImagePanel: View {
    var notice: String
    var orphan: Bool
    var busy: Bool
    var edit: () -> Void
    @AppStorage("ZImage.inspectorMirrorImageCollapsed") private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorPanelHeader(title: "Mirror", collapsed: collapsed) { collapsed.toggle() }
            if !collapsed {
                Text(orphan
                    ? "This photo is not on the main server. Recover and Edit copies it there under the same name, then opens it. A name that is already in that folder gains -2."
                    : "Displaying image on backup mirror server. Click Edit in Library below to make changes to this image.")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Button(orphan ? "Recover and Edit photo" : "Edit in Library", action: edit)
                    .disabled(orphan && busy)
                    .accessibilityIdentifier(orphan ? "Recover and Edit photo" : "Edit in Library")
                    .help(orphan
                        ? "Copies this photo onto the main server under the same name, then opens it. A name that is already there gains -2."
                        : "Opens this photo on the main server.")
                if !notice.isEmpty {
                    Text(notice)
                        .font(.system(size: 13))
                        .foregroundStyle(ChromePalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("Mirror image notice")
                }
            }
        }
        .padding(EdgeInsets(top: InspectorMetrics.panelTopPadding, leading: 16, bottom: InspectorMetrics.panelBottomPadding, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityIdentifier("Mirror image")
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
            Text("A red border means this file is not on the main server. A selected orphan is purple. Any other selected photo is green. Recover copies the selected orphan under the same name. A name that is already in that folder gains -2. Discard moves the selected orphan to Photos/_Removed. Discard all Orphans moves every orphan on this page there.")
                .font(.system(size: 13))
                .foregroundStyle(ChromePalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Recover photo") {
                Task { await browser.recoverMirrorSelection() }
            }
            .disabled(browser.removalBusy || browser.pageOrphans().isEmpty)
            .accessibilityIdentifier("Recover photo")
            .help("Copies the selected orphaned photos onto the main server under the same name. A name that is already there gains -2.")
            Button("Discard photo") {
                let targets = browser.selectedOrphans()
                Task {
                    if targets.isEmpty {
                        browser.notice = "Select an orphaned photo to discard."
                    } else {
                        await browser.removeFromLibrary(targets)
                    }
                }
            }
            .disabled(browser.removalBusy || browser.pageOrphans().isEmpty)
            .accessibilityIdentifier("Discard photo")
            .help("Moves the selected orphaned photos to Photos/_Removed on this mirror.")
            Button("Discard all Orphans") {
                Task { await browser.discardPageOrphans() }
            }
            .disabled(browser.removalBusy || browser.pageOrphans().isEmpty)
            .accessibilityIdentifier("Discard all Orphans")
            .help("Moves every orphaned photo on this page to Photos/_Removed on this mirror.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityIdentifier("Mirror panel")
    }
}
