import AppKit
import SwiftUI

/// Control-click on macOS is delivered as a right-click, which opens the cell menu.
/// This view takes that click only while Control is held, so the photo toggles and the menu stays closed.
/// A plain click, a Shift-click, a Command-click, and a real right-click fall through.
struct ControlClickCatcher: NSViewRepresentable {
    var onToggle: () -> Void

    func makeNSView(context: Context) -> ControlClickView {
        let view = ControlClickView()
        view.onToggle = onToggle
        return view
    }

    func updateNSView(_ view: ControlClickView, context: Context) {
        view.onToggle = onToggle
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ControlClickView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class ControlClickView: NSView {
    var onToggle: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSEvent.modifierFlags.contains(.control) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        onToggle?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        onToggle?()
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }
}
