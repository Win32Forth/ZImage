import SwiftUI

/// Tone and Geometry sliders use 56% of the system control height: 30% off, then another 20%.
enum InspectorMetrics {
    static let heightFactor: CGFloat = 0.56
    /// Stack gap of 10, reduced by 30% and then another 20%.
    static let stackSpacing: CGFloat = 5.6
    /// Shared width so every field name in Tone and Geometry ends on the same line.
    static let nameColumn: CGFloat = 108
    static let readoutColumn: CGFloat = 72
    /// Top inset of Tone, Geometry, Eyedropper, and History.
    static let panelTopPadding: CGFloat = 8
    /// Bottom inset of Tone, Geometry, and Eyedropper. Half of the previous 16 points.
    static let panelBottomPadding: CGFloat = 8

    static func compressed(_ height: CGFloat) -> CGFloat {
        height * heightFactor
    }
}

/// Reports 56% of the child's height. The child scales its drawing to match.
struct InspectorControlHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let width = proposal.width ?? size.width
        return CGSize(width: max(size.width, width), height: InspectorMetrics.compressed(size.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        child.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: size.height)
        )
    }
}

/// Name, then the slider, then the readout. Names share one right edge.
struct InspectorFieldRow<Control: View>: View {
    var title: String
    var readout: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(ChromePalette.ink)
                .lineLimit(1)
                .frame(width: InspectorMetrics.nameColumn, alignment: .trailing)
            control()
            Text(readout)
                .font(.system(size: 13))
                .foregroundStyle(ChromePalette.muted)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: InspectorMetrics.readoutColumn, alignment: .trailing)
        }
    }
}

extension View {
    /// Draws this slider at 56% of its normal height and reserves only that space.
    func inspectorControlHeight() -> some View {
        InspectorControlHeight {
            scaleEffect(x: 1, y: InspectorMetrics.heightFactor, anchor: .top)
        }
        .clipped()
    }
}
