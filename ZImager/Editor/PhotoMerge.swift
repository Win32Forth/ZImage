import CoreGraphics
import Foundation
import ImageIO

/// Which way two photos are joined. The first photo is the left or the top.
enum PhotoMergeAxis: String, CaseIterable, Identifiable, Sendable {
    case horizontal
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        }
    }
}

enum PhotoMergeFailure: Error, Sendable {
    case unreadable
    case samePhoto
    case cannotWrite

    var message: String {
        switch self {
        case .unreadable: return "The photos could not be read."
        case .samePhoto: return "Select two different photos."
        case .cannotWrite: return "The merged TIFF could not be saved."
        }
    }
}

/// Joins two photos into one TIFF. The second photo is scaled to the shared edge.
/// Preview places it with a right and down offset, in screen pixels. The unplaced
/// join still blends a repeated overlap, and otherwise meets the photos and slides
/// the second one along the seam when that lines the two edges up.
nonisolated enum PhotoMerge {
    /// `{first}-{second}.tiff`, then `{first}-{second}-2.tiff` when that name is taken.
    static func fileName(first: String, second: String, taken: (String) -> Bool) -> String {
        var firstStem = (first as NSString).deletingPathExtension
        var secondStem = (second as NSString).deletingPathExtension
        if firstStem.isEmpty { firstStem = "Photo" }
        if secondStem.isEmpty { secondStem = "Photo" }
        if firstStem.count + secondStem.count > 200 {
            firstStem = String(firstStem.prefix(100))
            secondStem = String(secondStem.prefix(100))
        }
        let base = "\(firstStem)-\(secondStem)"
        for number in 1..<1000 {
            let name = number == 1 ? "\(base).tiff" : "\(base)-\(number).tiff"
            if !taken(name) { return name }
        }
        return "\(base)-1000.tiff"
    }

    /// Reads both photos in the orientation the folder shows and writes the TIFF.
    /// A placement uses those screen offsets. Without one, the join is chosen automatically.
    static func perform(
        first: URL,
        second: URL,
        axis: PhotoMergeAxis,
        directory: URL,
        placement: (right: Int, down: Int)? = nil
    ) -> Result<String, PhotoMergeFailure> {
        let firstAccess = first.startAccessingSecurityScopedResource()
        let secondAccess = second.startAccessingSecurityScopedResource()
        let directoryAccess = directory.startAccessingSecurityScopedResource()
        defer {
            if firstAccess { first.stopAccessingSecurityScopedResource() }
            if secondAccess { second.stopAccessingSecurityScopedResource() }
            if directoryAccess { directory.stopAccessingSecurityScopedResource() }
        }
        let firstPath = first.standardizedFileURL.resolvingSymlinksInPath()
        let secondPath = second.standardizedFileURL.resolvingSymlinksInPath()
        guard firstPath != secondPath else { return .failure(.samePhoto) }
        guard let firstImage = image(at: first), let secondImage = image(at: second) else {
            return .failure(.unreadable)
        }
        let joined: CGImage?
        if let placement {
            joined = render(
                first: firstImage,
                second: secondImage,
                axis: axis,
                right: placement.right,
                down: placement.down
            )
        } else {
            joined = render(first: firstImage, second: secondImage, axis: axis)
        }
        guard let joined else { return .failure(.cannotWrite) }
        let name = fileName(first: first.lastPathComponent, second: second.lastPathComponent) { candidate in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
        let url = directory.appendingPathComponent(name)
        var request = ExportRequest.standard(.tiff)
        request.bitDepth = 8
        do {
            try StillExporter.write(joined, request: request, to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return .failure(.cannotWrite)
        }
        return .success(name)
    }

    /// Where the two photos sit. Y grows downward, matching the screen.
    struct Frame: Sendable {
        var canvasWidth: Int
        var canvasHeight: Int
        var firstX: Int
        var firstTop: Int
        var firstWidth: Int
        var firstHeight: Int
        var secondX: Int
        var secondTop: Int
        var secondWidth: Int
        var secondHeight: Int

        /// Middle of the shared rectangle, or of the gap when the photos do not meet.
        var focusX: Int {
            let left = max(firstX, secondX)
            let right = min(firstX + firstWidth, secondX + secondWidth)
            return (left + right) / 2
        }

        var focusY: Int {
            let top = max(firstTop, secondTop)
            let bottom = min(firstTop + firstHeight, secondTop + secondHeight)
            return (top + bottom) / 2
        }
    }

    /// The first image keeps its pixel size. The second is scaled to the shared edge, then placed
    /// by the automatic seam.
    static func render(first: CGImage, second: CGImage, axis: PhotoMergeAxis) -> CGImage? {
        guard first.width > 0, first.height > 0, second.width > 0, second.height > 0 else { return nil }
        let fit = fitted(first: first, second: second, axis: axis)
        let found = alignment(first: first, second: second, axis: axis, fit: fit)
        let right: Int
        let down: Int
        switch axis {
        case .horizontal:
            right = -found.overlap
            down = found.shift
        case .vertical:
            right = found.shift
            down = -found.overlap
        }
        return paint(first: first, second: second, axis: axis, fit: fit, right: right, down: down)
    }

    /// Places the second photo from a flush join. Positive right and down move it that way on screen.
    /// A negative right overlaps a horizontal join. A negative down overlaps a vertical join.
    static func render(
        first: CGImage,
        second: CGImage,
        axis: PhotoMergeAxis,
        right: Int,
        down: Int
    ) -> CGImage? {
        guard let fit = sized(first: first, second: second, axis: axis) else { return nil }
        let placed = limit(
            right: right,
            down: down,
            axis: axis,
            firstWidth: first.width,
            firstHeight: first.height,
            secondWidth: fit.secondWidth,
            secondHeight: fit.secondHeight
        )
        return paint(first: first, second: second, axis: axis, fit: fit, right: placed.right, down: placed.down)
    }

    /// The rectangle the preview is showing for these offsets.
    static func frame(
        first: CGImage,
        second: CGImage,
        axis: PhotoMergeAxis,
        right: Int,
        down: Int
    ) -> Frame? {
        guard let fit = sized(first: first, second: second, axis: axis) else { return nil }
        let placed = limit(
            right: right,
            down: down,
            axis: axis,
            firstWidth: first.width,
            firstHeight: first.height,
            secondWidth: fit.secondWidth,
            secondHeight: fit.secondHeight
        )
        return arranged(fit: fit, firstWidth: first.width, firstHeight: first.height, axis: axis, right: placed.right, down: placed.down)
    }

    /// Stops a held arrow at about one photo of overlap, gap, or slide.
    static func limit(
        right: Int,
        down: Int,
        axis: PhotoMergeAxis,
        firstWidth: Int,
        firstHeight: Int,
        secondWidth: Int,
        secondHeight: Int
    ) -> (right: Int, down: Int) {
        switch axis {
        case .horizontal:
            let overlap = max(0, min(firstWidth, secondWidth) - 1)
            let gap = max(firstWidth, secondWidth)
            let cross = max(0, max(firstHeight, secondHeight) - 1)
            return (min(max(right, -overlap), gap), min(max(down, -cross), cross))
        case .vertical:
            let overlap = max(0, min(firstHeight, secondHeight) - 1)
            let gap = max(firstHeight, secondHeight)
            let cross = max(0, max(firstWidth, secondWidth) - 1)
            return (min(max(right, -cross), cross), min(max(down, -overlap), gap))
        }
    }

    private static func sized(first: CGImage, second: CGImage, axis: PhotoMergeAxis) -> Fit? {
        guard first.width > 0, first.height > 0, second.width > 0, second.height > 0 else { return nil }
        return fitted(first: first, second: second, axis: axis)
    }

    private struct Fit {
        var secondWidth: Int
        var secondHeight: Int
    }

    /// Scales the second photo so a horizontal join shares a height, or a vertical join shares a width.
    private static func fitted(first: CGImage, second: CGImage, axis: PhotoMergeAxis) -> Fit {
        switch axis {
        case .horizontal:
            guard second.height != first.height else {
                return Fit(secondWidth: second.width, secondHeight: second.height)
            }
            let width = max(1, Int((Double(second.width) * Double(first.height) / Double(second.height)).rounded()))
            return Fit(secondWidth: width, secondHeight: first.height)
        case .vertical:
            guard second.width != first.width else {
                return Fit(secondWidth: second.width, secondHeight: second.height)
            }
            let height = max(1, Int((Double(second.height) * Double(first.width) / Double(second.width)).rounded()))
            return Fit(secondWidth: first.width, secondHeight: height)
        }
    }

    private static func alignment(
        first: CGImage,
        second: CGImage,
        axis: PhotoMergeAxis,
        fit: Fit
    ) -> (overlap: Int, shift: Int) {
        let limit = 480
        let down = min(1, Double(limit) / Double(max(first.width, first.height, 1)))
        let primaryWidth = max(1, Int((Double(first.width) * down).rounded()))
        let primaryHeight = max(1, Int((Double(first.height) * down).rounded()))
        let secondaryWidth: Int
        let secondaryHeight: Int
        switch axis {
        case .horizontal:
            secondaryHeight = primaryHeight
            secondaryWidth = max(1, Int((Double(fit.secondWidth) * Double(primaryHeight) / Double(first.height)).rounded()))
        case .vertical:
            secondaryWidth = primaryWidth
            secondaryHeight = max(1, Int((Double(fit.secondHeight) * Double(primaryWidth) / Double(first.width)).rounded()))
        }
        guard let primary = luma(first, width: primaryWidth, height: primaryHeight),
              let secondary = luma(second, width: secondaryWidth, height: secondaryHeight) else {
            return (0, 0)
        }
        let alongPrimary = axis == .horizontal ? primaryWidth : primaryHeight
        let alongSecondary = axis == .horizontal ? secondaryWidth : secondaryHeight
        let cross = axis == .horizontal ? primaryHeight : primaryWidth
        let found = search(primary: primary, secondary: secondary, axis: axis)
        guard found.overlap > 0 || found.shift != 0 else { return (0, 0) }
        let fullAlong = axis == .horizontal ? first.width : first.height
        let fullCross = axis == .horizontal ? first.height : first.width
        var overlap = Int((Double(found.overlap) / Double(alongPrimary) * Double(fullAlong)).rounded())
        var shift = Int((Double(found.shift) / Double(max(cross, 1)) * Double(fullCross)).rounded())
        let fittedAlong = axis == .horizontal ? fit.secondWidth : fit.secondHeight
        let cap = max(0, min(fullAlong, fittedAlong) - 1)
        overlap = min(max(0, overlap), cap)
        let shiftCap = fullCross / 5
        shift = min(max(shift, -shiftCap), shiftCap)
        return (overlap, shift)
    }

    /// Mean absolute difference along the join. A flat match is a flush join, because two
    /// copies of the same tone would otherwise swallow the overlap. A real repeat is much
    /// closer than a wrong placement, and it is no worse than simply touching the edges.
    private static func search(primary: Luma, secondary: Luma, axis: PhotoMergeAxis) -> (overlap: Int, shift: Int) {
        let alongPrimary = axis == .horizontal ? primary.width : primary.height
        let alongSecondary = axis == .horizontal ? secondary.width : secondary.height
        let cross = axis == .horizontal ? primary.height : primary.width
        let minAlong = min(alongPrimary, alongSecondary)
        guard minAlong >= 2, cross >= 1 else { return (0, 0) }
        let overlapStep = max(1, minAlong / 48)
        let shiftStep = max(1, cross / 40)
        let maxOverlap = minAlong * 60 / 100
        let maxShift = cross * 20 / 100
        let minOverlap = max(2, minAlong * 4 / 100)
        let seam = max(2, minAlong / 25)
        guard let flush = difference(
            primary: primary,
            secondary: secondary,
            axis: axis,
            strip: seam,
            shift: 0
        ) else { return (0, 0) }

        var best: (score: Float, overlap: Int, shift: Int)?
        func consider(overlap: Int, shift: Int) {
            guard overlap >= minOverlap, overlap <= maxOverlap else { return }
            guard let score = difference(
                primary: primary,
                secondary: secondary,
                axis: axis,
                strip: overlap,
                shift: shift
            ) else { return }
            guard let winner = best else {
                best = (score, overlap, shift)
                return
            }
            let closer = abs(shift) < abs(winner.shift)
            if score < winner.score - 0.05
                || (abs(score - winner.score) <= 0.05 && overlap > winner.overlap)
                || (abs(score - winner.score) <= 0.05 && overlap == winner.overlap && closer) {
                best = (score, overlap, shift)
            }
        }
        if maxOverlap >= minOverlap {
            var overlap = minOverlap
            while overlap <= maxOverlap {
                var shift = -maxShift
                while shift <= maxShift {
                    consider(overlap: overlap, shift: shift)
                    shift += shiftStep
                }
                overlap += overlapStep
            }
        }
        if let found = best {
            let overlap0 = max(minOverlap, found.overlap - overlapStep)
            let overlap1 = min(maxOverlap, found.overlap + overlapStep)
            let shift0 = max(-maxShift, found.shift - shiftStep)
            let shift1 = min(maxShift, found.shift + shiftStep)
            if overlap0 <= overlap1 {
                for overlap in overlap0...overlap1 {
                    for shift in shift0...shift1 {
                        consider(overlap: overlap, shift: shift)
                    }
                }
            }
        }

        let slid = seamShift(
            primary: primary,
            secondary: secondary,
            axis: axis,
            strip: seam,
            maxShift: maxShift,
            shiftStep: shiftStep,
            flush: flush
        )
        guard let found = best else { return slid }
        let contrast = mismatch(
            primary: primary,
            secondary: secondary,
            axis: axis,
            bestOverlap: found.overlap,
            bestShift: found.shift,
            bestScore: found.score,
            minAlong: minAlong,
            maxOverlap: maxOverlap,
            overlapStep: overlapStep
        )
        // The flush score is the seam at zero shift. A repeated region has to beat that
        // seam, not merely a mismatched part of the photo. Two copies of one picture
        // then stay side by side, and so do scans that only share a similar edge.
        let overlapWins = found.score + 2 < contrast
            && found.score < contrast * 0.5
            && found.score < flush * 0.82
        if overlapWins {
            return (found.overlap, found.shift)
        }
        return slid
    }

    /// Slides the second photo along a flush seam. A tie stays at zero.
    private static func seamShift(
        primary: Luma,
        secondary: Luma,
        axis: PhotoMergeAxis,
        strip: Int,
        maxShift: Int,
        shiftStep: Int,
        flush: Float
    ) -> (overlap: Int, shift: Int) {
        guard maxShift > 0, shiftStep > 0 else { return (0, 0) }
        var bestScore = flush
        var bestShift = 0
        func consider(shift: Int) {
            guard let score = difference(
                primary: primary,
                secondary: secondary,
                axis: axis,
                strip: strip,
                shift: shift
            ) else { return }
            let closer = abs(shift) < abs(bestShift)
            if score + 1.5 < bestScore || (abs(score - bestScore) <= 1.5 && closer && score <= bestScore + 0.05) {
                bestScore = score
                bestShift = shift
            }
        }
        var shift = -maxShift
        while shift <= maxShift {
            consider(shift: shift)
            shift += shiftStep
        }
        let shift0 = max(-maxShift, bestShift - shiftStep)
        let shift1 = min(maxShift, bestShift + shiftStep)
        if shift0 <= shift1 {
            for shift in shift0...shift1 {
                consider(shift: shift)
            }
        }
        guard bestShift != 0, bestScore + 2 < flush, bestScore < flush * 0.82 else { return (0, 0) }
        return (0, bestShift)
    }

    /// How badly a placement that is not the candidate matches. A real overlap beats this.
    private static func mismatch(
        primary: Luma,
        secondary: Luma,
        axis: PhotoMergeAxis,
        bestOverlap: Int,
        bestShift: Int,
        bestScore: Float,
        minAlong: Int,
        maxOverlap: Int,
        overlapStep: Int
    ) -> Float {
        var contrast = bestScore
        let farther = min(maxOverlap, bestOverlap + max(overlapStep * 3, minAlong / 10))
        if farther >= bestOverlap + max(2, overlapStep),
           let score = difference(
               primary: primary,
               secondary: secondary,
               axis: axis,
               strip: farther,
               shift: bestShift
           ), score > contrast {
            contrast = score
        }
        if let score = difference(
            primary: primary,
            secondary: secondary,
            axis: axis,
            strip: bestOverlap,
            shift: bestShift,
            fromEnd: false
        ), score > contrast {
            contrast = score
        }
        return contrast
    }

    private static func difference(
        primary: Luma,
        secondary: Luma,
        axis: PhotoMergeAxis,
        strip: Int,
        shift: Int,
        fromEnd: Bool = true
    ) -> Float? {
        let alongPrimary = axis == .horizontal ? primary.width : primary.height
        let alongSecondary = axis == .horizontal ? secondary.width : secondary.height
        let cross = axis == .horizontal ? primary.height : primary.width
        guard strip > 0, strip <= alongPrimary, strip <= alongSecondary, cross > 0 else { return nil }
        var sum: Float = 0
        var count = 0
        for position in 0..<cross {
            let other = position - shift
            if other < 0 || other >= cross { continue }
            for step in 0..<strip {
                let along = fromEnd ? alongPrimary - strip + step : step
                let left = sample(primary, axis: axis, along: along, cross: position)
                let right = sample(secondary, axis: axis, along: step, cross: other)
                sum += abs(left - right)
                count += 1
            }
        }
        guard count >= strip * cross / 2 else { return nil }
        return sum / Float(count)
    }

    private static func sample(_ field: Luma, axis: PhotoMergeAxis, along: Int, cross: Int) -> Float {
        switch axis {
        case .horizontal:
            return field.samples[cross * field.width + along]
        case .vertical:
            return field.samples[along * field.width + cross]
        }
    }

    /// Second photo's top-left is measured from the first photo's top-left. The canvas origin
    /// moves when the second photo sticks out above or to the left.
    private static func arranged(
        fit: Fit,
        firstWidth: Int,
        firstHeight: Int,
        axis: PhotoMergeAxis,
        right: Int,
        down: Int
    ) -> Frame {
        let relX: Int
        let relY: Int
        switch axis {
        case .horizontal:
            relX = firstWidth + right
            relY = down
        case .vertical:
            relX = right
            relY = firstHeight + down
        }
        let originX = min(0, relX)
        let originY = min(0, relY)
        let firstX = -originX
        let firstTop = -originY
        let secondX = relX - originX
        let secondTop = relY - originY
        return Frame(
            canvasWidth: max(firstX + firstWidth, secondX + fit.secondWidth),
            canvasHeight: max(firstTop + firstHeight, secondTop + fit.secondHeight),
            firstX: firstX,
            firstTop: firstTop,
            firstWidth: firstWidth,
            firstHeight: firstHeight,
            secondX: secondX,
            secondTop: secondTop,
            secondWidth: fit.secondWidth,
            secondHeight: fit.secondHeight
        )
    }

    private static func paint(
        first: CGImage,
        second: CGImage,
        axis: PhotoMergeAxis,
        fit: Fit,
        right: Int,
        down: Int
    ) -> CGImage? {
        let frame = arranged(
            fit: fit,
            firstWidth: first.width,
            firstHeight: first.height,
            axis: axis,
            right: right,
            down: down
        )
        let canvasW = frame.canvasWidth
        let canvasH = frame.canvasHeight
        guard canvasW > 0, canvasH > 0,
              let ctx = CGContext(
                data: nil,
                width: canvasW,
                height: canvasH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        func draw(_ image: CGImage, x: Int, top: Int, width: Int, height: Int) {
            let y = canvasH - top - height
            ctx.draw(image, in: CGRect(x: x, y: y, width: width, height: height))
        }
        draw(first, x: frame.firstX, top: frame.firstTop, width: frame.firstWidth, height: frame.firstHeight)
        guard let before = ctx.makeImage() else { return nil }
        let sharedLeft = max(frame.firstX, frame.secondX)
        let sharedTop = max(frame.firstTop, frame.secondTop)
        let sharedWidth = min(frame.firstX + frame.firstWidth, frame.secondX + frame.secondWidth) - sharedLeft
        let sharedHeight = min(frame.firstTop + frame.firstHeight, frame.secondTop + frame.secondHeight) - sharedTop
        let shared = CGRect(x: sharedLeft, y: sharedTop, width: sharedWidth, height: sharedHeight)
        // Copy the first photo's overlap before the second draw replaces those pixels.
        let firstOverlap: CGImage?
        if sharedWidth >= 1, sharedHeight >= 1, let cropped = before.cropping(to: shared) {
            firstOverlap = detachedCopy(cropped)
        } else {
            firstOverlap = nil
        }
        draw(second, x: frame.secondX, top: frame.secondTop, width: frame.secondWidth, height: frame.secondHeight)
        guard var after = ctx.makeImage() else { return nil }
        if let firstOverlap,
           let secondCrop = after.cropping(to: shared),
           let secondOverlap = detachedCopy(secondCrop),
           let blended = feather(firstStrip: firstOverlap, secondStrip: secondOverlap, axis: axis) {
            let y = CGFloat(canvasH - sharedTop - blended.height)
            ctx.draw(
                blended,
                in: CGRect(x: CGFloat(sharedLeft), y: y, width: CGFloat(blended.width), height: CGFloat(blended.height))
            )
            if let replaced = ctx.makeImage() {
                after = replaced
            }
        }
        let gap = axis == .horizontal ? max(0, right) : max(0, down)
        let slide = axis == .horizontal ? down : right
        // A gap along the join stays black. A slide fills only the clear band beside the photos.
        if (gap > 0 || slide != 0), let extended = extendClearEdges(after, axis: axis, reach: abs(slide) + 2) {
            return extended
        }
        return after
    }

    /// The second photo fades in across the overlap, from the first photo's side.
    private static func feather(firstStrip: CGImage, secondStrip: CGImage, axis: PhotoMergeAxis) -> CGImage? {
        guard let firstPixels = pixels(firstStrip),
              let secondPixels = pixels(secondStrip),
              firstPixels.width == secondPixels.width,
              firstPixels.height == secondPixels.height,
              firstPixels.width > 0,
              firstPixels.height > 0 else { return nil }
        var bytes = secondPixels.bytes
        let width = firstPixels.width
        let height = firstPixels.height
        for y in 0..<height {
            for x in 0..<width {
                let t: Float
                if axis == .horizontal {
                    t = width == 1 ? 1 : Float(x) / Float(width - 1)
                } else {
                    t = height == 1 ? 1 : Float(y) / Float(height - 1)
                }
                let index = (y * width + x) * 4
                for channel in 0..<3 {
                    let start = Float(firstPixels.bytes[index + channel])
                    let end = Float(secondPixels.bytes[index + channel])
                    bytes[index + channel] = UInt8((start * (1 - t) + end * t).rounded())
                }
                bytes[index + 3] = 255
            }
        }
        return image(width: width, height: height, bytes: bytes)
    }

    /// Fills the clear band left by a shift with the nearest photo pixel.
    private static func extendClearEdges(_ image: CGImage, axis: PhotoMergeAxis, reach: Int) -> CGImage? {
        guard var field = pixels(image) else { return nil }
        let width = field.width
        let height = field.height
        let source = field.bytes
        func opaque(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return source[(y * width + x) * 4 + 3] > 16
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                guard source[index + 3] <= 16 else { continue }
                var filled = false
                if reach > 0 {
                    for distance in 1...reach {
                        let candidates: [(Int, Int)]
                        if axis == .horizontal {
                            candidates = [(x, y - distance), (x, y + distance)]
                        } else {
                            candidates = [(x - distance, y), (x + distance, y)]
                        }
                        for (nx, ny) in candidates where opaque(nx, ny) {
                            let from = (ny * width + nx) * 4
                            field.bytes[index] = source[from]
                            field.bytes[index + 1] = source[from + 1]
                            field.bytes[index + 2] = source[from + 2]
                            field.bytes[index + 3] = 255
                            filled = true
                            break
                        }
                        if filled { break }
                    }
                }
                if !filled {
                    field.bytes[index] = 0
                    field.bytes[index + 1] = 0
                    field.bytes[index + 2] = 0
                    field.bytes[index + 3] = 255
                }
            }
        }
        return Self.image(width: width, height: height, bytes: field.bytes)
    }

    private struct Luma {
        var width: Int
        var height: Int
        var samples: [Float]
    }

    private struct RGBA {
        var width: Int
        var height: Int
        var bytes: [UInt8]
    }

    private static func detachedCopy(_ image: CGImage) -> CGImage? {
        guard let field = pixels(image) else { return nil }
        return Self.image(width: field.width, height: field.height, bytes: field.bytes)
    }

    /// Row 0 is the top of the photo. Drawing upright into a bitmap context stores that row first.
    private static func pixels(_ image: CGImage) -> RGBA? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBA(width: width, height: height, bytes: bytes)
    }

    private static func luma(_ image: CGImage, width: Int, height: Int) -> Luma? {
        guard let field = pixels(drawing: image, width: width, height: height) else { return nil }
        var samples = [Float](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            let red = Float(field[offset])
            let green = Float(field[offset + 1])
            let blue = Float(field[offset + 2])
            samples[index] = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
        return Luma(width: width, height: height, samples: samples)
    }

    private static func pixels(drawing image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private static func image(width: Int, height: Int, bytes: [UInt8]) -> CGImage? {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// The folder thumbnail orientation, at the photo's own pixel size.
    static func loadImage(at url: URL) -> CGImage? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return image(at: url)
    }

    private static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = int(properties?[kCGImagePropertyPixelWidth])
        let height = int(properties?[kCGImagePropertyPixelHeight])
        let edge = max(width, height, 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }
}
