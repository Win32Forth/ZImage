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

    /// How many previews of `cell` points fit across `width`, including the grid's outer inset.
    static func columnCount(width: CGFloat, cell: CGFloat, spacing: CGFloat = 16, inset: CGFloat = 32) -> Int {
        let step = cell + spacing
        let usable = width - inset
        guard cell > 1, step > 1, width.isFinite, usable.isFinite else { return 1 }
        guard usable >= cell else { return 1 }
        return max(1, Int((usable + spacing) / step))
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
