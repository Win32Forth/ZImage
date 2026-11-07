import AppKit
import PDFKit
import SwiftUI

struct PDFPagePicker: View {
    var document: PDFDocument
    @Binding var pageIndex: Int
    var onOpen: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a page")
                .font(.system(size: 15, weight: .semibold))
            Text("Page \(pageIndex + 1) of \(document.pageCount)")
                .font(.system(size: 13))
                .foregroundStyle(ChromePalette.muted)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)], spacing: 16) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        pageButton(index)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                Button("Open page", action: onOpen)
                    .keyboardShortcut(.defaultAction)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PDF pages")
    }

    private func pageButton(_ index: Int) -> some View {
        Button {
            pageIndex = index
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                    if let page = document.page(at: index) {
                        Image(nsImage: page.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    }
                }
                .frame(width: 140, height: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(index == pageIndex ? Color(red: 184 / 255, green: 90 / 255, blue: 18 / 255) : ChromePalette.hairline, lineWidth: index == pageIndex ? 3 : 1)
                )
                Text("Page \(index + 1)")
                    .font(.system(size: 12))
                    .foregroundStyle(ChromePalette.ink)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(index + 1)")
    }
}
