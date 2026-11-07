import AppKit
import SwiftUI

/// The duplicates store. The preview slider scales the same 512 px JPEG. Delete does not purge.
struct DuplicatesBrowser: View {
    @Bindable var browser: LibraryBrowser
    @State private var pendingPurge: PurgePrompt?
    @State private var showsPurgeAll = false
    @State private var purgeAllText = ""

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
                HStack(spacing: 8) {
                    libraryPushButton("Find duplicates", identifier: "Find duplicates") {
                        Task { await browser.findDuplicates() }
                    }
                    libraryPushButton("Start", identifier: "Trim start") {
                        Task { await browser.startTrim() }
                    }
                    libraryPushButton("Pause", identifier: "Trim pause") {
                        Task { await browser.pauseTrim() }
                    }
                    libraryPushButton("Continue", identifier: "Trim continue") {
                        Task { await browser.continueTrim() }
                    }
                }
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
            await browser.loadDuplicates()
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
        let item = browser.cells[asset.uid]
        let selected = browser.selectedUID == asset.uid
        return VStack(spacing: 6) {
            ZStack {
                if let data = item?.imageData, let image = NSImage(data: data) {
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
            browser.selectedUID = asset.uid
        }
        .accessibilityLabel(browser.filename(for: asset))
    }
}

private struct PurgePrompt: Equatable {
    var uid: String
    var filename: String
}
