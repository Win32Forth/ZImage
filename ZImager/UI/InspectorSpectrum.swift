import AppKit
import SwiftUI

/// Histogram and the three Preview-style handles, above Tone.
struct InspectorSpectrum: View {
    @Bindable var model: EditorModel
    @Binding var collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorPanelHeader(title: "Spectrum", collapsed: collapsed) {
                collapsed.toggle()
            }
            if !collapsed {
                SpectrumWell(model: model)
                    .frame(height: 104)
            }
        }
        .padding(EdgeInsets(top: InspectorMetrics.panelTopPadding, leading: 16, bottom: InspectorMetrics.panelBottomPadding, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Spectrum")
    }
}

/// The tone graph. Low, middle, and high sit on its bottom edge.
private struct SpectrumWell: View {
    @Bindable var model: EditorModel
    @State private var dragHandle: SpectrumHandle?
    @State private var dragOrigin: Double = 0
    @State private var suppressDrag = false
    @State private var lastClick: (handle: SpectrumHandle, time: Date)?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let graphHeight = max(48, geo.size.height - 16)
            let axisY = graphHeight + 5
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawWell(context: context, width: size.width, graphHeight: graphHeight)
                }
                .allowsHitTesting(false)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(drag(width: width, axisY: axisY))
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let hit = SpectrumLevels.nearest(
                                x: location.x,
                                y: location.y,
                                width: width,
                                axisY: axisY,
                                low: model.draftTone.spectrumLow,
                                mid: model.draftTone.spectrumMid,
                                high: model.draftTone.spectrumHigh
                            )
                            if hit == nil {
                                NSCursor.arrow.set()
                            } else {
                                NSCursor.resizeLeftRight.set()
                            }
                        case .ended:
                            NSCursor.arrow.set()
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spectrum")
        .accessibilityIdentifier("Spectrum graph")
        .help("Drag the low, middle, or high handle. Double-click a handle to reset it.")
    }

    private func drag(width: CGFloat, axisY: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.proxy != nil, width > 1 else { return }
                let handle: SpectrumHandle
                let origin: Double
                if let dragHandle, !suppressDrag {
                    handle = dragHandle
                    origin = dragOrigin
                } else if dragHandle == nil {
                    guard let found = SpectrumLevels.nearest(
                        x: value.startLocation.x,
                        y: value.startLocation.y,
                        width: width,
                        axisY: axisY,
                        low: model.draftTone.spectrumLow,
                        mid: model.draftTone.spectrumMid,
                        high: model.draftTone.spectrumHigh
                    ) else { return }
                    if let lastClick, lastClick.handle == found, Date().timeIntervalSince(lastClick.time) < 0.4 {
                        self.lastClick = nil
                        suppressDrag = true
                        dragHandle = found
                        model.resetSpectrum(found)
                        return
                    }
                    suppressDrag = false
                    dragHandle = found
                    origin = position(found)
                    dragOrigin = origin
                    model.beginSpectrumDrag()
                    handle = found
                } else {
                    return
                }
                let next = origin + Double((value.location.x - value.startLocation.x) / width)
                model.setSpectrum(handle, to: next)
            }
            .onEnded { _ in
                let handle = dragHandle
                let suppressed = suppressDrag
                dragHandle = nil
                suppressDrag = false
                guard let handle else { return }
                if suppressed { return }
                lastClick = (handle: handle, time: Date())
                model.endSpectrumDrag()
            }
    }

    private func position(_ handle: SpectrumHandle) -> Double {
        switch handle {
        case .low: return model.draftTone.spectrumLow
        case .mid: return model.draftTone.spectrumMid
        case .high: return model.draftTone.spectrumHigh
        }
    }

    private func drawWell(context: GraphicsContext, width: CGFloat, graphHeight: CGFloat) {
        let well = CGRect(x: 0, y: 0, width: width, height: graphHeight)
        let clip = Path(roundedRect: well, cornerRadius: 4)
        context.fill(clip, with: .color(Color.white.opacity(0.72)))
        context.stroke(clip, with: .color(ChromePalette.hairline), lineWidth: 1)
        context.drawLayer { layer in
            layer.clip(to: clip)
            layer.fill(histogramPath(width: width, graphHeight: graphHeight), with: .color(ChromePalette.ink.opacity(0.78)))
            let lowX = CGFloat(model.draftTone.spectrumLow) * width
            let highX = CGFloat(model.draftTone.spectrumHigh) * width
            if lowX > 0 {
                layer.fill(Path(CGRect(x: 0, y: 0, width: lowX, height: graphHeight)), with: .color(Color.black.opacity(0.16)))
            }
            if highX < width {
                layer.fill(
                    Path(CGRect(x: highX, y: 0, width: width - highX, height: graphHeight)),
                    with: .color(Color.black.opacity(0.16))
                )
            }
        }
        let axis = graphHeight
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: axis))
        baseline.addLine(to: CGPoint(x: width, y: axis))
        context.stroke(baseline, with: .color(ChromePalette.ink.opacity(0.35)), lineWidth: 1)
        drawHandle(.low, x: CGFloat(model.draftTone.spectrumLow) * width, tipY: axis, context: context)
        drawHandle(.mid, x: CGFloat(model.draftTone.spectrumMid) * width, tipY: axis, context: context)
        drawHandle(.high, x: CGFloat(model.draftTone.spectrumHigh) * width, tipY: axis, context: context)
    }

    private func histogramPath(width: CGFloat, graphHeight: CGFloat) -> Path {
        var path = Path()
        let bins = model.spectrumBins
        guard bins.count > 1, width > 1 else { return path }
        let peak = CGFloat(max(bins.max() ?? 1, 1))
        let ceiling = graphHeight - 6
        path.move(to: CGPoint(x: 0, y: graphHeight))
        for (index, bin) in bins.enumerated() {
            let x = CGFloat(index) / CGFloat(bins.count - 1) * width
            let y = graphHeight - (CGFloat(bin) / peak) * ceiling
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: width, y: graphHeight))
        path.closeSubpath()
        return path
    }

    private func drawHandle(_ handle: SpectrumHandle, x: CGFloat, tipY: CGFloat, context: GraphicsContext) {
        var triangle = Path()
        triangle.move(to: CGPoint(x: x, y: tipY - 1))
        triangle.addLine(to: CGPoint(x: x - 6, y: tipY + 12))
        triangle.addLine(to: CGPoint(x: x + 6, y: tipY + 12))
        triangle.closeSubpath()
        let fill: Color
        switch handle {
        case .low: fill = ChromePalette.ink
        case .mid: fill = ChromePalette.muted
        case .high: fill = Color.white
        }
        context.fill(triangle, with: .color(fill))
        context.stroke(triangle, with: .color(ChromePalette.ink), lineWidth: 1)
    }
}
