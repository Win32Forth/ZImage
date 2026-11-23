import AppKit
import PDFKit
import SwiftUI

struct PDFPagePicker: View {
    var document: PDFDocument
    @Binding var pageIndex: Int
    var onOpen: (Int) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("Choose a page")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 12)
                Button("Cancel", action: onCancel)
                Button("Open page") { onOpen(pageIndex) }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Page \(pageIndex + 1) of \(document.pageCount)")
                .font(.system(size: 13))
                .foregroundStyle(ChromePalette.muted)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)], spacing: 16) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        PDFPageCell(
                            index: index,
                            thumbnail: document.page(at: index)?.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox),
                            selected: index == pageIndex,
                            select: { pageIndex = $0 },
                            openPage: onOpen
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PDF pages")
    }
}

/// One thumbnail. The page number is stored on this view, so a click cannot open a neighbor.
private struct PDFPageCell: View {
    var index: Int
    var thumbnail: NSImage?
    var selected: Bool
    var select: (Int) -> Void
    var openPage: (Int) -> Void

    var body: some View {
        Button {
            if NSApp.currentEvent?.clickCount == 2 {
                openPage(index)
            } else {
                select(index)
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    }
                }
                .frame(width: 140, height: 160)
                .clipped()
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(selected ? Color(red: 184 / 255, green: 90 / 255, blue: 18 / 255) : ChromePalette.hairline, lineWidth: selected ? 3 : 1)
                )
                Text("Page \(index + 1)")
                    .font(.system(size: 12))
                    .foregroundStyle(ChromePalette.ink)
            }
            .frame(width: 140)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(index + 1)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Double-click to open this page.")
    }
}
