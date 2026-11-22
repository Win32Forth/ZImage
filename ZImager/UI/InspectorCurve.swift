import AppKit
import SwiftUI

/// The tone curve. RGB runs first. Red, green, and blue run after it.
struct InspectorCurve: View {
    @Bindable var model: EditorModel
    @Binding var collapsed: Bool
    @AppStorage("ZImage.curveChannel") private var channel = CurveChannel.rgb

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorPanelHeader(title: "Curve", collapsed: collapsed) { collapsed.toggle() }
            if !collapsed {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Channel", selection: $channel) {
                        ForEach(CurveChannel.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("Curve channel")
                    .help("RGB shapes the picture. Red, Green, and Blue shape one channel after that.")
                    CurveWell(model: model, channel: channel)
                        .frame(height: 168)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(CurvePreset.allCases) { preset in
                            presetButton(preset)
                        }
                    }
                }
            }
        }
        .padding(EdgeInsets(top: InspectorMetrics.panelTopPadding, leading: 16, bottom: InspectorMetrics.panelBottomPadding, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Curve")
    }

    private func presetButton(_ preset: CurvePreset) -> some View {
        let on = preset.matches(model.draftTone.curves)
        return Button(preset.title) {
            channel = .rgb
            model.applyCurvePreset(preset)
        }
        .buttonStyle(LibraryPushButtonStyle())
        .toolToggleBorder(active: on)
        .disabled(model.proxy == nil && !model.showsVideo)
        .accessibilityIdentifier(preset.title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(preset.help)
    }
}

/// Histogram, curve, and handles for one channel.
private struct CurveWell: View {
    @Bindable var model: EditorModel
    var channel: CurveChannel
    @State private var dragIndex: Int?
    @State private var dragChannel: CurveChannel?
    @State private var dragOrigin: CurvePoint?
    @State private var suppressDrag = false
    @State private var lastClick: (index: Int, time: Date)?

    var body: some View {
        GeometryReader { geo in
            let plot = plotRect(in: geo.size)
            let curve = channel.curve(in: model.draftTone.curves)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawWell(context: context, size: size, plot: plotRect(in: size), curve: curve)
                }
                .allowsHitTesting(false)
                Color.clear
                    .contentShape(Rectangle())
                    .highPriorityGesture(drag(plot: plot))
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if handleIndex(at: location, plot: plot, curve: curve) != nil {
                                NSCursor.pointingHand.set()
                            } else if nearCurve(location, plot: plot, curve: curve) {
                                NSCursor.crosshair.set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        case .ended:
                            NSCursor.arrow.set()
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Curve")
        .accessibilityIdentifier("Curve graph")
        .help("Drag a handle. Click the curve to add one, up to eight. Double-click a middle handle to remove it. Double-click an end to put that corner back.")
    }

    private var canEdit: Bool {
        model.proxy != nil || model.showsVideo
    }

    private func plotRect(in size: CGSize) -> CGRect {
        let inset: CGFloat = 8
        return CGRect(
            x: inset,
            y: inset,
            width: max(1, size.width - inset * 2),
            height: max(1, size.height - inset * 2)
        )
    }

    private func drag(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard canEdit, plot.width > 1, plot.height > 1 else { return }
                if suppressDrag { return }
                if dragIndex == nil {
                    let curve = channel.curve(in: model.draftTone.curves)
                    if let hit = handleIndex(at: value.startLocation, plot: plot, curve: curve) {
                        if let lastClick, lastClick.index == hit, Date().timeIntervalSince(lastClick.time) < 0.4 {
                            self.lastClick = nil
                            suppressDrag = true
                            dragIndex = hit
                            let next = (hit == 0 || hit == curve.points.count - 1)
                                ? curve.resettingEndpoint(hit)
                                : curve.removing(index: hit)
                            model.beginCurveDrag()
                            model.setCurve(channel, to: next)
                            model.endCurveDrag()
                            return
                        }
                        dragIndex = hit
                        dragChannel = channel
                        dragOrigin = curve.points[hit]
                        model.beginCurveDrag()
                    } else if nearCurve(value.startLocation, plot: plot, curve: curve),
                              let inserted = curve.inserting(x: curveX(value.startLocation, plot: plot)) {
                        dragIndex = inserted.index
                        dragChannel = channel
                        dragOrigin = inserted.curve.points[inserted.index]
                        model.beginCurveDrag()
                        model.setCurve(channel, to: inserted.curve)
                    } else {
                        return
                    }
                }
                guard let dragIndex, let dragOrigin, let dragChannel else { return }
                let dx = Double((value.location.x - value.startLocation.x) / plot.width)
                let dy = Double((value.startLocation.y - value.location.y) / plot.height)
                let moved = dragChannel.curve(in: model.draftTone.curves).moving(
                    index: dragIndex,
                    x: dragOrigin.x + dx,
                    y: dragOrigin.y + dy
                )
                model.setCurve(dragChannel, to: moved)
            }
            .onEnded { _ in
                let index = dragIndex
                let suppressed = suppressDrag
                dragIndex = nil
                dragChannel = nil
                dragOrigin = nil
                suppressDrag = false
                guard let index else { return }
                if suppressed { return }
                lastClick = (index: index, time: Date())
                model.endCurveDrag()
            }
    }

    private func handleIndex(at location: CGPoint, plot: CGRect, curve: ToneCurve) -> Int? {
        var best: Int?
        var bestDistance: CGFloat = 14
        for (index, point) in curve.points.enumerated() {
            let distance = hypot(location.x - plotX(point.x, plot: plot), location.y - plotY(point.y, plot: plot))
            if distance <= bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func nearCurve(_ location: CGPoint, plot: CGRect, curve: ToneCurve) -> Bool {
        guard location.x >= plot.minX, location.x <= plot.maxX else { return false }
        let y = curve.evaluate(curveX(location, plot: plot))
        return abs(location.y - plotY(y, plot: plot)) <= 14
    }

    private func curveX(_ location: CGPoint, plot: CGRect) -> Double {
        Double(min(1, max(0, (location.x - plot.minX) / plot.width)))
    }

    private func plotX(_ x: Double, plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(x) * plot.width
    }

    private func plotY(_ y: Double, plot: CGRect) -> CGFloat {
        plot.maxY - CGFloat(min(1, max(0, y))) * plot.height
    }

    private func drawWell(context: GraphicsContext, size: CGSize, plot: CGRect, curve: ToneCurve) {
        let well = CGRect(origin: .zero, size: size)
        let clip = Path(roundedRect: well, cornerRadius: 4)
        context.fill(clip, with: .color(Color.white.opacity(0.72)))
        context.stroke(clip, with: .color(ChromePalette.hairline), lineWidth: 1)
        let ink = channelColor(channel)
        context.drawLayer { layer in
            layer.clip(to: clip)
            layer.fill(histogramPath(plot: plot), with: .color(ink.opacity(0.28)))
            var diagonal = Path()
            diagonal.move(to: CGPoint(x: plot.minX, y: plot.maxY))
            diagonal.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
            layer.stroke(diagonal, with: .color(ChromePalette.muted.opacity(0.45)), lineWidth: 1)
            var line = Path()
            let samples = 64
            for index in 0...samples {
                let x = Double(index) / Double(samples)
                let point = CGPoint(x: plotX(x, plot: plot), y: plotY(curve.evaluate(x), plot: plot))
                if index == 0 {
                    line.move(to: point)
                } else {
                    line.addLine(to: point)
                }
            }
            layer.stroke(line, with: .color(ink), lineWidth: 1.5)
        }
        for point in curve.points {
            let center = CGPoint(x: plotX(point.x, plot: plot), y: plotY(point.y, plot: plot))
            let handle = Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
            context.fill(handle, with: .color(Color.white))
            context.stroke(handle, with: .color(ink), lineWidth: 1.5)
        }
    }

    private func histogramPath(plot: CGRect) -> Path {
        var path = Path()
        let bins = model.curveHistogram.bins(for: channel)
        guard bins.count > 1, plot.width > 1 else { return path }
        let peak = CGFloat(max(bins.max() ?? 1, 1))
        path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        for (index, bin) in bins.enumerated() {
            let x = plot.minX + CGFloat(index) / CGFloat(bins.count - 1) * plot.width
            let y = plot.maxY - (CGFloat(bin) / peak) * plot.height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.closeSubpath()
        return path
    }

    private func channelColor(_ channel: CurveChannel) -> Color {
        switch channel {
        case .rgb: return ChromePalette.ink
        case .red: return Color(red: 0.72, green: 0.18, blue: 0.16)
        case .green: return Color(red: 0.16, green: 0.46, blue: 0.24)
        case .blue: return Color(red: 0.18, green: 0.32, blue: 0.62)
        }
    }
}
