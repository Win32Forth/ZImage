import SwiftUI

/// Indented folders under Photos. A folder click shows that folder in the Photos grid.
struct LibraryFolderTree: View {
    @Bindable var browser: LibraryBrowser
    var onSelect: (String) -> Void

    @State private var children: [String: [LibraryFolderNode]] = [:]
    @State private var expanded: Set<String> = [DisplayFolder.root]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleRows, id: \.node.rel) { item in
                    row(item.node, depth: item.depth)
                }
            }
            .padding(.vertical, 4)
        }
        .background(ChromePalette.listWash)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder tree")
        .task(id: browser.libraryRoot.path) {
            children = [:]
            expanded = [DisplayFolder.root]
            await load(DisplayFolder.root)
            await reveal(browser.displayFolder)
        }
        .onChange(of: browser.displayFolder) { _, folder in
            Task { await reveal(folder) }
        }
    }

    private var visibleRows: [(node: LibraryFolderNode, depth: Int)] {
        var rows: [(node: LibraryFolderNode, depth: Int)] = []
        func append(_ node: LibraryFolderNode, _ depth: Int) {
            rows.append((node, depth))
            guard expanded.contains(node.rel) else { return }
            for child in children[node.rel] ?? [] {
                append(child, depth + 1)
            }
        }
        append(LibraryFolderNode(rel: DisplayFolder.root, name: DisplayFolder.root), 0)
        return rows
    }

    private func row(_ node: LibraryFolderNode, depth: Int) -> some View {
        let open = expanded.contains(node.rel)
        let known = children[node.rel]
        let hasChevron = known == nil || known?.isEmpty == false
        return HStack(spacing: 4) {
            if hasChevron {
                Button {
                    toggle(node.rel)
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
                    toggle(node.rel)
                }
                onSelect(node.rel)
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
        .background(browser.displayFolder == node.rel ? ChromePalette.listSelected : ChromePalette.listWash)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node.rel)
    }

    private func toggle(_ rel: String) {
        if expanded.contains(rel) {
            expanded.remove(rel)
            return
        }
        expanded.insert(rel)
        Task { await load(rel) }
    }

    private func load(_ rel: String) async {
        let root = browser.libraryRoot
        let found = await Task.detached(priority: .userInitiated) {
            LibraryFolderScan.childFolders(libraryRoot: root, parent: rel)
        }.value
        guard browser.libraryRoot.path == root.path else { return }
        children[rel] = found
    }

    /// Opens the folders above the one on screen so its row is in the list.
    private func reveal(_ folder: String) async {
        let parts = folder.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.first == "Photos" else { return }
        var chain: [String] = []
        var acc = ""
        for part in parts {
            acc = acc.isEmpty ? part : acc + "/" + part
            chain.append(acc)
        }
        for rel in chain.dropLast() {
            expanded.insert(rel)
            if children[rel] == nil {
                await load(rel)
            }
        }
    }
}
