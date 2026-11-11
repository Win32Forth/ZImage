import SwiftUI

/// White and skin modes. A click on the canvas samples stage 3 and commits one `setTone`.
struct InspectorEyedropper: View {
    @Bindable var model: EditorModel
    @Binding var collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorPanelHeader(title: EyedropperCopy.panel, collapsed: collapsed) { collapsed.toggle() }
            if !collapsed {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: InspectorMetrics.stackSpacing) {
                        ForEach(ToneSliderSpec.color) { spec in
                            ToneSliderControl(model: model, spec: spec)
                        }
                    }
                    HStack(spacing: 8) {
                    Picker(EyedropperCopy.panel, selection: $model.eyedropperMode) {
                        Text(EyedropperCopy.white).tag(EyedropperMode.white)
                        Text(EyedropperCopy.skin).tag(EyedropperMode.skin)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(EyedropperCopy.panel)
                    Button { model.toggleCanvasTool(.eyedropper) } label: {
                        Image(systemName: "eyedropper")
                    }
                    .buttonStyle(LibraryPushButtonStyle())
                    .toolToggleBorder(active: model.canvasTool == .eyedropper)
                    .accessibilityLabel(EyedropperCopy.tool)
                    .accessibilityIdentifier(EyedropperCopy.tool)
                    .accessibilityAddTraits(model.canvasTool == .eyedropper ? .isSelected : [])
                    .help(EyedropperCopy.toolHelp)
                    .disabled(model.showsVideo)
                    }
                    if model.eyedropperMode == .skin {
                        Picker(EyedropperCopy.presetMenu, selection: $model.skinPresetID) {
                            ForEach(SkinPresets.all) { preset in
                                Text(preset.label).tag(preset.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityLabel(EyedropperCopy.presetMenu)
                        HStack(spacing: 6) {
                            ForEach(SkinPresets.all) { preset in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(swatch(preset.sRGBHex))
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(ChromePalette.ink, lineWidth: preset.id == model.skinPresetID ? 2 : 0)
                                    )
                                    .accessibilityLabel(preset.label)
                                    .onTapGesture { model.skinPresetID = preset.id }
                            }
                        }
                    }
                    Text(EyedropperCopy.hint)
                        .font(.system(size: 12))
                        .foregroundStyle(ChromePalette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(EdgeInsets(top: InspectorMetrics.panelTopPadding, leading: 16, bottom: InspectorMetrics.panelBottomPadding, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(EyedropperCopy.panel)
    }

    private func swatch(_ hex: String) -> Color {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        return Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
