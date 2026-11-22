import AppKit
import SwiftUI

/// Joins the two selected photos. On Disk and on the server it sits under Move selected files.
struct MergePhotosPanel: View {
    var firstName: String?
    var secondName: String?
    var busy: Bool
    var previewing: Bool
    var ready: Bool
    var right: Int
    var down: Int
    var preview: (PhotoMergeAxis) -> Void
    var retarget: (PhotoMergeAxis) -> Void
    var merge: () -> Void
    var cancel: () -> Void

    @State private var axis = PhotoMergeAxis.horizontal
    @AppStorage(FolderPanelStore.merge) private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorPanelHeader(title: "Merge two photos", collapsed: collapsed) { collapsed.toggle() }
            if !collapsed {
                mergeControls
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityIdentifier("Merge photos panel")
    }

    private var mergeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(intro)
                .font(.system(size: 13))
                .foregroundStyle(ChromePalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Direction", selection: $axis) {
                ForEach(PhotoMergeAxis.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .disabled(busy)
            .accessibilityIdentifier("Merge direction")
            .onChange(of: axis) { _, newAxis in
                if previewing {
                    retarget(newAxis)
                }
            }
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(ChromePalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("Merge order")
            if previewing {
                Text("Arrow keys move the second photo. Click zooms in. Option-click zooms out. Hold Space and drag to move the view.")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(MergeOffset.caption(right: right, down: down))
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .accessibilityIdentifier("Merge offset")
                HStack(spacing: 8) {
                    Button("Merge") {
                        merge()
                    }
                    .disabled(!ready || busy)
                    .accessibilityIdentifier("Merge")
                    .help("Saves this placement as a TIFF in this folder. The original photos stay.")
                    Button("Cancel") {
                        cancel()
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("Cancel merge")
                    .help("Closes the preview without saving.")
                }
            } else {
                Button("Preview") {
                    preview(axis)
                }
                .disabled(firstName == nil || secondName == nil || busy)
                .accessibilityIdentifier("Preview")
                .help("Shows the joined photos. Arrow keys move the second photo before it is saved.")
            }
        }
    }

    private var intro: String {
        if previewing {
            return "The first photo is the left or the top. Merge saves the TIFF in this folder."
        }
        return "The first photo selected is the left or the top. The second is the right or the bottom. Preview shows the join, then Merge saves the TIFF in this folder."
    }

    private var caption: String {
        guard let firstName, let secondName else { return "Select two photos." }
        switch axis {
        case .horizontal:
            return "Left: \(firstName). Right: \(secondName)."
        case .vertical:
            return "Top: \(firstName). Bottom: \(secondName)."
        }
    }
}

enum MergeOffset {
    static func caption(right: Int, down: Int) -> String {
        if right == 0, down == 0 { return "Flush" }
        var parts: [String] = []
        if right > 0 {
            parts.append("\(right) right")
        } else if right < 0 {
            parts.append("\(-right) left")
        }
        if down > 0 {
            parts.append("\(down) down")
        } else if down < 0 {
            parts.append("\(-down) up")
        }
        return parts.joined(separator: ", ")
    }
}

/// Where the joined photo sits in the preview. Scale is points per image pixel.
/// The origin is the photo's top-left, measured from the view's top-left, with Y downward.
struct MergePreviewViewport: Equatable {
    var scale: CGFloat
    var originX: CGFloat
    var originY: CGFloat

    /// Same ceiling as the editor zoom.
    static let maximumScale: CGFloat = CGFloat(ZoomController.maximumMagnification)
    /// One click, matching the editor's zoom step.
    static let zoomStep: CGFloat = CGFloat(ZoomController.sqrtTwo)

    static func fitted(imageWidth: Int, imageHeight: Int, viewWidth: CGFloat, viewHeight: CGFloat) -> MergePreviewViewport {
        guard imageWidth > 0, imageHeight > 0, viewWidth > 1, viewHeight > 1 else {
            return MergePreviewViewport(scale: 1, originX: 0, originY: 0)
        }
        let scale = min(viewWidth / CGFloat(imageWidth), viewHeight / CGFloat(imageHeight))
        return MergePreviewViewport(
            scale: scale,
            originX: (viewWidth - CGFloat(imageWidth) * scale) / 2,
            originY: (viewHeight - CGFloat(imageHeight) * scale) / 2
        )
    }

    /// One point per pixel, with `focus` in the middle of the view.
    static func actualSize(
        focusX: CGFloat,
        focusY: CGFloat,
        imageWidth: Int,
        imageHeight: Int,
        viewWidth: CGFloat,
        viewHeight: CGFloat
    ) -> MergePreviewViewport {
        var view = MergePreviewViewport(
            scale: 1,
            originX: viewWidth / 2 - focusX,
            originY: viewHeight / 2 - focusY
        )
        view.clamp(imageWidth: imageWidth, imageHeight: imageHeight, viewWidth: viewWidth, viewHeight: viewHeight)
        return view
    }

    /// Option-click stops once the whole photo fits. Further clicks in stop at 4×.
    func limits(imageWidth: Int, imageHeight: Int, viewWidth: CGFloat, viewHeight: CGFloat) -> (min: CGFloat, max: CGFloat) {
        let fit = Self.fitted(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewWidth: viewWidth,
            viewHeight: viewHeight
        ).scale
        return (min(fit, Self.maximumScale), max(fit, Self.maximumScale))
    }

    /// Keeps the image pixel under `point` under that same view point.
    mutating func zoom(
        by factor: CGFloat,
        at point: CGPoint,
        imageWidth: Int,
        imageHeight: Int,
        viewWidth: CGFloat,
        viewHeight: CGFloat
    ) {
        guard scale > 0, factor > 0 else { return }
        let range = limits(imageWidth: imageWidth, imageHeight: imageHeight, viewWidth: viewWidth, viewHeight: viewHeight)
        let pixelX = (point.x - originX) / scale
        let pixelY = (point.y - originY) / scale
        let newScale = min(max(scale * factor, range.min), range.max)
        scale = newScale
        originX = point.x - pixelX * newScale
        originY = point.y - pixelY * newScale
        clamp(imageWidth: imageWidth, imageHeight: imageHeight, viewWidth: viewWidth, viewHeight: viewHeight)
    }

    /// Moves the whole photo. The two halves stay where the arrow keys put them.
    mutating func pan(
        dx: CGFloat,
        dy: CGFloat,
        imageWidth: Int,
        imageHeight: Int,
        viewWidth: CGFloat,
        viewHeight: CGFloat
    ) {
        originX += dx
        originY += dy
        clamp(imageWidth: imageWidth, imageHeight: imageHeight, viewWidth: viewWidth, viewHeight: viewHeight)
    }

    /// Keeps the same part of the first photo in view when an arrow key changes the canvas.
    mutating func rebase(
        oldFirstOrigin: CGPoint,
        newFirstOrigin: CGPoint,
        imageWidth: Int,
        imageHeight: Int,
        viewWidth: CGFloat,
        viewHeight: CGFloat
    ) {
        guard scale > 0, viewWidth > 1, viewHeight > 1 else { return }
        let centerX = viewWidth / 2
        let centerY = viewHeight / 2
        let pixelX = (centerX - originX) / scale - oldFirstOrigin.x
        let pixelY = (centerY - originY) / scale - oldFirstOrigin.y
        originX = centerX - (newFirstOrigin.x + pixelX) * scale
        originY = centerY - (newFirstOrigin.y + pixelY) * scale
        clamp(imageWidth: imageWidth, imageHeight: imageHeight, viewWidth: viewWidth, viewHeight: viewHeight)
    }

    mutating func clamp(imageWidth: Int, imageHeight: Int, viewWidth: CGFloat, viewHeight: CGFloat) {
        guard imageWidth > 0, imageHeight > 0, viewWidth > 1, viewHeight > 1, scale > 0 else { return }
        let width = CGFloat(imageWidth) * scale
        let height = CGFloat(imageHeight) * scale
        if width <= viewWidth {
            originX = (viewWidth - width) / 2
        } else {
            originX = min(0, max(viewWidth - width, originX))
        }
        if height <= viewHeight {
            originY = (viewHeight - height) / 2
        } else {
            originY = min(0, max(viewHeight - height, originY))
        }
    }
}

/// The joined photo in the center. A click zooms in at the pointer. Option-click zooms out.
/// Space-drag moves the whole photo.
struct MergePreviewCanvas: View {
    var image: CGImage
    var fitted: Bool
    var actualToken: Int
    var firstOrigin: CGPoint
    var focus: CGPoint
    var spaceDown: Bool
    var setFitted: (Bool) -> Void
    var chooseActualSize: () -> Void
    var userZoomed: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Fit") { setFitted(true) }
                    .buttonStyle(LibraryPushButtonStyle())
                    .accessibilityIdentifier("Merge preview fit")
                    .help("Fits the joined photo in the window.")
                Button("100%") { chooseActualSize() }
                    .buttonStyle(LibraryPushButtonStyle())
                    .accessibilityIdentifier("Merge preview actual size")
                    .help("Shows the join at one point per pixel, centered on the seam.")
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(ChromePalette.panel)
            MergePreviewScroll(
                image: image,
                fitted: fitted,
                actualToken: actualToken,
                firstOrigin: firstOrigin,
                focus: focus,
                spaceDown: spaceDown,
                userZoomed: userZoomed
            )
        }
        .background(Color.black)
        .accessibilityIdentifier("Merge preview")
    }
}

private struct MergePreviewScroll: NSViewRepresentable {
    var image: CGImage
    var fitted: Bool
    var actualToken: Int
    var firstOrigin: CGPoint
    var focus: CGPoint
    var spaceDown: Bool
    var userZoomed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MergePreviewHost {
        let host = MergePreviewHost()
        host.onUserZoom = userZoomed
        host.update(
            image: image,
            fitted: fitted,
            firstOrigin: firstOrigin,
            focus: focus,
            jumpToFocus: !fitted,
            spaceDown: spaceDown
        )
        context.coordinator.actualToken = actualToken
        return host
    }

    func updateNSView(_ host: MergePreviewHost, context: Context) {
        let jumpToFocus = context.coordinator.actualToken != actualToken
        context.coordinator.actualToken = actualToken
        host.onUserZoom = userZoomed
        host.update(
            image: image,
            fitted: fitted,
            firstOrigin: firstOrigin,
            focus: focus,
            jumpToFocus: jumpToFocus,
            spaceDown: spaceDown
        )
    }

    final class Coordinator {
        var actualToken = 0
    }
}

/// Draws the join itself. A click zooms about the pointer. Space-drag moves the whole photo.
final class MergePreviewHost: NSView {
    var onUserZoom: () -> Void = {}
    private var picture: CGImage?
    private var viewport = MergePreviewViewport(scale: 1, originX: 0, originY: 0)
    private var fitted = true
    private var firstOrigin = CGPoint.zero
    private var focus = CGPoint.zero
    private var didInstall = false
    private var pendingFocus = false
    private var panning = false
    private var downPoint = CGPoint.zero
    private var downOrigin = CGPoint.zero

    var spaceDown = false {
        didSet {
            if spaceDown != oldValue { refreshCursor() }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func layout() {
        super.layout()
        guard let picture, bounds.width > 1, bounds.height > 1 else { return }
        if fitted {
            applyFit()
            return
        }
        if pendingFocus {
            pendingFocus = false
            applyActual()
            return
        }
        let before = viewport
        viewport.clamp(
            imageWidth: picture.width,
            imageHeight: picture.height,
            viewWidth: bounds.width,
            viewHeight: bounds.height
        )
        if viewport != before { needsDisplay = true }
    }

    func update(
        image: CGImage,
        fitted: Bool,
        firstOrigin: CGPoint,
        focus: CGPoint,
        jumpToFocus: Bool,
        spaceDown: Bool
    ) {
        let sizeChanged = picture.map { $0.width != image.width || $0.height != image.height } ?? true
        let originChanged = self.firstOrigin != firstOrigin
        let previousOrigin = self.firstOrigin
        let hadImage = picture != nil
        picture = image
        self.firstOrigin = firstOrigin
        self.focus = focus
        self.spaceDown = spaceDown
        if fitted {
            self.fitted = true
            pendingFocus = false
            applyFit()
            didInstall = true
            return
        }
        self.fitted = false
        if !hadImage || jumpToFocus {
            if bounds.width > 1, bounds.height > 1 {
                applyActual()
                pendingFocus = false
            } else {
                pendingFocus = true
            }
            didInstall = true
            needsDisplay = true
            return
        }
        if sizeChanged || originChanged {
            viewport.rebase(
                oldFirstOrigin: previousOrigin,
                newFirstOrigin: firstOrigin,
                imageWidth: image.width,
                imageHeight: image.height,
                viewWidth: bounds.width,
                viewHeight: bounds.height
            )
        }
        didInstall = true
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = topDown(event)
        downOrigin = CGPoint(x: viewport.originX, y: viewport.originY)
        panning = spaceDown
        if panning { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard panning, let picture else { return }
        let now = topDown(event)
        viewport.originX = downOrigin.x
        viewport.originY = downOrigin.y
        viewport.pan(
            dx: now.x - downPoint.x,
            dy: now.y - downPoint.y,
            imageWidth: picture.width,
            imageHeight: picture.height,
            viewWidth: bounds.width,
            viewHeight: bounds.height
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if panning {
            panning = false
            refreshCursor()
            return
        }
        let up = topDown(event)
        let travel = hypot(up.x - downPoint.x, up.y - downPoint.y)
        guard travel < 4, let picture else { return }
        if event.modifierFlags.contains(.control) { return }
        let zoomOut = event.modifierFlags.contains(.option)
        let factor = zoomOut ? 1 / MergePreviewViewport.zoomStep : MergePreviewViewport.zoomStep
        fitted = false
        viewport.zoom(
            by: factor,
            at: downPoint,
            imageWidth: picture.width,
            imageHeight: picture.height,
            viewWidth: bounds.width,
            viewHeight: bounds.height
        )
        needsDisplay = true
        onUserZoom()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { return }
        super.keyDown(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        desiredCursor().set()
    }

    override func mouseEntered(with event: NSEvent) {
        desiredCursor().set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let picture, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let width = CGFloat(picture.width) * viewport.scale
        let height = CGFloat(picture.height) * viewport.scale
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return }
        ctx.interpolationQuality = viewport.scale >= 1 ? .none : .high
        ctx.draw(
            picture,
            in: CGRect(
                x: viewport.originX,
                y: bounds.height - viewport.originY - height,
                width: width,
                height: height
            )
        )
    }

    private func applyFit() {
        guard let picture, bounds.width > 1, bounds.height > 1 else { return }
        let next = MergePreviewViewport.fitted(
            imageWidth: picture.width,
            imageHeight: picture.height,
            viewWidth: bounds.width,
            viewHeight: bounds.height
        )
        guard next != viewport || !didInstall else { return }
        viewport = next
        needsDisplay = true
    }

    private func applyActual() {
        guard let picture, bounds.width > 1, bounds.height > 1 else { return }
        viewport = MergePreviewViewport.actualSize(
            focusX: focus.x,
            focusY: focus.y,
            imageWidth: picture.width,
            imageHeight: picture.height,
            viewWidth: bounds.width,
            viewHeight: bounds.height
        )
        needsDisplay = true
    }

    /// The view is not flipped, so this turns a window point into a top-left point.
    private func topDown(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    private func desiredCursor() -> NSCursor {
        if panning { return .closedHand }
        if spaceDown { return .openHand }
        return .arrow
    }

    private func refreshCursor() {
        guard let window else { return }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(location) {
            desiredCursor().set()
        }
    }
}
