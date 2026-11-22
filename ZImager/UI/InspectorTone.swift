import SwiftUI

enum ToneReadout {
    case tenth
    case hundredth
    case kelvin
    case tint

    func text(_ value: Double) -> String {
        switch self {
        case .tenth:
            return String(format: "%+.1f", value)
        case .hundredth:
            return String(format: "%+.2f", value)
        case .kelvin:
            return String(format: "%.0f K", value)
        case .tint:
            return String(format: "%+.0f", value)
        }
    }
}

struct ToneSliderSpec: Identifiable {
    var title: String
    var range: ClosedRange<Double>
    var keyPath: WritableKeyPath<ToneState, Double>
    var readout: ToneReadout
    var historyLabel: String? = nil
    var help: String? = nil
    var id: String { historyLabel ?? title }

    static let tone: [ToneSliderSpec] = [
        ToneSliderSpec(title: "Exposure", range: -5...5, keyPath: \.exposureEV, readout: .tenth),
        ToneSliderSpec(title: "Brightness", range: -1...1, keyPath: \.brightness, readout: .hundredth),
        ToneSliderSpec(title: "Contrast", range: -1...1, keyPath: \.contrast, readout: .hundredth),
        ToneSliderSpec(title: "Highlights", range: -1...1, keyPath: \.highlights, readout: .hundredth),
        ToneSliderSpec(title: "Shadows", range: -1...1, keyPath: \.shadows, readout: .hundredth),
        ToneSliderSpec(title: "Whites", range: -1...1, keyPath: \.whites, readout: .hundredth),
        ToneSliderSpec(title: "Blacks", range: -1...1, keyPath: \.blacks, readout: .hundredth),
        ToneSliderSpec(title: "Dehaze", range: 0...1, keyPath: \.dehaze, readout: .hundredth),
        ToneSliderSpec(title: "Vibrance", range: -1...1, keyPath: \.vibrance, readout: .hundredth),
        ToneSliderSpec(title: "Saturation", range: -1...1, keyPath: \.saturation, readout: .hundredth),
    ]

    /// Local contrast. These sit under a hairline, with Sharpness drawn after them.
    static let detail: [ToneSliderSpec] = [
        ToneSliderSpec(title: "Texture", range: -1...1, keyPath: \.texture, readout: .hundredth),
        ToneSliderSpec(title: "Clarity", range: -1...1, keyPath: \.clarity, readout: .hundredth),
        ToneSliderSpec(title: "Details", range: -1...1, keyPath: \.details, readout: .hundredth),
    ]

    static let color: [ToneSliderSpec] = [
        ToneSliderSpec(title: "Temperature", range: 2000...50000, keyPath: \.temperature, readout: .kelvin),
        ToneSliderSpec(title: "Tint", range: -150...150, keyPath: \.tint, readout: .tint),
    ]

    static let vignette: [ToneSliderSpec] = [
        ToneSliderSpec(
            title: "Amount",
            range: -1...1,
            keyPath: \.vignetteAmount,
            readout: .hundredth,
            historyLabel: "Vignette amount",
            help: "Negative darkens the edges. Positive lightens them. Double-click returns it to none."
        ),
        ToneSliderSpec(
            title: "Midpoint",
            range: 0...1,
            keyPath: \.vignetteMidpoint,
            readout: .hundredth,
            historyLabel: "Vignette midpoint",
            help: "Moves the clear center outward. Double-click returns it to the middle."
        ),
        ToneSliderSpec(
            title: "Roundness",
            range: -1...1,
            keyPath: \.vignetteRoundness,
            readout: .hundredth,
            historyLabel: "Vignette roundness",
            help: "Negative follows the frame. Positive pulls the edge toward a circle. Double-click returns it to an ellipse."
        ),
        ToneSliderSpec(
            title: "Feather",
            range: 0...1,
            keyPath: \.vignetteFeather,
            readout: .hundredth,
            historyLabel: "Vignette feather",
            help: "Softens the edge. Double-click returns it to the middle."
        ),
        ToneSliderSpec(
            title: "X",
            range: -1...1,
            keyPath: \.vignetteCenterX,
            readout: .hundredth,
            historyLabel: "Vignette X",
            help: "Moves the clear center left or right. Positive goes right. Double-click returns it to the middle."
        ),
        ToneSliderSpec(
            title: "Y",
            range: -1...1,
            keyPath: \.vignetteCenterY,
            readout: .hundredth,
            historyLabel: "Vignette Y",
            help: "Moves the clear center down or up. Positive goes up. Double-click returns it to the middle."
        ),
    ]
}

/// Tone sliders. A drag commits one `setTone` on mouse-up. Keyboard nudges commit
/// once the value has been still for 400 ms. The log does not record the in-between values.
struct InspectorTone: View {
    @Bindable var model: EditorModel
    @Binding var collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorPanelHeader(
                title: "Tone",
                collapsed: collapsed,
                accessory: HStack(spacing: 8) {
                    Button("Auto") { model.autoAdjustTone() }
                        .buttonStyle(LibraryPushButtonStyle())
                        .disabled(model.proxy == nil && !model.showsVideo)
                        .accessibilityIdentifier("Auto")
                        .help("Sets Exposure, Contrast, Highlights, Shadows, Whites, and Blacks from this photograph.")
                    Button("Reset") { model.resetPhoto() }
                        .buttonStyle(LibraryPushButtonStyle())
                        .disabled(!model.canResetPhoto)
                        .accessibilityIdentifier("Reset")
                        .help("Returns this photograph to the start. Redo brings each change back, one at a time.")
                    Button("Flatten") { model.confirmFlatten() }
                        .buttonStyle(LibraryPushButtonStyle())
                        .disabled(!model.canFlattenPhoto)
                        .accessibilityIdentifier("Flatten")
                        .help("Opens Flatten. Continue saves the edits into a TIFF beside the edits. Duplicate writes that TIFF next to this photo and leaves this photo as it is.")
                },
                toggle: { collapsed.toggle() }
            )
            if !collapsed {
                VStack(alignment: .leading, spacing: InspectorMetrics.stackSpacing) {
                    ForEach(ToneSliderSpec.tone) { spec in
                        ToneSliderControl(model: model, spec: spec)
                    }
                    Rectangle()
                        .fill(ChromePalette.hairline)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                    ForEach(ToneSliderSpec.detail) { spec in
                        ToneSliderControl(model: model, spec: spec)
                    }
                    sharpnessSlider
                }
            }
        }
        .padding(EdgeInsets(top: InspectorMetrics.panelTopPadding, leading: 16, bottom: InspectorMetrics.panelBottomPadding, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Tone")
    }

    /// Sharpness stays on the geometry record. The slider is here so it sits with the other detail controls.
    /// A video does not run geometry, so the slider is off while one is open.
    private var sharpnessSlider: some View {
        InspectorFieldRow(title: "Sharpness", readout: String(format: "%+.2f", model.draftGeometry.sharpness)) {
            InspectorSlider(
                value: model.draftGeometry.sharpness,
                range: -1...1,
                onChange: { value in
                    model.nudgeGeometry("Sharpness") { $0.sharpness = value }
                },
                onEditingChanged: { editing in
                    if editing {
                        model.beginGeometryDrag()
                    } else {
                        model.endGeometryDrag()
                    }
                },
                onReset: {
                    model.beginGeometryDrag()
                    model.nudgeGeometry("Sharpness") { $0.sharpness = 0 }
                    model.endGeometryDrag()
                }
            )
            .inspectorControlHeight()
            .accessibilityLabel("Sharpness")
            .help("Double-click the knob to return it to the middle.")
        }
        .disabled(model.showsVideo)
    }
}

/// One Tone or Color slider. Temperature stays put on a double-click. Tint returns to the middle.
struct ToneSliderControl: View {
    @Bindable var model: EditorModel
    var spec: ToneSliderSpec

    var body: some View {
        InspectorFieldRow(title: spec.title, readout: spec.readout.text(model.draftTone[keyPath: spec.keyPath])) {
            InspectorSlider(
                value: model.draftTone[keyPath: spec.keyPath],
                range: spec.range,
                onChange: { model.nudgeTone(spec.keyPath, to: $0, label: spec.historyLabel ?? spec.title) },
                onEditingChanged: { editing in
                    if editing {
                        model.beginToneDrag()
                    } else {
                        model.endToneDrag()
                    }
                },
                onReset: SliderReset.resets(title: spec.title) ? {
                    model.beginToneDrag()
                    model.nudgeTone(spec.keyPath, to: SliderReset.middle(of: spec.range), label: spec.historyLabel ?? spec.title)
                    model.endToneDrag()
                } : nil
            )
            .inspectorControlHeight()
            .accessibilityLabel(spec.title)
            .help(spec.help ?? (SliderReset.resets(title: spec.title) ? "Double-click the knob to return it to the middle." : ""))
        }
    }
}
