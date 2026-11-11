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
    var id: String { title }

    static let tone: [ToneSliderSpec] = [
        ToneSliderSpec(title: "Exposure", range: -5...5, keyPath: \.exposureEV, readout: .tenth),
        ToneSliderSpec(title: "Brightness", range: -1...1, keyPath: \.brightness, readout: .hundredth),
        ToneSliderSpec(title: "Contrast", range: -1...1, keyPath: \.contrast, readout: .hundredth),
        ToneSliderSpec(title: "Highlights", range: -1...1, keyPath: \.highlights, readout: .hundredth),
        ToneSliderSpec(title: "Shadows", range: -1...1, keyPath: \.shadows, readout: .hundredth),
        ToneSliderSpec(title: "Whites", range: -1...1, keyPath: \.whites, readout: .hundredth),
        ToneSliderSpec(title: "Blacks", range: -1...1, keyPath: \.blacks, readout: .hundredth),
        ToneSliderSpec(title: "Texture", range: -1...1, keyPath: \.texture, readout: .hundredth),
        ToneSliderSpec(title: "Clarity", range: -1...1, keyPath: \.clarity, readout: .hundredth),
        ToneSliderSpec(title: "Dehaze", range: 0...1, keyPath: \.dehaze, readout: .hundredth),
        ToneSliderSpec(title: "Vibrance", range: -1...1, keyPath: \.vibrance, readout: .hundredth),
        ToneSliderSpec(title: "Saturation", range: -1...1, keyPath: \.saturation, readout: .hundredth),
    ]

    static let color: [ToneSliderSpec] = [
        ToneSliderSpec(title: "Temperature", range: 2000...50000, keyPath: \.temperature, readout: .kelvin),
        ToneSliderSpec(title: "Tint", range: -150...150, keyPath: \.tint, readout: .tint),
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
                },
                toggle: { collapsed.toggle() }
            )
            if !collapsed {
                VStack(alignment: .leading, spacing: InspectorMetrics.stackSpacing) {
                    ForEach(ToneSliderSpec.tone) { spec in
                        ToneSliderControl(model: model, spec: spec)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: InspectorMetrics.panelTopPadding, leading: 16, bottom: InspectorMetrics.panelBottomPadding, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Tone")
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
                onChange: { model.nudgeTone(spec.keyPath, to: $0, label: spec.title) },
                onEditingChanged: { editing in
                    if editing {
                        model.beginToneDrag()
                    } else {
                        model.endToneDrag()
                    }
                },
                onReset: SliderReset.resets(title: spec.title) ? {
                    model.beginToneDrag()
                    model.nudgeTone(spec.keyPath, to: SliderReset.middle(of: spec.range), label: spec.title)
                    model.endToneDrag()
                } : nil
            )
            .inspectorControlHeight()
            .accessibilityLabel(spec.title)
            .help(SliderReset.resets(title: spec.title) ? "Double-click the knob to return it to the middle." : "")
        }
    }
}
