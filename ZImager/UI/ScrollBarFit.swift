import AppKit
import SwiftUI

/// Overlay scroll bars sit on the trailing edge.
/// A preview redraw was leaving that edge clipped, so the bar showed at half width.
enum ScrollBarFit {
    static let indicatorInset: CGFloat = 12
}

/// One reduced JPEG. Equal bytes keep the same image view, so a selection change does not rebuild it.
struct JPEGImage: View, Equatable {
    var data: Data

    var body: some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        }
    }
}
