import SwiftUI

/// Dust and scratch repair. Spot and Scratch stay on until they are clicked again.
struct InspectorTouchup: View {
    @Bindable var model: EditorModel
    @Binding var collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorPanelHeader(title: "Touchup", collapsed: collapsed) { collapsed.toggle() }
            if !collapsed {
            HStack(spacing: 8) {
                Button("Dust") { model.removeDust() }
                    .buttonStyle(LibraryPushButtonStyle())
                    .disabled(model.proxy == nil)
                    .accessibilityIdentifier("Dust")
                    .help("Finds dust and blends it into the surrounding photo.")
                Button("Scratches") { model.removeScratches() }
                    .buttonStyle(LibraryPushButtonStyle())
                    .disabled(model.proxy == nil)
                    .accessibilityIdentifier("Scratches")
                    .help("Finds scratches and blends them into the surrounding photo.")
            }
            HStack(spacing: 8) {
                Button("Spot") { model.toggleCanvasTool(.dustSpot) }
                    .buttonStyle(LibraryPushButtonStyle())
                    .toolToggleBorder(active: model.canvasTool == .dustSpot)
                    .disabled(model.proxy == nil)
                    .accessibilityIdentifier("Spot")
                    .accessibilityAddTraits(model.canvasTool == .dustSpot ? .isSelected : [])
                    .help("Cover a speck with the circle and click it. More clicks wait in a list of \(TouchupQueue.cap). Click Spot again to leave.")
                Button("Scratch") { model.toggleCanvasTool(.scratchMark) }
                    .buttonStyle(LibraryPushButtonStyle())
                    .toolToggleBorder(active: model.canvasTool == .scratchMark)
                    .disabled(model.proxy == nil)
                    .accessibilityIdentifier("Scratch")
                    .accessibilityAddTraits(model.canvasTool == .scratchMark ? .isSelected : [])
                    .help("Drag the circle along a scratch. Click Scratch again to leave.")
            }
            if let left = model.touchupSpotsLeftLabel {
                Text(left)
                    .font(.body)
                    .foregroundStyle(ChromePalette.muted)
                    .accessibilityIdentifier("Spots left")
            }
            InspectorFieldRow(title: "Size", readout: "\(Int(model.touchupBrushDiameter.rounded())) px") {
                InspectorSlider(
                    value: model.touchupBrushDiameter,
                    range: 8...200,
                    onChange: { model.touchupBrushDiameter = $0 },
                    onEditingChanged: { _ in },
                    onReset: { model.touchupBrushDiameter = 48 }
                )
                .inspectorControlHeight()
                .disabled(model.proxy == nil)
                .accessibilityLabel("Touchup size")
                .help("Diameter of the Spot and Scratch circle. Double-click the knob to restore 48 px.")
            }
            amountSlider("Dust", modelID: InpaintModel.dust)
            amountSlider("Scratches", modelID: InpaintModel.scratch)
            }
        }
        .padding(EdgeInsets(
            top: InspectorMetrics.panelTopPadding,
            leading: 16,
            bottom: InspectorMetrics.panelBottomPadding,
            trailing: 16
        ))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Touchup")
    }

    private func amountSlider(_ title: String, modelID: String) -> some View {
        let value = model.touchupStrength(modelID: modelID)
        return InspectorFieldRow(title: title, readout: "\(Int((value * 100).rounded()))%") {
            InspectorSlider(
                value: value,
                range: 0...1,
                onChange: { model.setTouchupStrength(modelID: modelID, $0) },
                onEditingChanged: { editing in
                    if editing {
                        model.beginTouchupStrength(modelID: modelID)
                    } else {
                        model.endTouchupStrength(modelID: modelID)
                    }
                },
                onReset: { model.resetTouchupStrength(modelID: modelID) }
            )
            .inspectorControlHeight()
            .disabled(!model.hasTouchup(modelID) || model.touchupBusy)
            .accessibilityLabel("\(title) amount")
            .help("Double-click the knob to restore the full repair.")
        }
    }
}
