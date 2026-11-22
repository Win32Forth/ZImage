import SwiftUI

/// Amount, Midpoint, Roundness, Feather, X, and Y. The ellipse follows the cropped frame.
struct InspectorVignette: View {
    @Bindable var model: EditorModel
    @Binding var collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorPanelHeader(title: "Vignette", collapsed: collapsed) { collapsed.toggle() }
            if !collapsed {
                VStack(alignment: .leading, spacing: InspectorMetrics.stackSpacing) {
                    ForEach(ToneSliderSpec.vignette) { spec in
                        ToneSliderControl(model: model, spec: spec)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: InspectorMetrics.panelTopPadding, leading: 16, bottom: InspectorMetrics.panelBottomPadding, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Vignette")
    }
}
