import AppKit
import SwiftUI

/// Reduced images, or the video list. The preview slider scales the helper JPEG.
struct LibraryGrid: View {
    @Bindable var browser: LibraryBrowser
    var media: String? = "photo"

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
            if let notice = browser.notice {
                Text(notice)
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
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
        }
        .background(ChromePalette.panel)
        .onDeleteCommand {
            browser.deleteKey()
        }
        .task(id: "\(media ?? "")|\(browser.displayFolder)") {
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
            browser.selectRow(asset.uid, shift: NSEvent.modifierFlags.contains(.shift), order: browser.rows.map(\.uid))
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
                Button(LibraryItemMenu.openWithZImage) {
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
            Button("Remove from library") {
                browser.selectedUID = asset.uid
                Task { await browser.moveToDuplicates(asset) }
            }
            .disabled(alreadyStored(asset))
            Divider()
            Text(browser.sizeLabel(for: asset))
        }
        .accessibilityLabel(browser.filename(for: asset))
    }

    private func alreadyStored(_ asset: LibraryAsset) -> Bool {
        if asset.placement == "duplicates" || asset.placement == "purged" { return true }
        let path = asset.relPath ?? ""
        return path == "Photos/_Duplicates" || path.hasPrefix("Photos/_Duplicates/")
    }
}
