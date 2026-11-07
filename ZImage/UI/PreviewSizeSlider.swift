import SwiftUI

/// Cell long edge for a grid. The editor folder JPEG stays at most 250 px.
/// This is not the editor zoom.
nonisolated enum PreviewSize {
    static let label = "Preview size"
    static let minimumPoints = 80.0
    static let maximumPoints = 480.0
    static let defaultPoints = 160.0

    static func clamped(_ points: Double) -> Double {
        min(max(points, minimumPoints), maximumPoints)
    }
}

struct PreviewSizeSlider: View {
    @Binding var points: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(PreviewSize.label)
                .font(.system(size: 13))
            Slider(value: $points, in: PreviewSize.minimumPoints...PreviewSize.maximumPoints)
                .accessibilityLabel(PreviewSize.label)
            Text("\(Int(points.rounded())) pt")
                .font(.system(size: 12))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(PreviewSize.label)
    }
}
