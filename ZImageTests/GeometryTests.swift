import CoreGraphics
import CoreImage
import XCTest
@testable import ZImager

final class GeometryTests: XCTestCase {
    func testKeystoneKeepsTheCenterAndMovesTheTopCorners() {
        let center = GeometryPipeline.keystonePoint(
            NormPoint(x: 0.5, y: 0.5),
            vertical: 1,
            horizontal: -0.4
        )
        XCTAssertEqual(center.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(center.y, 0.5, accuracy: 1e-9)

        let topLeft = GeometryPipeline.keystonePoint(NormPoint(x: 0, y: 0), vertical: 1, horizontal: 0)
        let topRight = GeometryPipeline.keystonePoint(NormPoint(x: 1, y: 0), vertical: 1, horizontal: 0)
        XCTAssertEqual(topLeft.x, -1.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(topLeft.y, -1.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(topRight.x, 7.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(topRight.y, -1.0 / 6.0, accuracy: 1e-9)
    }

    func testQuarterTurnSwapsWidthAndHeight() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 40, height: 16))
        var geometry = GeometryState.identity
        geometry.quarterTurns = 1
        let turned = GeometryPipeline.apply(base: image, geometry: geometry)
        XCTAssertEqual(Int(turned.extent.width.rounded()), 16)
        XCTAssertEqual(Int(turned.extent.height.rounded()), 40)

        geometry.quarterTurns = 2
        let half = GeometryPipeline.apply(base: image, geometry: geometry)
        XCTAssertEqual(Int(half.extent.width.rounded()), 40)
        XCTAssertEqual(Int(half.extent.height.rounded()), 16)
    }

    func testHorizonUsesPixelAspect() {
        let degrees = 10.0
        let wide = horizonDelta(degrees: degrees, pixelWidth: 400, pixelHeight: 200, run: 200)
        XCTAssertEqual(wide.quarterTurns, 0)
        XCTAssertEqual(wide.straightenDegrees, degrees, accuracy: 0.05)

        let tall = horizonDelta(degrees: degrees, pixelWidth: 200, pixelHeight: 400, run: 80)
        XCTAssertEqual(tall.quarterTurns, 0)
        XCTAssertEqual(tall.straightenDegrees, degrees, accuracy: 0.05)
    }

    func testHorizonLevelsAWideFrame() {
        let width = 361
        let height = 181
        let source = lineImage(angleDegrees: 12, width: width, height: height)
        let context = TonePipeline.makeContext()
        let before = TonePipeline.rgba8(of: source, context: context)
        let ends = try! XCTUnwrap(lineEnds(before, width: width, height: height))
        let geometry = GeometryPipeline.applyingHorizon(
            from: NormPoint(x: ends.0 / Double(width), y: ends.1 / Double(height)),
            to: NormPoint(x: ends.2 / Double(width), y: ends.3 / Double(height)),
            pixelWidth: Double(width),
            pixelHeight: Double(height),
            current: .identity
        )
        let leveled = GeometryPipeline.apply(base: source, geometry: geometry)
        let after = TonePipeline.rgba8(of: leveled, context: context)
        let angle = try! XCTUnwrap(
            lineAngleDegrees(
                after,
                width: Int(leveled.extent.width.rounded()),
                height: Int(leveled.extent.height.rounded())
            )
        )
        XCTAssertEqual(angle, 0, accuracy: 0.5, "wide line remained at \(angle)°")
    }

    func testHorizonLevelsAKnownLine() {
        let source = lineImage(angleDegrees: 18, size: 181)
        let context = TonePipeline.makeContext()
        let before = TonePipeline.rgba8(of: source, context: context)
        let size = 181
        let ends = try! XCTUnwrap(lineEnds(before, width: size, height: size))
        var geometry = GeometryState.identity
        geometry = GeometryPipeline.applyingHorizon(
            from: NormPoint(x: ends.0 / Double(size), y: ends.1 / Double(size)),
            to: NormPoint(x: ends.2 / Double(size), y: ends.3 / Double(size)),
            current: geometry
        )
        let leveled = GeometryPipeline.apply(base: source, geometry: geometry)
        let after = TonePipeline.rgba8(of: leveled, context: context)
        let width = Int(leveled.extent.width.rounded())
        let height = Int(leveled.extent.height.rounded())
        let angle = try! XCTUnwrap(lineAngleDegrees(after, width: width, height: height))
        XCTAssertEqual(angle, 0, accuracy: 0.5, "line remained at \(angle)°")
    }

    func testSteepHorizonUsesOneQuarterTurnAndLevels() {
        let source = lineImage(angleDegrees: 70, size: 401)
        let context = TonePipeline.makeContext()
        let before = TonePipeline.rgba8(of: source, context: context)
        let size = 401
        let ends = try! XCTUnwrap(lineEnds(before, width: size, height: size))
        let geometry = GeometryPipeline.applyingHorizon(
            from: NormPoint(x: ends.0 / Double(size), y: ends.1 / Double(size)),
            to: NormPoint(x: ends.2 / Double(size), y: ends.3 / Double(size)),
            current: .identity
        )
        let turns = GeometryPipeline.wrap(geometry.quarterTurns)
        XCTAssertTrue(turns == 1 || turns == 3, "steep line used \(turns) quarter-turns")
        let leveled = GeometryPipeline.apply(base: source, geometry: geometry)
        let after = TonePipeline.rgba8(of: leveled, context: context)
        let angle = try! XCTUnwrap(
            lineAngleDegrees(after, width: Int(leveled.extent.width.rounded()), height: Int(leveled.extent.height.rounded()))
        )
        XCTAssertEqual(angle, 0, accuracy: 0.5, "steep line remained at \(angle)°")
    }

    func testPositiveSharpnessRaisesEdgeEnergy() {
        let checker = checkerboard(width: 32, height: 32)
        let context = TonePipeline.makeContext()
        let before = edgeEnergy(TonePipeline.rgba8(of: checker, context: context), width: 32)
        let sharp = GeometryPipeline.sharpen(checker, amount: 1, longEdge: 2560)
        let after = edgeEnergy(TonePipeline.rgba8(of: sharp, context: context), width: 32)
        XCTAssertGreaterThan(after, before)
    }

    func testSharpnessZeroMatchesTheUntransformedImage() {
        let checker = checkerboard(width: 32, height: 32)
        var geometry = GeometryState.identity
        geometry.sharpness = 1
        let applied = GeometryPipeline.apply(base: checker, geometry: geometry)
        let direct = GeometryPipeline.sharpen(checker, amount: 1, longEdge: 32)
        let context = TonePipeline.makeContext()
        XCTAssertEqual(TonePipeline.rgba8(of: applied, context: context), TonePipeline.rgba8(of: direct, context: context))
        XCTAssertEqual(
            TonePipeline.rgba8(of: GeometryPipeline.apply(base: checker, geometry: .identity), context: context),
            TonePipeline.rgba8(of: checker, context: context)
        )
    }

    func testOlderGeometryWithoutSharpnessStaysAtZero() throws {
        let data = try JSONEncoder().encode(GeometryState.identity)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sharpness")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(GeometryState.self, from: stripped)
        XCTAssertEqual(decoded.sharpness, 0)
        XCTAssertEqual(decoded, .identity)
    }

    @MainActor
    func testEachGeometryActionIsOneHistoryCommand() {
        let model = EditorModel()
        model.rotateClockwise()
        XCTAssertEqual(model.log.commands.count, 1)
        XCTAssertEqual(model.log.commands[0].historyTitle, "Rotate clockwise")
        XCTAssertEqual(model.log.state.geometry.quarterTurns, 1)

        model.rotateCounterclockwise()
        XCTAssertEqual(model.log.commands.count, 2)
        XCTAssertEqual(model.log.commands[1].historyTitle, "Rotate counterclockwise")
        XCTAssertEqual(model.log.state.geometry.quarterTurns, 0)

        model.beginGeometryDrag()
        model.nudgeGeometry("Vertical") { $0.verticalKeystone = 0.25 }
        model.nudgeGeometry("Vertical") { $0.verticalKeystone = 0.5 }
        XCTAssertEqual(model.log.commands.count, 2)
        model.endGeometryDrag()
        XCTAssertEqual(model.log.commands.count, 3)
        XCTAssertEqual(model.log.state.geometry.verticalKeystone, 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.log.commands[2].historyTitle, "Vertical")

        model.chooseLensProfile("superwide-mild")
        XCTAssertEqual(model.log.commands.count, 4)
        XCTAssertEqual(model.log.state.geometry.lens.profileID, "superwide-mild")
        XCTAssertEqual(model.log.state.geometry.lens.k1, -0.15, accuracy: 1e-9)
        XCTAssertEqual(model.log.state.geometry.lens.k2, 0.05, accuracy: 1e-9)
        XCTAssertNil(model.log.state.geometry.lens.cylindricalFOV)
        XCTAssertEqual(model.log.commands[3].historyTitle, "Super-wide adapter, mild")

        model.undo()
        XCTAssertEqual(model.log.state.geometry.lens, .identity)
        XCTAssertEqual(model.draftGeometry.lens, .identity)
        XCTAssertEqual(model.log.state.geometry.verticalKeystone, 0.5, accuracy: 1e-9)
    }

    private func checkerboard(width: Int, height: Int) -> CIImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for y in 0..<height {
            for x in 0..<width {
                let on = (x / 2 + y / 2).isMultiple(of: 2)
                context.setFillColor(on
                    ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                    : CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return CIImage(cgImage: context.makeImage()!)
    }

    private func edgeEnergy(_ bytes: [UInt8], width: Int) -> Double {
        let height = bytes.count / (width * 4)
        var energy = 0.0
        guard height > 1, width > 1 else { return 0 }
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let here = Double(bytes[(y * width + x) * 4])
                let right = Double(bytes[(y * width + x + 1) * 4])
                let below = Double(bytes[((y + 1) * width + x) * 4])
                energy += abs(here - right) + abs(here - below)
            }
        }
        return energy
    }

    private func horizonDelta(
        degrees: Double,
        pixelWidth: Double,
        pixelHeight: Double,
        run: Double
    ) -> (quarterTurns: Int, straightenDegrees: Double) {
        let dy = run * tan(degrees * .pi / 180)
        return GeometryPipeline.horizonDelta(
            from: NormPoint(x: 40 / pixelWidth, y: 40 / pixelHeight),
            to: NormPoint(x: (40 + run) / pixelWidth, y: (40 + dy) / pixelHeight),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    private func lineImage(angleDegrees: Double, size: Int) -> CIImage {
        lineImage(angleDegrees: angleDegrees, width: size, height: size)
    }

    private func lineImage(angleDegrees: Double, width: Int, height: Int) -> CIImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: CGFloat(angleDegrees * .pi / 180))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(2)
        context.setLineCap(.square)
        let reach = CGFloat(min(width, height)) * 0.42
        context.move(to: CGPoint(x: -reach, y: 0))
        context.addLine(to: CGPoint(x: reach, y: 0))
        context.strokePath()
        return CIImage(cgImage: context.makeImage()!)
    }

    /// Leftmost and rightmost bright pixels as `(x0, y0, x1, y1)` in bitmap row order.
    private func lineEnds(_ bytes: [UInt8], width: Int, height: Int) -> (Double, Double, Double, Double)? {
        var bestLeft: (Double, Double)?
        var bestRight: (Double, Double)?
        for y in 0..<height {
            for x in 0..<width where bright(bytes, width: width, x: x, y: y) {
                if bestLeft == nil || Double(x) < bestLeft!.0 {
                    bestLeft = (Double(x), Double(y))
                }
                if bestRight == nil || Double(x) > bestRight!.0 {
                    bestRight = (Double(x), Double(y))
                }
            }
        }
        guard let bestLeft, let bestRight, bestRight.0 - bestLeft.0 > 10 else { return nil }
        return (bestLeft.0, bestLeft.1, bestRight.0, bestRight.1)
    }

    private func lineAngleDegrees(_ bytes: [UInt8], width: Int, height: Int) -> Double? {
        var count = 0.0
        var mx = 0.0
        var my = 0.0
        for y in 0..<height {
            for x in 0..<width where bright(bytes, width: width, x: x, y: y) {
                count += 1
                mx += Double(x)
                my += Double(y)
            }
        }
        guard count > 30 else { return nil }
        mx /= count
        my /= count
        var cxx = 0.0
        var cyy = 0.0
        var cxy = 0.0
        for y in 0..<height {
            for x in 0..<width where bright(bytes, width: width, x: x, y: y) {
                let dx = Double(x) - mx
                let dy = Double(y) - my
                cxx += dx * dx
                cyy += dy * dy
                cxy += dx * dy
            }
        }
        var degrees = 0.5 * atan2(2 * cxy, cxx - cyy) * 180 / .pi
        while degrees > 90 { degrees -= 180 }
        while degrees <= -90 { degrees += 180 }
        return degrees
    }

    private func bright(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> Bool {
        let index = (y * width + x) * 4
        guard index + 2 < bytes.count else { return false }
        return bytes[index] > 180 && bytes[index + 1] > 180 && bytes[index + 2] > 180
    }
}
