import CoreGraphics
import Foundation

/// Magnification of the open image. 1× is one image pixel per screen point.
/// Fit may drop the slider floor to 0.05 when the image is larger than the view.
/// Zoom changes this transform. It does not rebuild the proxy.
nonisolated enum CanvasTool: String, Equatable, Sendable {
    case hand
    case zoom
    case horizon
    case eyedropper
    case removeObject
    case select
    case dustSpot
    case scratchMark

    /// Zoom tool: a click zooms in, and Option-click zooms out.
    /// Hand: Command-click zooms in. Command-Option-click zooms out.
    /// Option is the key to the right of the right-hand Command key.
    func clickZoom(command: Bool, option: Bool) -> ClickZoom? {
        switch self {
        case .zoom:
            return option ? .zoomOut : .zoomIn
        case .hand:
            guard command else { return nil }
            return option ? .zoomOut : .zoomIn
        case .horizon, .eyedropper, .removeObject, .select, .dustSpot, .scratchMark:
            return nil
        }
    }
}

nonisolated enum ClickZoom: Equatable, Sendable {
    case zoomIn
    case zoomOut
}

nonisolated struct ZoomController: Equatable {
    var magnification: Double = 1
    var sliderMinimum: Double = standardMinimum
    var offset: CGSize = .zero

    static let standardMinimum = 0.1
    static let maximumMagnification = 4.0
    static let absoluteFloor = 0.05
    static let sqrtTwo = 2.0.squareRoot()
    static let tileUpsampleThreshold = 1.25

    var sliderMaximum: Double { Self.maximumMagnification }

    var factorLabel: String {
        String(format: "%.2f×", magnification)
    }

    /// 0 is the slider minimum and 1 is 4×, on a log scale.
    var logarithmicPosition: Double {
        let low = log(sliderMinimum)
        let high = log(Self.maximumMagnification)
        let span = high - low
        guard span > 0 else { return 0 }
        let mag = min(max(magnification, sliderMinimum), Self.maximumMagnification)
        return (log(mag) - low) / span
    }

    mutating func setLogarithmicPosition(_ position: Double) {
        let t = min(max(position, 0), 1)
        let low = log(sliderMinimum)
        let high = log(Self.maximumMagnification)
        magnification = exp(low + (high - low) * t)
    }

    mutating func resetForNewDocument() {
        sliderMinimum = Self.standardMinimum
        magnification = 1
        offset = .zero
    }

    mutating func clampToRange() {
        magnification = min(max(magnification, sliderMinimum), Self.maximumMagnification)
    }

    mutating func zoomIn(about anchor: CGPoint = .zero, viewSize: CGSize = .zero) {
        multiply(by: Self.sqrtTwo, anchor: anchor, viewSize: viewSize)
    }

    mutating func zoomOut(about anchor: CGPoint = .zero, viewSize: CGSize = .zero) {
        multiply(by: 1 / Self.sqrtTwo, anchor: anchor, viewSize: viewSize)
    }

    mutating func pinch(by factor: Double, anchor: CGPoint = .zero, viewSize: CGSize = .zero) {
        multiply(by: factor, anchor: anchor, viewSize: viewSize)
    }

    mutating func actualSize() {
        sliderMinimum = min(sliderMinimum, 1)
        magnification = 1
        offset = .zero
        clampToRange()
    }

    /// Fit-to-window. When the raw factor is below 0.1, the slider minimum drops
    /// to that factor and stops at 0.05.
    mutating func fit(imageLongEdge: Double, viewLongEdge: Double) {
        guard imageLongEdge > 0, viewLongEdge > 0 else { return }
        let raw = viewLongEdge / imageLongEdge
        if raw < Self.standardMinimum {
            sliderMinimum = max(raw, Self.absoluteFloor)
            magnification = sliderMinimum
        } else {
            sliderMinimum = Self.standardMinimum
            magnification = min(raw, Self.maximumMagnification)
        }
        offset = .zero
    }

    mutating func multiply(by factor: Double, anchor: CGPoint, viewSize: CGSize) {
        guard factor > 0, magnification > 0 else { return }
        let old = magnification
        let newMag = min(max(old * factor, sliderMinimum), Self.maximumMagnification)
        let applied = newMag / old
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let dx = anchor.x - center.x - offset.width
        let dy = anchor.y - center.y - offset.height
        offset.width += dx - dx * applied
        offset.height += dy - dy * applied
        magnification = newMag
    }
}
