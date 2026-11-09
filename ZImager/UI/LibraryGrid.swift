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

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: browser.previewPoints + 24), spacing: 16)]
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
                    Text(browser.displayFolder)
                        .font(.system(size: 13))
                        .foregroundStyle(ChromePalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("Display folder name")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
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
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(browser.rows, id: \.uid) { asset in
                        cell(asset)
                    }
                }
                .padding(16)
            }
            .modifier(KeptScroll(
                visible: onScreen,
                key: "\(media ?? "")|\(browser.displayFolder)",
                holdOffset: browser.removalBusy || browser.dateBusy || browser.cleanBusy
            ))
        }
        .background(ChromePalette.panel)
        .onDeleteCommand {
            guard live else { return }
            browser.deleteKey()
        }
        .task(id: "\(media ?? "")|\(browser.displayFolder)|\(live)") {
            guard live else { return }
            await browser.showFocus()
            await browser.reload(media: media)
            while !Task.isCancelled {
                if await browser.previewVisibleOne() { continue }
                let consumed = await browser.checkpointOne()
                if !browser.awaitsPreviews && !consumed { return }
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                if browser.awaitsPreviews {
                    await browser.reload(media: media)
                }
            }
        }
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
                if let data = browser.displayImageData(uid: asset.uid), let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
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
                    .stroke(selected ? ChromePalette.accentSoft : Color.clear, lineWidth: 3)
            )
            Text(browser.filename(for: asset))
                .font(.system(size: 12))
                .foregroundStyle(ChromePalette.ink)
                .lineLimit(1)
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
            Divider()
            Button("Copy settings") {
                if let url = browser.fileURL(for: asset) {
                    model.copySettings(from: url)
                }
            }
            .disabled(!browser.isSettingsStill(asset))
            Button("Paste settings") {
                model.pasteLibraryStills(browser.settingsPasteTargets(clicked: asset)) { browser.fileURL(for: $0) }
            }
            .disabled(!model.hasCopiedSettings || model.folderRotateBusy || browser.settingsPasteTargets(clicked: asset).isEmpty)
            Divider()
            Button("Remove from library") {
                let targets = browser.libraryRemovalTargets(clicked: asset)
                Task { await browser.removeFromLibrary(targets) }
            }
            .disabled(browser.removalBusy || browser.dateBusy || browser.cleanBusy || browser.libraryRemovalTargets(clicked: asset).isEmpty)
            Divider()
            Text(browser.sizeLabel(for: asset))
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
