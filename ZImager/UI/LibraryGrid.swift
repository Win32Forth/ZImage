import AppKit
import SwiftUI

/// Reduced images, or the video list. The preview slider scales the helper JPEG.
struct LibraryGrid: View {
    @Bindable var browser: LibraryBrowser
    @Bindable var model: EditorModel
    var media: String? = "photo"
    /// Server mode. Disk leaves the preview walk idle.
    var live = true
    /// The grid is on screen. Hiding it keeps the scroll offset.
    var onScreen = true
    @State private var confirmsRemovedDelete = false
    @State private var renameAsset: LibraryAsset?
    @State private var renameName = ""

    private func columns(for width: CGFloat) -> [GridItem] {
        let count = PreviewSize.columnCount(width: width, cell: browser.previewPoints)
        return Array(repeating: GridItem(.fixed(browser.previewPoints), spacing: 16), count: count)
    }

    var body: some View {
        grid
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 0) {
            if media == "photo" || media == "video" {
                HStack(spacing: 8) {
                    libraryPushButton("Display Folder", identifier: "Display Folder") {
                        browser.chooseDisplayFolder(media: media ?? "photo")
                    }
                    if live {
                        libraryPushButton("Rescan", identifier: "Rescan Folder") {
                            browser.rescanDisplayFolder()
                        }
                        .disabled(browser.rescanBusy || browser.removalBusy || browser.dateBusy || browser.organizeBusy || browser.cleanBusy || browser.moveBusy || browser.mergeBusy)
                        .help("Checks the photos on this page, up to 2,000. It does not walk the rest of the folder.")
                    }
                    Text(folderHeading)
                        .font(.system(size: 13))
                        .foregroundStyle(ChromePalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("Display folder name")
                    if DisplayFolder.isRemovedShelf(browser.displayFolder) {
                        libraryPushButton("Delete ALL", identifier: "Delete ALL") {
                            confirmsRemovedDelete = true
                        }
                        .disabled(browser.removalBusy || browser.rescanBusy || browser.dateBusy || browser.organizeBusy || browser.cleanBusy || browser.moveBusy || browser.mergeBusy)
                        .help("Deletes every file in Photos/_Removed from the server.")
                        .layoutPriority(1)
                    } else {
                        FolderNameFilterBar(
                            query: $browser.nameQuery,
                            filterActive: !browser.nameFilter.isEmpty,
                            prefix: "Server",
                            find: { browser.applyNameFilter() },
                            clear: { browser.clearNameFilter() }
                        )
                        .layoutPriority(1)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                if let meter = browser.organizeMeter {
                    TouchupProgressBar(
                        meter: meter,
                        identifier: "Organize progress",
                        caption: rescanProgressCaption(meter)
                    )
                    .padding(.horizontal, 8)
                }
                if live, let meter = browser.rescanMeter {
                    TouchupProgressBar(
                        meter: meter,
                        identifier: "Rescan progress",
                        caption: rescanProgressCaption(meter)
                    )
                    .padding(.horizontal, 8)
                }
            }
            PreviewSizeSlider(points: Binding(
                get: { browser.previewPoints },
                set: { browser.setPreviewPoints($0) }
            ))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            noticeLine
            if let status = browser.previewStatus {
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if let banner = browser.session.banner {
                OfflineBanner(text: banner)
            }
            if browser.session.isEmptyOffline {
                LibraryEmptyState()
                    .padding(16)
            } else if browser.rows.isEmpty && !browser.nameFilter.isEmpty {
                Text("No photos match that name.")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            }
            GeometryReader { proxy in
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVGrid(columns: columns(for: proxy.size.width), alignment: .leading, spacing: 16) {
                            ForEach(browser.rows, id: \.uid) { asset in
                                cell(asset)
                                    .id(asset.uid)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // A new preview was leaving this bar half outside the center clip.
                    .contentMargins(.trailing, ScrollBarFit.indicatorInset, for: .scrollIndicators)
                    .modifier(KeptScroll(
                        visible: onScreen,
                        key: "\(media ?? "")|\(browser.displayFolder)|\(browser.folderPage)",
                        holdOffset: browser.removalBusy || browser.dateBusy || browser.organizeBusy || browser.cleanBusy || browser.rescanBusy || browser.moveBusy || browser.mergeBusy
                    ))
                    .onChange(of: browser.switchScrollTick) { _, _ in
                        guard let uid = browser.switchScrollUID else { return }
                        Task { @MainActor in
                            scroller.scrollTo(uid, anchor: .center)
                        }
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .onDeleteCommand {
            guard live else { return }
            browser.deleteKey()
        }
        .onChange(of: browser.rows.map { $0.relPath ?? "" }.joined(separator: "\n")) { _, _ in
            browser.refreshMirrorMarks()
        }
        .onChange(of: browser.displayFolder) { _, folder in
            guard DisplayFolder.isRemovedShelf(folder) else { return }
            if !browser.nameQuery.isEmpty || !browser.nameFilter.isEmpty {
                browser.clearNameFilter()
            }
        }
        .alert(
            "Are you sure, all _Removed photos will be deleted from the server?",
            isPresented: $confirmsRemovedDelete
        ) {
            Button("Yes", role: .destructive) {
                Task { await browser.deleteAllRemoved() }
            }
            Button("No", role: .cancel) {}
        }
        .alert("Rename", isPresented: renamePresented) {
            TextField("File name", text: $renameName)
            Button("Rename") {
                let asset = renameAsset
                let typed = renameName
                renameAsset = nil
                if let asset, !model.showsServerMergePreview {
                    browser.rename(asset, to: typed)
                }
            }
            Button("Cancel", role: .cancel) {
                renameAsset = nil
            }
        } message: {
            Text("The file stays in this folder.")
        }
        .task(id: "\(media ?? "")|\(browser.displayFolder)|\(browser.nameFilter)|\(live)") {
            guard live else { return }
            await browser.showFocus()
            await browser.reload(media: media)
            while !Task.isCancelled {
                if await browser.previewVisibleBatch() > 0 { continue }
                let consumed = await browser.checkpointOne()
                if !browser.awaitsPreviews && !consumed {
                    await browser.waitForAnotherFolderPage()
                    continue
                }
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                if browser.awaitsPreviews {
                    await browser.reload(media: media)
                }
            }
        }
    }

    /// An orphan that is not selected is red. A selected orphan is purple. Any other selected photo is green.
    private func cellBorder(_ asset: LibraryAsset, selected: Bool) -> Color {
        let orphan = asset.relPath.map { browser.mirrorMissing.contains($0) } ?? false
        switch MirrorFrame.kind(orphan: orphan, selected: selected) {
        case .red:
            return .red
        case .purple:
            return .purple
        case .green:
            return .green
        case .none:
            return .clear
        }
    }

    /// The open folder, with its still count at the end once that count is known.
    private var folderHeading: String {
        let count = media == "photo" && !browser.folderPageCounting ? browser.folderPhotoTotal : nil
        return FolderPage.heading(folder: browser.displayFolder, photoCount: count)
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameAsset != nil },
            set: { if !$0 { renameAsset = nil } }
        )
    }

    /// Stays in the tree when the text is empty so the scroll view keeps its identity.
    private var noticeLine: some View {
        let text = browser.notice ?? ""
        return Text(text)
            .font(.system(size: 13))
            .foregroundStyle(ChromePalette.ink)
            .lineLimit(2)
            .padding(.horizontal, 16)
            .padding(.bottom, text.isEmpty ? 0 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: text.isEmpty ? 0 : nil)
            .clipped()
            .accessibilityHidden(text.isEmpty)
    }

    private func cell(_ asset: LibraryAsset) -> some View {
        let item = browser.cells[asset.uid]
        let selected = browser.selectedUIDs.contains(asset.uid)
        return VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                if let data = browser.displayImageData(uid: asset.uid) {
                    JPEGImage(data: data)
                        .equatable()
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ChromePalette.hairline)
                }
                if let badge = item?.badge {
                    Text(badge)
                        .font(.system(size: 11))
                        .foregroundStyle(ChromePalette.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ChromePalette.panel)
                        .padding(6)
                }
            }
            .frame(width: browser.previewPoints, height: browser.previewPoints)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(cellBorder(asset, selected: selected), lineWidth: 3)
            )
            Text(browser.filename(for: asset))
                .font(.system(size: 12))
                .foregroundStyle(ChromePalette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: browser.previewPoints)
            if browser.isVideo(asset) {
                Text("Video")
                    .font(.system(size: 11))
                    .foregroundStyle(ChromePalette.muted)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            browser.selectRow(
                asset.uid,
                shift: flags.contains(.shift),
                extend: flags.contains(.command),
                order: browser.rows.map(\.uid)
            )
        }
        .onTapGesture(count: 2) {
            browser.selectRow(asset.uid, shift: false, order: browser.rows.map(\.uid))
            browser.openPrimary(asset)
        }
        .contextMenu {
            if browser.isVideo(asset) {
                Button("Play") {
                    browser.selectedUID = asset.uid
                    browser.openPrimary(asset)
                }
                .disabled(browser.fileURL(for: asset) == nil)
                Button(LibraryItemMenu.openWithQuickTime) {
                    browser.selectedUID = asset.uid
                    browser.openInQuickTime(asset)
                }
                .disabled(browser.fileURL(for: asset) == nil || !browser.quickTimeAvailable)
            } else {
                Button(LibraryItemMenu.editImage) {
                    browser.selectedUID = asset.uid
                    browser.openInEditor(asset)
                }
                .disabled(!browser.canOpenInEditor(asset))
            }
            Button(LibraryItemMenu.showInFinder) {
                browser.showInFinder(asset)
            }
            .disabled(browser.fileURL(for: asset) == nil)
            Menu(LibraryItemMenu.openWith) {
                let targets = browser.openWithTargets(for: asset)
                if targets.isEmpty {
                    Text("No application")
                } else {
                    ForEach(targets) { target in
                        Button(target.name) {
                            browser.open(asset, with: target.url)
                        }
                        .disabled(target.isZImage && !browser.canOpenInEditor(asset))
                    }
                }
            }
            if !browser.isMirror && !model.showsServerMergePreview {
                Button(LibraryItemMenu.rename) {
                    renameName = browser.filename(for: asset)
                    renameAsset = asset
                }
                .disabled(
                    browser.fileURL(for: asset) == nil
                        || browser.removalBusy || browser.dateBusy || browser.organizeBusy || browser.cleanBusy
                        || browser.rescanBusy || browser.moveBusy || browser.mergeBusy
                        || model.mergePreviewBusy
                )
                .accessibilityIdentifier("Rename")
                .help("Gives this file a new name in the same folder.")
            }
            Divider()
            Button("Copy settings") {
                if let url = browser.fileURL(for: asset) {
                    model.copySettings(from: url)
                }
            }
            .disabled(!browser.isSettingsStill(asset))
            if !browser.isMirror {
                Button("Paste settings") {
                    model.pasteLibraryStills(browser.settingsPasteTargets(clicked: asset)) { browser.fileURL(for: $0) }
                }
                .disabled(!model.hasCopiedSettings || model.folderRotateBusy || browser.settingsPasteTargets(clicked: asset).isEmpty)
            }
            Divider()
            Button("Remove from library") {
                let targets = browser.libraryRemovalTargets(clicked: asset)
                Task { await browser.removeFromLibrary(targets) }
            }
            .disabled(browser.removalBusy || browser.dateBusy || browser.organizeBusy || browser.cleanBusy || browser.rescanBusy || browser.moveBusy || browser.mergeBusy || browser.libraryRemovalTargets(clicked: asset).isEmpty)
            Divider()
            Text(browser.listedSizeLabel(for: asset))
        }
        .accessibilityLabel(browser.filename(for: asset))
        .overlay {
            ControlClickCatcher {
                browser.selectRow(asset.uid, shift: false, extend: true, order: browser.rows.map(\.uid))
            }
            .accessibilityHidden(true)
        }
    }

}
