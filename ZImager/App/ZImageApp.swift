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
            CommandGroup(after: .sidebar) {
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
                Button("Remove Object") { model.selectCanvasTool(.removeObject) }
                Button("Remove Dust") { model.removeDust() }
                Button("Remove Scratches") { model.removeScratches() }
                Button("Spot") { model.toggleCanvasTool(.dustSpot) }
                Button("Scratch") { model.toggleCanvasTool(.scratchMark) }
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
}
