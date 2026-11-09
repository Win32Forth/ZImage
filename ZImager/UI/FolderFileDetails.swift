import AppKit
import SwiftUI

/// The Disk folder column's image details. The same facts the library date panel reads from a file.
struct FolderFileDetails: View {
    @Bindable var model: EditorModel
    @State private var header = ReviewHeaderFacts(opened: false, lines: [])

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
            Text("Date")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChromePalette.ink)
            if let entry {
                line(entry.name)
                line(entry.url.path)
                line(model.sizeLabel(for: entry))
                if entry.isVideo {
                    line("Video")
                }
                ForEach(header.lines, id: \.self) { item in
                    line(item)
                }
                if header.opened && !header.hasDate && !entry.isVideo {
                    line("No DateTimeOriginal, DateTimeDigitized, or DateTime tag was in the file header.")
                }
            } else {
                Text("Select a file to see its preview and the dates in the file.")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityIdentifier("Date inspector")
        .task(id: model.selectedFolderKey) {
            await showSelection()
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let entry, let data = model.editedPreviewData(for: entry), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 180)
        } else if let entry, let jpeg = model.previewJPEG(for: entry), let image = NSImage(contentsOf: jpeg) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 180)
        } else if entry != nil {
            RoundedRectangle(cornerRadius: 4)
                .fill(ChromePalette.hairline)
                .frame(height: 120)
                .overlay {
                    Text("Loading preview")
                        .font(.system(size: 12))
                        .foregroundStyle(ChromePalette.ink)
                }
        }
    }

    private var entry: FolderEntry? {
        guard let key = model.selectedFolderKey else { return nil }
        return model.folderEntries.first { $0.id == key }
    }

    private func showSelection() async {
        header = ReviewHeaderFacts(opened: false, lines: [])
        guard let entry else { return }
        let key = entry.id
        let url = entry.url
        let video = entry.isVideo
        let facts = await Task.detached(priority: .userInitiated) {
            if video {
                return MovieHeaderFacts.read(url)
            }
            return ReviewHeaderFacts.read(url)
        }.value
        if model.selectedFolderKey == key {
            header = facts
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(ChromePalette.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
