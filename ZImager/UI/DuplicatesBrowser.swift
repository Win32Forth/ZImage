import AppKit
import SwiftUI

/// The duplicates store. The preview slider scales the stored preview JPEG. Delete does not purge.
struct DuplicatesBrowser: View {
    @Bindable var browser: LibraryBrowser
    @State private var pendingPurge: PurgePrompt?
    @State private var showsPurgeAll = false
    @State private var purgeAllText = ""
    @State private var openHelp: String?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: browser.previewPoints + 24), spacing: 16)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewSizeSlider(points: Binding(
                get: { browser.previewPoints },
                set: { browser.setPreviewPoints($0) }
            ))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 8) {
                Text(TrimCopy.lamp(browser.trim))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(lampColor)
                    .accessibilityIdentifier("Trim lamp")
                trimControl("Find duplicates", identifier: "Find duplicates", help: TrimButtonHelp.find) {
                    Task { await browser.findDuplicates() }
                }
                .fixedSize(horizontal: true, vertical: true)
                if let progress = DuplicateCopy.scanLine(browser.scan) {
                    Text(progress)
                        .font(.system(size: 13))
                        .foregroundStyle(ChromePalette.ink)
                        .accessibilityIdentifier("Duplicate scan")
                }
                HStack(alignment: .center, spacing: 20) {
                    Text("Gather duplicates")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChromePalette.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityIdentifier("Gather duplicates")
                    HStack(alignment: .center, spacing: 28) {
                        trimControl("Start", identifier: "Trim start", help: TrimButtonHelp.start) {
                            Task { await browser.startTrim() }
                        }
                        trimControl("Pause", identifier: "Trim pause", help: TrimButtonHelp.pause) {
                            Task { await browser.pauseTrim() }
                        }
                        trimControl("Continue", identifier: "Trim continue", help: TrimButtonHelp.continueGather) {
                            Task { await browser.continueTrim() }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(ChromePalette.ink.opacity(0.7), lineWidth: 1)
                )
                .fixedSize(horizontal: true, vertical: true)
                if let activity = DuplicateCopy.activity(browser.trim?.runState) {
                    Text(activity)
                        .font(.system(size: 13))
                        .foregroundStyle(ChromePalette.ink)
                }
                if let notice = browser.duplicateNotice, !notice.isEmpty {
                    Text(notice)
                        .font(.system(size: 13))
                        .foregroundStyle(ChromePalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else if browser.duplicateGroups.isEmpty {
                    Text(DuplicateCopy.emptyList)
                        .font(.system(size: 13))
                        .foregroundStyle(ChromePalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let trimNotice = browser.trimNotice, !trimNotice.isEmpty {
                    Text(trimNotice)
                        .font(.system(size: 13))
                        .foregroundStyle(ChromePalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(browser.duplicateGroups, id: \.uid) { group in
                        groupSection(group)
                    }
                }
                .padding(16)
            }
            if let asset = selectedMember, DuplicateCopy.inStore(asset.relPath) {
                HStack(spacing: 12) {
                    Button("Restore") {
                        Task { await browser.restoreDuplicate(asset) }
                    }
                    Button(asset.pinned == true ? "Clear pin" : "Pin") {
                        Task { await browser.setPin(asset, pinned: asset.pinned != true) }
                    }
                    Button("Delete") {
                        pendingPurge = PurgePrompt(uid: asset.uid, filename: browser.filename(for: asset))
                    }
                }
                .padding(16)
            }
            Button("Delete all duplicates") {
                purgeAllText = ""
                showsPurgeAll = true
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityIdentifier("Duplicates browser")
        .onDeleteCommand {
            browser.deleteKey()
        }
        .confirmationDialog(pendingTitle, isPresented: purgePresented, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let prompt = pendingPurge,
                      let asset = member(uid: prompt.uid) else {
                    pendingPurge = nil
                    return
                }
                pendingPurge = nil
                Task { await browser.purgeDuplicate(asset, filename: prompt.filename) }
            }
            Button("Cancel", role: .cancel) {
                pendingPurge = nil
            }
        }
        .alert("Delete all duplicates", isPresented: $showsPurgeAll) {
            TextField("DELETE", text: $purgeAllText)
            Button("Delete all", role: .destructive) {
                let typed = purgeAllText
                purgeAllText = ""
                Task { await browser.purgeAllDuplicates(confirm: typed) }
            }
            Button("Cancel", role: .cancel) {
                purgeAllText = ""
            }
        } message: {
            Text("Type DELETE to permanently delete every file in the duplicates store.")
        }
        .task {
            await browser.showFocus("Photos/_Duplicates")
            await browser.refreshScan()
            if browser.scan?.runState == "running" {
                Task { await browser.watchScan() }
            } else {
                await browser.loadDuplicates()
            }
            await browser.loadTrim()
            var previous = browser.trim?.runState
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await browser.loadTrim()
                let state = browser.trim?.runState
                if previous == "running" || previous == "pause_requested" || previous == "recovering" {
                    if state == "completed" || state == "paused" || state == "blocked" {
                        await browser.loadDuplicates(notice: DuplicateCopy.gathered)
                    }
                }
                previous = state
            }
        }
    }

    /// The action and its circle-i stay together. The wide gap after the circle belongs to the next button.
    private func trimControl(_ title: String, identifier: String, help: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            libraryPushButton(title, identifier: identifier, action: action)
            Button {
                openHelp = openHelp == identifier ? nil : identifier
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(ChromePalette.ink)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) information")
            .accessibilityIdentifier("\(identifier) info")
            .popover(isPresented: Binding(
                get: { openHelp == identifier },
                set: { shown in
                    if !shown, openHelp == identifier { openHelp = nil }
                }
            )) {
                Text(help)
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(width: 280)
            }
        }
    }

    private var lampColor: Color {
        guard let trim = browser.trim else { return ChromePalette.muted }
        if trim.safeToReboot {
            return Color(red: 0.12, green: 0.45, blue: 0.22)
        }
        return Color(red: 0.72, green: 0.42, blue: 0.08)
    }

    private var pendingTitle: String {
        let name = pendingPurge?.filename ?? "this file"
        return "Delete \(name)?"
    }

    private var purgePresented: Binding<Bool> {
        Binding(
            get: { pendingPurge != nil },
            set: { shown in
                if !shown { pendingPurge = nil }
            }
        )
    }

    private var selectedMember: LibraryAsset? {
        guard let uid = browser.selectedUID else { return nil }
        return member(uid: uid)
    }

    private func member(uid: String) -> LibraryAsset? {
        for group in browser.duplicateGroups {
            if let asset = group.members.first(where: { $0.uid == uid }) {
                return asset
            }
        }
        return nil
    }

    private func groupSection(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(headerName(group))
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                if group.keeper != nil {
                    Text(DuplicateCopy.keeper)
                        .font(.system(size: 11))
                        .foregroundStyle(ChromePalette.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ChromePalette.canvas)
                }
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(group.members, id: \.uid) { asset in
                    cell(asset)
                }
            }
        }
    }

    private func headerName(_ group: DuplicateGroup) -> String {
        if let keeper = group.keeper {
            return browser.filename(for: keeper)
        }
        return group.uid
    }

    private func cell(_ asset: LibraryAsset) -> some View {
        let selected = browser.selectedUIDs.contains(asset.uid)
        return VStack(spacing: 6) {
            ZStack {
                if let data = browser.displayImageData(uid: asset.uid), let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ChromePalette.hairline)
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
            if let place = DuplicateCopy.placeLine(asset.relPath) {
                Text(place)
                    .font(.system(size: 11))
                    .foregroundStyle(ChromePalette.ink)
                    .lineLimit(2)
            }
            ForEach(DuplicateCopy.captions(score: asset.detailScore, pixels: asset.nativePixels), id: \.self) { line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(ChromePalette.ink)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let order = browser.duplicateGroups.flatMap(\.members).map(\.uid)
            browser.selectRow(asset.uid, shift: NSEvent.modifierFlags.contains(.shift), order: order)
        }
        .accessibilityLabel(browser.filename(for: asset))
    }
}

private enum TrimButtonHelp {
    static let find = "Compares the library again and lists matching groups that are still in their folders. The line under this button shows how many photos are done and how many are left. It does not copy or remove files."
    static let start = "Moves the extra copies into Photos/_Duplicates. One photo, the keeper, stays in its date folder. The other unpinned copies leave the old folder and are not permanently deleted. Start waits if Reorganize is still running."
    static let pause = "Finishes the file that is being copied, then waits. The lamp stays Not safe to reboot until that file is done."
    static let continueGather = "Resumes a paused gather. It does not start a new one."
}

private struct PurgePrompt: Equatable {
    var uid: String
    var filename: String
}
