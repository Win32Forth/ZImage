import AppKit
import SwiftUI

/// The editor folder column starts at 230 and can be dragged wide enough to read a name.
enum EditorFolderSpan {
    static let minimum: CGFloat = 180
    static let maximum: CGFloat = 720
    static let initial: CGFloat = 230

    static func clamped(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        let room = max(minimum, available - 240)
        let cap = min(maximum, room)
        return min(max(proposed, minimum), cap)
    }
}

/// One child directory. The preview grid lists stills. The tree does not.
struct EditorFolderNode: Identifiable, Equatable, Sendable {
    var url: URL
    var name: String
    var id: String { EditorFolderScan.key(url) }
}

/// Child directories of one folder. A click loads the next level. Files are not listed.
enum EditorFolderScan {
    nonisolated static func key(_ url: URL) -> String {
        FolderEntry.cacheKey(for: url)
    }

    nonisolated static func childFolders(of directory: URL) -> [EditorFolderNode] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var folders: [EditorFolderNode] = []
        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isDirectory == true else { continue }
            folders.append(EditorFolderNode(url: url, name: name))
        }
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Indented folders under the folder chosen with Open Folder.
struct EditorFolderTree: View {
    @Bindable var model: EditorModel

    @State private var children: [String: [EditorFolderNode]] = [:]
    @State private var expanded: Set<String> = []

    var body: some View {
        Group {
            if let root = model.browseRoot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleRows(root: root), id: \.node.id) { item in
                            row(item.node, depth: item.depth)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Text("Open a folder to see its subfolders.")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.muted)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(ChromePalette.listWash)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder tree")
        .task(id: model.browseRoot.map(EditorFolderScan.key)) {
            children = [:]
            if let root = model.browseRoot {
                let key = EditorFolderScan.key(root)
                expanded = [key]
                await load(root)
                await reveal(model.folderURL)
            } else {
                expanded = []
            }
        }
        .onChange(of: model.folderURL.map(EditorFolderScan.key)) { _, _ in
            Task { await reveal(model.folderURL) }
        }
    }

    private func visibleRows(root: URL) -> [(node: EditorFolderNode, depth: Int)] {
        var rows: [(node: EditorFolderNode, depth: Int)] = []
        let top = EditorFolderNode(url: root, name: root.lastPathComponent)
        func append(_ node: EditorFolderNode, _ depth: Int) {
            rows.append((node, depth))
            guard expanded.contains(node.id) else { return }
            for child in children[node.id] ?? [] {
                append(child, depth + 1)
            }
        }
        append(top, 0)
        return rows
    }

    private func row(_ node: EditorFolderNode, depth: Int) -> some View {
        let open = expanded.contains(node.id)
        let known = children[node.id]
        let hasChevron = known == nil || known?.isEmpty == false
        let selected = model.folderURL.map { EditorFolderScan.key($0) == node.id } ?? false
        return HStack(spacing: 4) {
            if hasChevron {
                Button {
                    toggle(node)
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ChromePalette.muted)
                        .frame(width: 12, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Collapse \(node.name)" : "Expand \(node.name)")
            } else {
                Color.clear.frame(width: 12, height: 16)
            }
            Button {
                if !open {
                    toggle(node)
                }
                model.selectBrowseFolder(node.url)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .foregroundStyle(ChromePalette.muted)
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 13))
        .foregroundStyle(ChromePalette.ink)
        .padding(.leading, 8 + CGFloat(depth) * 14)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? ChromePalette.listSelected : ChromePalette.listWash)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node.name)
    }

    private func toggle(_ node: EditorFolderNode) {
        if expanded.contains(node.id) {
            expanded.remove(node.id)
            return
        }
        expanded.insert(node.id)
        Task { await load(node.url) }
    }

    private func load(_ directory: URL) async {
        let rootKey = model.browseRoot.map(EditorFolderScan.key)
        let found = await Task.detached(priority: .userInitiated) {
            EditorFolderScan.childFolders(of: directory)
        }.value
        guard model.browseRoot.map(EditorFolderScan.key) == rootKey else { return }
        children[EditorFolderScan.key(directory)] = found
    }

    /// Opens the folders above the selected one so its row is in the list.
    private func reveal(_ folder: URL?) async {
        guard let folder, let root = model.browseRoot else { return }
        let rootKey = EditorFolderScan.key(root)
        let folderKey = EditorFolderScan.key(folder)
        guard folderKey == rootKey || folderKey.hasPrefix(rootKey + "/") else { return }
        var chain = [root]
        if folderKey != rootKey {
            let suffix = folderKey.dropFirst(rootKey.count + 1)
            var acc = root
            for part in suffix.split(separator: "/") {
                acc = acc.appendingPathComponent(String(part))
                chain.append(acc)
            }
        }
        for directory in chain.dropLast() {
            expanded.insert(EditorFolderScan.key(directory))
            if children[EditorFolderScan.key(directory)] == nil {
                await load(directory)
            }
        }
    }
}

/// The line between the folder tree and the editor. Drag it to read long names.
struct EditorFolderDivider: View {
    @Binding var width: CGFloat
    var available: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        Rectangle()
            .fill(ChromePalette.hairline)
            .frame(width: 1)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if start == nil {
                            start = width
                        }
                        width = EditorFolderSpan.clamped((start ?? width) + value.translation.width, available: available)
                    }
                    .onEnded { _ in
                        start = nil
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.resizeLeftRight.set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .accessibilityLabel("Folder list width")
            .accessibilityIdentifier("Folder tree splitter")
    }
}
