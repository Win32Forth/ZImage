import SwiftUI

/// Geometry controls. A drag commits one `setGeometry` on mouse-up.
/// Keyboard nudges commit after 400 ms. Rotate and horizon commit immediately.
struct InspectorGeometry: View {
    @Bindable var model: EditorModel
    @Binding var collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorPanelHeader(title: "Geometry", collapsed: collapsed) { collapsed.toggle() }
            if !collapsed {
                VStack(alignment: .leading, spacing: InspectorMetrics.stackSpacing) {
                    HStack(spacing: 8) {
                        Button("Rotate left") { model.rotateCounterclockwise() }
                            .help("Rotates 90° counter-clockwise.")
                        Button("Rotate right") { model.rotateClockwise() }
                            .help("Rotates 90° clockwise.")
                        Spacer(minLength: 8)
                        Button("Horizon") { model.toggleCanvasTool(.horizon) }
                            .buttonStyle(LibraryPushButtonStyle())
                            .toolToggleBorder(active: model.canvasTool == .horizon)
                            .accessibilityAddTraits(model.canvasTool == .horizon ? .isSelected : [])
                            .help("Two clicks level a horizon. Click Horizon again to leave.")
                    }
                    slider("Straighten", value: model.draftGeometry.straightenDegrees, range: -45...45, readout: String(format: "%+.1f°", model.draftGeometry.straightenDegrees)) { value in
                        model.nudgeGeometry("Straighten") { $0.straightenDegrees = value }
                    }
                    slider("Vertical", value: model.draftGeometry.verticalKeystone, range: -1...1, readout: String(format: "%+.2f", model.draftGeometry.verticalKeystone)) { value in
                        model.nudgeGeometry("Vertical") { $0.verticalKeystone = value }
                    }
                    slider("Horizontal", value: model.draftGeometry.horizontalKeystone, range: -1...1, readout: String(format: "%+.2f", model.draftGeometry.horizontalKeystone)) { value in
                        model.nudgeGeometry("Horizontal") { $0.horizontalKeystone = value }
                    }
                    slider("Sharpness", value: model.draftGeometry.sharpness, range: -1...1, readout: String(format: "%+.2f", model.draftGeometry.sharpness)) { value in
                        model.nudgeGeometry("Sharpness") { $0.sharpness = value }
                    }
                    Toggle("Corner pin", isOn: Binding(
                        get: { model.draftGeometry.corners != nil },
                        set: { model.setCornerPin($0) }
                    ))
                    .toggleStyle(.switch)
                    .font(.system(size: 13))
                    if let corners = model.draftGeometry.corners {
                        corner("Top left", point: corners.topLeft) { point in
                            model.nudgeGeometry("Corners") { $0.corners?.topLeft = point }
                        }
                        corner("Top right", point: corners.topRight) { point in
                            model.nudgeGeometry("Corners") { $0.corners?.topRight = point }
                        }
                        corner("Bottom right", point: corners.bottomRight) { point in
                            model.nudgeGeometry("Corners") { $0.corners?.bottomRight = point }
                        }
                        corner("Bottom left", point: corners.bottomLeft) { point in
                            model.nudgeGeometry("Corners") { $0.corners?.bottomLeft = point }
                        }
                    }
                    Picker("Lens", selection: Binding(
                        get: { model.draftGeometry.lens.profileID },
                        set: { model.chooseLensProfile($0) }
                    )) {
                        ForEach(GeometryPipeline.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Lens")
                    slider("k1", value: model.draftGeometry.lens.k1, range: -0.50...0.20, readout: String(format: "%+.2f", model.draftGeometry.lens.k1)) { value in
                        model.nudgeGeometry("k1") { $0.lens.k1 = value }
                    }
                    slider("k2", value: model.draftGeometry.lens.k2, range: -0.20...0.20, readout: String(format: "%+.2f", model.draftGeometry.lens.k2)) { value in
                        model.nudgeGeometry("k2") { $0.lens.k2 = value }
                    }
                }
            }
        }
        .padding(EdgeInsets(top: InspectorMetrics.panelTopPadding, leading: 16, bottom: InspectorMetrics.panelBottomPadding, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Geometry")
    }

    private func slider(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        readout: String,
        set: @escaping (Double) -> Void
    ) -> some View {
        InspectorFieldRow(title: title, readout: readout) {
            InspectorSlider(
                value: value,
                range: range,
                onChange: set,
                onEditingChanged: { editing in
                    if editing {
                        model.beginGeometryDrag()
                    } else {
                        model.endGeometryDrag()
                    }
                },
                onReset: SliderReset.resets(title: title) ? {
                    model.beginGeometryDrag()
                    set(SliderReset.middle(of: range))
                    model.endGeometryDrag()
                } : nil
            )
            .inspectorControlHeight()
            .accessibilityLabel(title)
            .help(SliderReset.resets(title: title) ? "Double-click the knob to return it to the middle." : "")
        }
    }

    private func corner(_ title: String, point: NormPoint, set: @escaping (NormPoint) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1.6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(ChromePalette.muted)
            slider("\(title) X", value: point.x, range: -0.5...1.5, readout: String(format: "%.2f", point.x)) { value in
                set(NormPoint(x: value, y: point.y))
            }
            slider("\(title) Y", value: point.y, range: -0.5...1.5, readout: String(format: "%.2f", point.y)) { value in
                set(NormPoint(x: point.x, y: value))
            }
        }
    }
}
