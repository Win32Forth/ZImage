import AppKit
import SwiftUI

extension Notification.Name {
    static let zimageExternalFile = Notification.Name("ZImageExternalFile")
}

/// Files Launch Services hands to this app. Stills stay rank Alternate.
/// A `.zimg` is rank Owner, so Finder opens a saved document in this app.
@MainActor
enum ExternalFileOpen {
    private static var pending: [URL] = []

    static func enqueue(_ urls: [URL]) {
        pending.append(contentsOf: urls)
        NotificationCenter.default.post(name: .zimageExternalFile, object: nil)
    }

    static func take() -> URL? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    static func drain(into model: EditorModel) {
        while let url = take() {
            model.openSecurityScopedFile(at: url)
        }
    }

    static var hasPending: Bool { !pending.isEmpty }
}

final class ZImageAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = urls
        Task { @MainActor in
            ExternalFileOpen.enqueue(urls)
            application.activate()
            if let window = application.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

@main
struct ZImagerApp: App {
    @NSApplicationDelegateAdaptor(ZImageAppDelegate.self) private var appDelegate
    @State private var model = EditorModel()
    @State private var browser: LibraryBrowser
    @AppStorage("ZImager.sourceMode") private var sourceMode = "disk"
    @AppStorage("ZImager.serverShowsFolder") private var serverShowsFolder = true

    init() {
        SandboxPreferenceImport.adoptLibraryContainer()
        let root = LibraryFolderBookmark.resolve(defaults: .standard)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let browser = LibraryBrowser(
            client: LibraryHost.client(),
            libraryRoot: root,
            openFile: { _, _ in }
        )
        if let stored = LibraryFolderBookmark.resolve(defaults: .standard) {
            browser.adoptLibraryRoot(stored)
        }
        _browser = State(initialValue: browser)
    }

    var body: some Scene {
        // One window. Disk is the editor. Server is the library. The same photo stays on Image.
        // The empty external-event set keeps SwiftUI from opening another window for the file.
        Window("ZImager", id: "editor") {
            ContentView(model: model, browser: browser)
                .frame(minWidth: 1100, minHeight: 700)
                .navigationTitle(model.openedFileName ?? "ZImager")
                .handlesExternalEvents(preferring: [], allowing: [])
                .onAppear {
                    let opening = ExternalFileOpen.hasPending
                    ExternalFileOpen.drain(into: model)
                    if opening, UserDefaults.standard.string(forKey: "ZImager.sourceMode") == "server" {
                        UserDefaults.standard.set(false, forKey: "ZImager.serverShowsFolder")
                    }
                    Task { await model.refreshHelper() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .zimageExternalFile)) { _ in
                    let opening = ExternalFileOpen.hasPending
                    ExternalFileOpen.drain(into: model)
                    if opening, UserDefaults.standard.string(forKey: "ZImager.sourceMode") == "server" {
                        UserDefaults.standard.set(false, forKey: "ZImager.serverShowsFolder")
                    }
                }
        }
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open File…") {
                    UserDefaults.standard.set("disk", forKey: "ZImager.sourceMode")
                    model.openFile()
                }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open Folder…") {
                    UserDefaults.standard.set("disk", forKey: "ZImager.sourceMode")
                    model.openFolder()
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                if SaveEdits.showsCommand(helperUp: model.helperUp) {
                    Button("Save edits") { model.saveEdits() }
                        .disabled(!SaveEdits.isEnabled(helperUp: model.helperUp, assetUID: model.catalogAssetUID))
                }
                Button("Export…") { model.showExportPanel() }
            }
            CommandGroup(replacing: .printItem) {
                Button("Print…") { printCommand() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(!canPrint)
            }
            CommandGroup(after: .sidebar) {
                Button("Folder View") { showFolderView() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Edit View") { showEditView() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Previous Image") { stepImage(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!canStepImage(by: -1))
                Button("Next Image") { stepImage(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!canStepImage(by: 1))
                Divider()
                Button("Fit") { model.fitToWindow() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Actual Size") { model.actualSize() }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Rotate Clockwise") { model.rotateClockwise() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Rotate Counterclockwise") { model.rotateCounterclockwise() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Eyedropper") { model.toggleCanvasTool(.eyedropper) }
                    .keyboardShortcut("e", modifiers: [])
                Button("Remove Dust") { model.removeDust() }
                Button("Remove Scratches") { model.removeScratches() }
                Button("Spot") { model.toggleCanvasTool(.dustSpot) }
                Button("Scratch") { model.toggleCanvasTool(.scratchMark) }
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy settings") { copySettingsCommand() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!canCopySettings)
                Button("Paste settings") { pasteSettingsCommand() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(!canPasteSettings)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.log.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.log.canRedo)
            }
        }
    }

    /// Folder view of the source on screen. Image view is the other choice.
    private var showingFolder: Bool {
        if sourceMode == "server" { return serverShowsFolder }
        return model.showsFolderGrid
    }

    /// One still can be copied in Folder view. Image view copies the open photo.
    private var canCopySettings: Bool {
        if showingFolder {
            if sourceMode == "server" { return browser.primarySettingsStill() != nil }
            return model.primaryFolderStillURL() != nil
        }
        return model.proxy != nil && !model.showsPDFPicker
    }

    /// Folder view prints the selected stills. Image view prints the open photo.
    private var canPrint: Bool {
        guard !model.folderRotateBusy else { return false }
        if showingFolder {
            if sourceMode == "server" {
                return !browser.rotatableStills(in: browser.sectionAssets()).isEmpty
            }
            return model.canRotateFolderSelection
        }
        return model.proxy != nil && !model.showsPDFPicker
    }

    private func printCommand() {
        guard canPrint else { return }
        if showingFolder {
            if sourceMode == "server" {
                var files: [URL] = []
                for asset in browser.rotatableStills(in: browser.sectionAssets()) {
                    guard let url = browser.fileURL(for: asset) else { continue }
                    files.append(url)
                }
                model.printFolderFiles(files)
            } else {
                model.printFolderFiles(model.exportableFolderFiles())
            }
            return
        }
        model.printOpenPhoto()
    }

    /// Folder view pastes onto the selected stills. Image view pastes onto the open photo.
    private var canPasteSettings: Bool {
        guard model.hasCopiedSettings, !model.folderRotateBusy else { return false }
        if showingFolder {
            if sourceMode == "server" {
                return !browser.settingsPasteTargets(clicked: nil).isEmpty
            }
            return model.canRotateFolderSelection
        }
        return model.proxy != nil && !model.showsPDFPicker
    }

    private func copySettingsCommand() {
        guard canCopySettings else { return }
        if showingFolder {
            if sourceMode == "server" {
                guard let asset = browser.primarySettingsStill(), let url = browser.fileURL(for: asset) else { return }
                model.copySettings(from: url)
            } else if let url = model.primaryFolderStillURL() {
                model.copySettings(from: url)
            }
            return
        }
        model.copySettings()
    }

    private func pasteSettingsCommand() {
        guard canPasteSettings else { return }
        if showingFolder {
            if sourceMode == "server" {
                model.pasteLibraryStills(browser.settingsPasteTargets(clicked: nil)) { browser.fileURL(for: $0) }
            } else {
                model.pasteFolderSelection()
            }
            return
        }
        model.pasteSettings()
    }

    /// Image mode of the source on screen, with a photograph open.
    private var editingImage: Bool {
        guard model.proxy != nil, !model.showsPDFPicker else { return false }
        if sourceMode == "server" { return !serverShowsFolder }
        return !model.showsFolderGrid
    }

    private func canStepImage(by delta: Int) -> Bool {
        guard editingImage else { return false }
        if sourceMode == "server" {
            return browser.canStepImage(by: delta, matching: model.openedFileURL)
        }
        return model.canStepListedImage(by: delta)
    }

    private func stepImage(by delta: Int) {
        guard canStepImage(by: delta) else { return }
        if sourceMode == "server" {
            browser.stepImage(by: delta, matching: model.openedFileURL)
        } else {
            model.stepListedImage(by: delta)
        }
    }

    /// Folder and Edit follow whichever source is on screen. Each source keeps its own choice.
    private func showFolderView() {
        if UserDefaults.standard.string(forKey: "ZImager.sourceMode") == "server" {
            UserDefaults.standard.set(true, forKey: "ZImager.serverShowsFolder")
        } else {
            model.showsFolderGrid = true
        }
    }

    private func showEditView() {
        if UserDefaults.standard.string(forKey: "ZImager.sourceMode") == "server" {
            UserDefaults.standard.set(false, forKey: "ZImager.serverShowsFolder")
        } else {
            model.showsFolderGrid = false
        }
    }
}
