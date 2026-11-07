import CoreGraphics
import CoreImage
import Foundation

/// A rectangle in normalized image space. Origin is the top left. Y grows downward.
nonisolated struct NormRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// Crops the geometry output. Coordinates stay in that output, origin top-left, y down.
nonisolated enum CropRect {
    static func isUsable(_ rect: NormRect, pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        return rect.width * Double(pixelWidth) >= 2 && rect.height * Double(pixelHeight) >= 2
    }

    /// Keeps the rectangle inside the unit square. A reversed drag is turned upright.
    static func clamped(_ rect: NormRect) -> NormRect {
        var x = rect.x
        var y = rect.y
        var width = rect.width
        var height = rect.height
        if width < 0 {
            x += width
            width = -width
        }
        if height < 0 {
            y += height
            height = -height
        }
        let maxX = min(1, max(0, x + width))
        let maxY = min(1, max(0, y + height))
        x = min(1, max(0, x))
        y = min(1, max(0, y))
        return NormRect(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
    }

    /// A selection drawn on an already cropped image, mapped into the geometry output.
    static func composed(_ selection: NormRect, within existing: NormRect?) -> NormRect {
        let selection = clamped(selection)
        guard let existing else { return selection }
        let base = clamped(existing)
        return clamped(NormRect(
            x: base.x + selection.x * base.width,
            y: base.y + selection.y * base.height,
            width: selection.width * base.width,
            height: selection.height * base.height
        ))
    }

    /// A point on the cropped image, mapped into the geometry output.
    static func sourcePoint(_ point: NormPoint, within crop: NormRect?) -> NormPoint {
        guard let crop else { return point }
        return NormPoint(x: crop.x + point.x * crop.width, y: crop.y + point.y * crop.height)
    }

    static func apply(_ image: CIImage, crop: NormRect?) -> CIImage {
        guard let crop else { return image }
        let extent = image.extent
        guard extent.isInfinite == false, extent.width >= 1, extent.height >= 1 else { return image }
        let clamped = clamped(crop)
        guard clamped.width > 0, clamped.height > 0 else { return image }
        let width = clamped.width * extent.width
        let height = clamped.height * extent.height
        let rect = CGRect(
            x: extent.minX + clamped.x * extent.width,
            y: extent.minY + (1 - clamped.y - clamped.height) * extent.height,
            width: width,
            height: height
        ).integral
        guard rect.width >= 1, rect.height >= 1 else { return image }
        let shifted = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return shifted.cropped(to: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    }
}

enum CropHandle: Equatable, CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomRight
    case bottomLeft
    case top
    case right
    case bottom
    case left
}

enum CropDrag: Equatable, Sendable {
    case create
    case move
    case resize(CropHandle)
}

/// The rectangle drawn on the open image, in view points and in normalized pixels.
enum CropMarquee {
    static let handleHit: CGFloat = 14

    static func handlePoint(in rect: CGRect, handle: CropHandle) -> CGPoint {
        switch handle {
        case .topLeft:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .top:
            return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .right:
            return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom:
            return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .left:
            return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    static func hitHandle(at point: CGPoint, in rect: CGRect) -> CropHandle? {
        for handle in CropHandle.allCases {
            let mark = handlePoint(in: rect, handle: handle)
            if hypot(point.x - mark.x, point.y - mark.y) <= handleHit {
                return handle
            }
        }
        return nil
    }

    static func begin(at viewPoint: CGPoint, selection: NormRect?, map: ImageViewMap) -> CropDrag {
        guard let selection else { return .create }
        let rect = map.viewRect(for: selection)
        if let handle = hitHandle(at: viewPoint, in: rect) {
            return .resize(handle)
        }
        if rect.contains(viewPoint) {
            return .move
        }
        return .create
    }

    static func updated(
        drag: CropDrag,
        startSelection: NormRect?,
        startView: CGPoint,
        currentView: CGPoint,
        map: ImageViewMap
    ) -> NormRect {
        switch drag {
        case .create:
            let start = map.normPoint(from: startView)
            let current = map.normPoint(from: currentView)
            return CropRect.clamped(NormRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(start.x - current.x),
                height: abs(start.y - current.y)
            ))
        case .move:
            let start = startSelection ?? NormRect(x: 0, y: 0, width: 0, height: 0)
            let delta = map.normDelta(from: startView, to: currentView)
            return moved(start, by: delta)
        case .resize(let handle):
            let start = startSelection ?? NormRect(x: 0, y: 0, width: 0, height: 0)
            let delta = map.normDelta(from: startView, to: currentView)
            return resized(start, handle: handle, by: delta)
        }
    }

    static func moved(_ start: NormRect, by delta: NormPoint) -> NormRect {
        var next = start
        next.x += delta.x
        next.y += delta.y
        let limitX = max(0, 1 - next.width)
        let limitY = max(0, 1 - next.height)
        next.x = min(max(0, next.x), limitX)
        next.y = min(max(0, next.y), limitY)
        return next
    }

    static func resized(_ start: NormRect, handle: CropHandle, by delta: NormPoint) -> NormRect {
        var left = start.x
        var right = start.x + start.width
        var top = start.y
        var bottom = start.y + start.height
        switch handle {
        case .left, .topLeft, .bottomLeft:
            left += delta.x
        case .right, .topRight, .bottomRight:
            right += delta.x
        case .top, .bottom:
            break
        }
        switch handle {
        case .top, .topLeft, .topRight:
            top += delta.y
        case .bottom, .bottomLeft, .bottomRight:
            bottom += delta.y
        case .left, .right:
            break
        }
        return CropRect.clamped(NormRect(x: left, y: top, width: right - left, height: bottom - top))
    }
}

/// Places the open image in the canvas. The image center follows the pan offset.
struct ImageViewMap: Equatable {
    var viewSize: CGSize
    var imageSize: CGSize
    var magnification: CGFloat
    var offset: CGSize

    var center: CGPoint {
        CGPoint(x: viewSize.width / 2 + offset.width, y: viewSize.height / 2 + offset.height)
    }

    func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        let scale = magnification == 0 ? 1 : magnification
        return CGPoint(
            x: (viewPoint.x - center.x) / scale + imageSize.width / 2,
            y: (viewPoint.y - center.y) / scale + imageSize.height / 2
        )
    }

    func viewPoint(from imagePoint: CGPoint) -> CGPoint {
        let scale = magnification == 0 ? 1 : magnification
        return CGPoint(
            x: center.x + (imagePoint.x - imageSize.width / 2) * scale,
            y: center.y + (imagePoint.y - imageSize.height / 2) * scale
        )
    }

    func viewRect(for selection: NormRect) -> CGRect {
        let origin = viewPoint(from: CGPoint(
            x: selection.x * imageSize.width,
            y: selection.y * imageSize.height
        ))
        let opposite = viewPoint(from: CGPoint(
            x: (selection.x + selection.width) * imageSize.width,
            y: (selection.y + selection.height) * imageSize.height
        ))
        return CGRect(
            x: min(origin.x, opposite.x),
            y: min(origin.y, opposite.y),
            width: abs(opposite.x - origin.x),
            height: abs(opposite.y - origin.y)
        )
    }

    /// A view point clamped to the image, as a top-left normalized coordinate.
    func normPoint(from viewPoint: CGPoint) -> NormPoint {
        let point = imagePoint(from: viewPoint)
        let width = imageSize.width == 0 ? 1 : imageSize.width
        let height = imageSize.height == 0 ? 1 : imageSize.height
        let x = min(max(0, point.x), imageSize.width)
        let y = min(max(0, point.y), imageSize.height)
        return NormPoint(x: Double(x / width), y: Double(y / height))
    }

    func normDelta(from start: CGPoint, to current: CGPoint) -> NormPoint {
        let width = imageSize.width == 0 ? 1 : imageSize.width
        let height = imageSize.height == 0 ? 1 : imageSize.height
        let delta = imagePoint(from: current)
        let origin = imagePoint(from: start)
        return NormPoint(
            x: Double((delta.x - origin.x) / width),
            y: Double((delta.y - origin.y) / height)
        )
    }
}
