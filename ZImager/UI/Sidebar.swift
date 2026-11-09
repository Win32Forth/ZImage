import AppKit
import SwiftUI

/// The folder column starts at 230 and can be dragged wide enough to read a name.
enum LibrarySidebarSpan {
    static let minimum: CGFloat = 180
    static let maximum: CGFloat = 720
    static let initial: CGFloat = 230

    static func clamped(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        let room = max(minimum, available - 240)
        let cap = min(maximum, room)
        return min(max(proposed, minimum), cap)
    }
}

/// Photos, Review, and Duplicates, then the folder tree. Videos are in the Photos grid. The store path stays `Photos/_Duplicates`.
struct Sidebar: View {
    @Binding var selection: String?
    @Bindable var browser: LibraryBrowser
    var onFolderPick: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            List(LibrarySidebar.items, id: \.self, selection: $selection) { item in
                Text(item)
                    .font(.system(size: 13))
                    .pastelListRow(selected: selection == item)
                    .tag(item)
            }
            .pastelListChrome()
            .scrollDisabled(true)
            .frame(height: 114)
            .accessibilityIdentifier("Library sidebar")
            Rectangle()
                .fill(ChromePalette.hairline)
                .frame(height: 1)
            LibraryFolderTree(browser: browser) { folder in
                browser.displayFolder = folder
                browser.notice = nil
                let section = LibrarySidebar.sectionAfterTreePick(selection)
                selection = section
                onFolderPick()
                Task { await browser.reload(media: LibrarySidebar.media(for: section)) }
            }
        }
        .background(ChromePalette.listWash)
    }
}

/// The line between the folder list and the grid. Drag it to read long names.
struct LibrarySidebarDivider: View {
    @Binding var width: CGFloat
    var available: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(ChromePalette.hairline)
                .frame(width: 1)
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if start == nil {
                        start = width
                    }
                    width = LibrarySidebarSpan.clamped((start ?? width) + value.translation.width, available: available)
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
        .accessibilityIdentifier("Sidebar splitter")
    }
}
