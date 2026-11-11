import AppKit
import CoreGraphics
import SwiftUI

struct CanvasSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct CanvasView: View {
    @Bindable var model: EditorModel
    @State private var trackingPan = false
    @State private var trackingPinch = false
    @State private var cropDrag: CropDrag?
    @State private var cropDragStart: NormRect?
    @State private var pointerInside = false
    @State private var hoverPoint: CGPoint = .zero
    /// Stroke points live here so a drag can append without rebuilding the photo every event.
    @State private var scratchInk = ScratchInk()
    @State private var scratchEpoch = 0
    @State private var scratchDragging = false
    @State private var lastScratchPublish = 0.0
    /// The hand cursor currently on the AppKit stack, so a second push does not stick.
    @State private var pushedHand: NSCursor?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ChromePalette.canvas
                if let playback = model.videoPlayback {
                    VideoCanvasPlayer(player: playback.player)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityLabel(model.openedFileName ?? "Video")
                } else if let image = model.preview {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .frame(width: CGFloat(image.width), height: CGFloat(image.height))
                        .scaleEffect(model.zoom.magnification, anchor: .center)
                        .offset(model.zoom.offset)
                        .accessibilityLabel(model.openedFileName ?? "Opened image")
                } else {
                    Text(model.canvasMessage ?? "No image")
                        .font(model.canvasMessage == nil ? .title3 : .body)
                        .foregroundStyle(Color.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(ChromePalette.canvas)
            .clipped()
            .overlay {
                if showsBrushChrome {
                    Canvas { context, _ in
                        let diameter = brushDiameter
                        let points = scratchInk.points
                        if points.count > 1 {
                            var path = Path()
                            path.move(to: points[0])
                            for point in points.dropFirst() {
                                path.addLine(to: point)
                            }
                            context.stroke(
                                path,
                                with: .color(Color(white: 0.35).opacity(0.45)),
                                style: StrokeStyle(lineWidth: diameter, lineCap: .round, lineJoin: .round)
                            )
                        }
                        let rect = CGRect(
                            x: hoverPoint.x - diameter / 2,
                            y: hoverPoint.y - diameter / 2,
                            width: diameter,
                            height: diameter
                        )
                        context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.85)), lineWidth: 2)
                        context.stroke(
                            Path(ellipseIn: rect.insetBy(dx: 1.5, dy: 1.5)),
                            with: .color(.white.opacity(0.95)),
                            lineWidth: 1
                        )
                    }
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("Touchup brush")
                }
            }
            .overlay {
                if let selection = model.cropSelection, let image = model.preview {
                    CropSelectionOverlay(
                        selection: selection,
                        map: imageMap(in: geo.size, image: image),
                        showsHandles: model.canvasTool == .select
                    )
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if let banner = model.previewBanner {
                    Text(banner)
                        .font(.system(size: 13))
                        .foregroundStyle(ChromePalette.ink)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(ChromePalette.panel)
                }
            }
            .canvasHitTarget(model.videoPlayback == nil)
            .onContinuousHover { phase in
                guard model.videoPlayback == nil else { return }
                switch phase {
                case .active(let location):
                    pointerInside = true
                    hoverPoint = location
                    syncCursor(in: geo.size)
                case .ended:
                    if scratchDragging { break }
                    pointerInside = false
                    popHandCursor()
                    NSCursor.arrow.set()
                }
            }
            .onChange(of: model.spaceDown) { _, down in
                if down { clearScratchStroke() }
                syncCursor(in: geo.size)
            }
            .onChange(of: model.canvasTool) { _, tool in
                if tool != .scratchMark { clearScratchStroke() }
                if !model.handIsActive { trackingPan = false }
                syncCursor(in: geo.size)
            }
            .onChange(of: model.handIsActive) { _, active in
                if !active { trackingPan = false }
                syncCursor(in: geo.size)
            }
            .onChange(of: trackingPan) { _, _ in
                syncCursor(in: geo.size)
            }
            .onDisappear {
                popHandCursor()
                NSCursor.arrow.set()
            }
            .cropDrag(model.videoPlayback == nil && model.canvasTool == .select, selectGesture(in: geo.size))
            .cropDrag(model.videoPlayback == nil && model.canvasTool == .scratchMark && !model.handIsActive, scratchGesture(in: geo.size))
            .cropDrag(model.videoPlayback == nil && model.handIsActive, panGesture(in: geo.size))
            .stillGesture(model.videoPlayback == nil, pinchGesture(in: geo.size))
            .stillGesture(model.videoPlayback == nil, zoomClickGesture(in: geo.size))
            .preference(key: CanvasSizeKey.self, value: geo.size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Canvas")
        .onPreferenceChange(CanvasSizeKey.self) { model.updateCanvasSize($0) }
    }

    /// Open hand while the hand is armed. Closed hand while a drag is moving the image.
    private func syncCursor(in viewSize: CGSize) {
        guard pointerInside else {
            popHandCursor()
            return
        }
        if model.handIsActive {
            let cursor: NSCursor = trackingPan ? .closedHand : .openHand
            if pushedHand !== cursor {
                popHandCursor()
                cursor.push()
                pushedHand = cursor
            }
            return
        }
        popHandCursor()
        guard model.canvasTool == .select, let image = model.preview else {
            NSCursor.arrow.set()
            return
        }
        selectionCursor(at: hoverPoint, image: image, in: viewSize).set()
    }

    /// The circle and the gray scratch trail stay up for the whole drag, including after hover tracking ends.
    private var showsBrushChrome: Bool {
        guard model.preview != nil, !model.spaceDown else { return false }
        guard model.canvasTool == .dustSpot || model.canvasTool == .scratchMark else { return false }
        return pointerInside || scratchDragging
    }

    private var brushDiameter: CGFloat {
        max(4, CGFloat(model.touchupBrushDiameter) * CGFloat(model.zoom.magnification))
    }

    private func clearScratchStroke() {
        scratchDragging = false
        scratchInk.dragging = false
        scratchInk.points.removeAll()
        scratchEpoch += 1
    }

    private func popHandCursor() {
        guard pushedHand != nil else { return }
        NSCursor.pop()
        pushedHand = nil
    }

    private func selectionCursor(at location: CGPoint, image: CGImage, in viewSize: CGSize) -> NSCursor {
        guard let selection = model.cropSelection else { return .crosshair }
        let rect = imageMap(in: viewSize, image: image).viewRect(for: selection)
        guard let handle = CropMarquee.hitHandle(at: location, in: rect) else { return .crosshair }
        switch handle {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return .crosshair
        }
    }

    private func imageMap(in viewSize: CGSize, image: CGImage) -> ImageViewMap {
        ImageViewMap(
            viewSize: viewSize,
            imageSize: CGSize(width: image.width, height: image.height),
            magnification: CGFloat(model.zoom.magnification),
            offset: model.zoom.offset
        )
    }

    private func selectGesture(in viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.canvasTool == .select, let image = model.preview else { return }
                selectionCursor(at: value.location, image: image, in: viewSize).set()
                let map = imageMap(in: viewSize, image: image)
                if cropDrag == nil {
                    cropDrag = CropMarquee.begin(at: value.startLocation, selection: model.cropSelection, map: map)
                    cropDragStart = model.cropSelection
                }
                guard let cropDrag else { return }
                model.cropSelection = CropMarquee.updated(
                    drag: cropDrag,
                    startSelection: cropDragStart,
                    startView: value.startLocation,
                    currentView: value.location,
                    map: map
                )
            }
            .onEnded { _ in
                if let rect = model.cropSelection, let image = model.preview,
                   !CropRect.isUsable(rect, pixelWidth: image.width, pixelHeight: image.height) {
                    model.cropSelection = nil
                }
                cropDrag = nil
                cropDragStart = nil
            }
    }

    private func scratchGesture(in viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.canvasTool == .scratchMark, !model.spaceDown else { return }
                if !scratchDragging {
                    scratchDragging = true
                    scratchInk.dragging = true
                    scratchInk.points.removeAll()
                    scratchInk.points.append(value.startLocation)
                }
                if let last = scratchInk.points.last {
                    let dx = value.location.x - last.x
                    let dy = value.location.y - last.y
                    if dx * dx + dy * dy >= 16 {
                        scratchInk.points.append(value.location)
                    }
                }
                let now = Date().timeIntervalSinceReferenceDate
                guard now - lastScratchPublish >= 1.0 / 40 else { return }
                lastScratchPublish = now
                hoverPoint = value.location
                scratchEpoch += 1
            }
            .onEnded { value in
                let point = value.location
                if scratchInk.points.last.map({ hypot($0.x - point.x, $0.y - point.y) > 1 }) ?? true {
                    scratchInk.points.append(point)
                }
                let points = scratchInk.points
                hoverPoint = point
                clearScratchStroke()
                guard points.count >= 2 else { return }
                model.scratchStroke(points, in: viewSize)
            }
    }

    private func panGesture(in viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard model.handIsActive else { return }
                if !trackingPan {
                    model.beginPan()
                    trackingPan = true
                }
                model.pan(translation: value.translation)
            }
            .onEnded { _ in
                trackingPan = false
            }
    }

    private func pinchGesture(in viewSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if !trackingPinch {
                    model.beginPinch()
                    trackingPinch = true
                }
                let anchor = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                model.pinchChanged(scale: Double(scale), anchor: anchor, viewSize: viewSize)
            }
            .onEnded { _ in
                trackingPinch = false
            }
    }

    private func zoomClickGesture(in viewSize: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                if model.canvasTool == .horizon {
                    model.horizonClick(at: value.location, in: viewSize)
                    return
                }
                if model.canvasTool == .eyedropper {
                    model.eyedropperClick(at: value.location, in: viewSize)
                    return
                }
                if model.canvasTool == .removeObject {
                    model.removeObjectClick(at: value.location, in: viewSize)
                    return
                }
                if model.canvasTool == .dustSpot {
                    model.dustSpotClick(at: value.location, in: viewSize)
                    return
                }
                if model.canvasTool == .scratchMark {
                    return
                }
                let flags = NSEvent.modifierFlags
                guard let zoom = model.canvasTool.clickZoom(
                    command: flags.contains(.command),
                    option: flags.contains(.option)
                ) else { return }
                switch zoom {
                case .zoomIn:
                    model.zoomIn(about: value.location, in: viewSize)
                case .zoomOut:
                    model.zoomOut(about: value.location, in: viewSize)
                }
            }
    }
}

/// View points gathered while Scratch is dragged. A class so appending does not copy the whole stroke.
private final class ScratchInk {
    var points: [CGPoint] = []
    var dragging = false
}

/// The crop rectangle and its eight handles, drawn in the canvas.
struct CropSelectionOverlay: View {
    var selection: NormRect
    var map: ImageViewMap
    var showsHandles: Bool

    var body: some View {
        let rect = map.viewRect(for: selection)
        Canvas { context, size in
            var shade = Path()
            shade.addRect(CGRect(origin: .zero, size: size))
            shade.addRect(rect)
            context.fill(shade, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            context.stroke(Path(rect), with: .color(.black.opacity(0.9)), lineWidth: 3)
            context.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)
            guard showsHandles else { return }
            for handle in CropHandle.allCases {
                let mark = CropMarquee.handlePoint(in: rect, handle: handle)
                let box = CGRect(x: mark.x - 6, y: mark.y - 6, width: 12, height: 12)
                context.fill(Path(box), with: .color(.white))
                context.stroke(Path(box), with: .color(.black), lineWidth: 1.5)
            }
        }
        .accessibilityIdentifier("Crop selection")
    }
}

private extension View {
    @ViewBuilder
    func cropDrag(_ enabled: Bool, _ gesture: some Gesture) -> some View {
        if enabled {
            highPriorityGesture(gesture)
        } else {
            self
        }
    }

    @ViewBuilder
    func canvasHitTarget(_ enabled: Bool) -> some View {
        if enabled {
            contentShape(Rectangle())
        } else {
            self
        }
    }

    @ViewBuilder
    func stillGesture(_ enabled: Bool, _ gesture: some Gesture) -> some View {
        if enabled {
            simultaneousGesture(gesture)
        } else {
            self
        }
    }
}
