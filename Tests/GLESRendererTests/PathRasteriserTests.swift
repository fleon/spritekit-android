import XCTest
@testable import GLESRenderer
@testable import SpriteKitShim

#if canImport(Darwin)
import CoreGraphics
#endif

/// The rasteriser's own tests, run on the host.
///
/// `CGPath` here is the real CoreGraphics one and the paths are built with
/// its own API, which is the point: what the rasteriser sees on the Mac is
/// what the game's `UIBezierPath` helpers hand it on a device, read back
/// through `pathElements`.
final class PathRasteriserTests: XCTestCase {

    // MARK: Filling

    func testFillsASquareSolidly() throws {
        let path = rectanglePath(CGRect(x: 0, y: 0, width: 10, height: 10))
        let mask = try XCTUnwrap(PathRasteriser.fill(path, scale: 1))

        // A pixel of margin all round, so the 10x10 square is 12x12.
        XCTAssertEqual(mask.width, 12)
        XCTAssertEqual(mask.height, 12)
        XCTAssertEqual(coverage(mask, 6, 6), 255)
        XCTAssertEqual(coverage(mask, 1, 1), 255)
        XCTAssertEqual(coverage(mask, 0, 0), 0, "the margin stays empty")
        XCTAssertEqual(coverage(mask, 11, 11), 0)
    }

    func testMaskBoundsAreThePathsOwnSpace() throws {
        let path = rectanglePath(CGRect(x: 40, y: -10, width: 20, height: 6))
        let mask = try XCTUnwrap(PathRasteriser.fill(path, scale: 2))

        // One device pixel of margin at scale 2 is half a point.
        XCTAssertEqual(mask.bounds.minX, 39.5, accuracy: 0.001)
        XCTAssertEqual(mask.bounds.minY, -10.5, accuracy: 0.001)
        XCTAssertEqual(mask.bounds.width, 21, accuracy: 0.001)
        XCTAssertEqual(mask.bounds.height, 7, accuracy: 0.001)
        XCTAssertEqual(mask.width, 42)
        XCTAssertEqual(mask.height, 14)
    }

    func testEvenOddLeavesAHoleWhereNonZeroDoesNot() throws {
        // Two squares wound the same way: non-zero counts 2 and fills,
        // even-odd counts 2 and does not.
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: 20, height: 20))
        path.addRect(CGRect(x: 5, y: 5, width: 10, height: 10))

        let nonZero = try XCTUnwrap(PathRasteriser.fill(path, rule: .nonZero, scale: 1))
        let evenOdd = try XCTUnwrap(PathRasteriser.fill(path, rule: .evenOdd, scale: 1))

        XCTAssertEqual(coverage(nonZero, 11, 11), 255, "the middle is inside both squares")
        XCTAssertEqual(coverage(evenOdd, 11, 11), 0, "and so even-odd punches it out")
        XCTAssertEqual(coverage(evenOdd, 3, 11), 255, "the ring stays filled either way")
        XCTAssertEqual(coverage(nonZero, 3, 11), 255)
    }

    func testACirclesAreaIsRight() throws {
        let radius: CGFloat = 30
        let path = CGPath(
            ellipseIn: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2),
            transform: nil
        )
        let mask = try XCTUnwrap(PathRasteriser.fill(path, scale: 1))

        XCTAssertEqual(area(mask), Double.pi * Double(radius * radius), accuracy: 30,
                       "coverage is area, so a disc should weigh pi r squared")
    }

    func testEdgesAreAntialiased() throws {
        let path = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: 40, height: 20),
            cornerWidth: 8, cornerHeight: 8, transform: nil
        )
        let mask = try XCTUnwrap(PathRasteriser.fill(path, scale: 1))
        let partial = mask.pixels.filter { $0 > 0 && $0 < 255 }
        XCTAssertGreaterThan(partial.count, 20, "a rounded corner should have soft pixels")
    }

    func testScaleRastersMorePixelsNotABiggerShape() throws {
        let path = rectanglePath(CGRect(x: 0, y: 0, width: 10, height: 10))
        let one = try XCTUnwrap(PathRasteriser.fill(path, scale: 1))
        let three = try XCTUnwrap(PathRasteriser.fill(path, scale: 3))

        XCTAssertEqual(three.width, 32)             // 10 points + 2/3 of a point, at 3x
        XCTAssertEqual(one.bounds.width, 12)
        XCTAssertEqual(three.bounds.width, 10 + 2.0 / 3, accuracy: 0.001)
    }

    func testAnEmptyPathRasterisesToNothing() {
        XCTAssertNil(PathRasteriser.fill(CGMutablePath(), scale: 1))
        let line = CGMutablePath()
        line.move(to: .zero)
        line.addLine(to: CGPoint(x: 10, y: 0))
        XCTAssertNil(PathRasteriser.fill(line, scale: 1), "a line encloses nothing")
    }

    // MARK: Stroking

    func testStrokesALineToABand() throws {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 10))
        path.addLine(to: CGPoint(x: 20, y: 10))
        let mask = try XCTUnwrap(PathRasteriser.stroke(path, width: 4, scale: 1))

        // 4 points tall plus a pixel of margin either side.
        XCTAssertEqual(mask.height, 6)
        XCTAssertEqual(mask.width, 22)
        XCTAssertEqual(coverage(mask, 10, 3), 255)
        XCTAssertEqual(coverage(mask, 10, 0), 0)
        XCTAssertEqual(coverage(mask, 10, 5), 0)
    }

    func testCapsReachPastTheEndOrDoNot() throws {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 10, y: 10))
        path.addLine(to: CGPoint(x: 30, y: 10))

        let butt = try XCTUnwrap(PathRasteriser.stroke(path, width: 6, cap: .butt, scale: 1))
        let round = try XCTUnwrap(PathRasteriser.stroke(path, width: 6, cap: .round, scale: 1))
        let square = try XCTUnwrap(PathRasteriser.stroke(path, width: 6, cap: .square, scale: 1))

        XCTAssertEqual(butt.bounds.width, 22, accuracy: 0.001, "20 long plus the margin")
        XCTAssertEqual(round.bounds.width, 28, accuracy: 0.001, "plus half a width at each end")
        XCTAssertEqual(square.bounds.width, 28, accuracy: 0.001)

        // A round cap is a half disc, so its corner is empty; a square one
        // fills it.
        XCTAssertLessThan(coverage(round, 1, 1), 128)
        XCTAssertEqual(coverage(square, 1, 1), 255)
        XCTAssertEqual(round.height, 8)
    }

    func testAMiterJoinReachesFurtherThanABevel() throws {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 20, y: 0))
        path.addLine(to: CGPoint(x: 20, y: 20))

        let miter = try XCTUnwrap(PathRasteriser.stroke(path, width: 8, join: .miter, scale: 1))
        let bevel = try XCTUnwrap(PathRasteriser.stroke(path, width: 8, join: .bevel, scale: 1))
        let round = try XCTUnwrap(PathRasteriser.stroke(path, width: 8, join: .round, scale: 1))

        // The outside of the corner is at (24, -4), a pixel of margin below.
        XCTAssertEqual(miter.bounds.minY, -5, accuracy: 0.001)
        XCTAssertEqual(miter.bounds.maxX, 25, accuracy: 0.001)
        XCTAssertEqual(bevel.bounds.maxX, 25, accuracy: 0.001)

        XCTAssertGreaterThan(area(miter), area(bevel), "a mitre fills the corner a bevel cuts off")
        XCTAssertGreaterThan(area(round), area(bevel))
        XCTAssertGreaterThan(area(miter), area(round))
    }

    func testASharpMiterFallsBackToABevel() throws {
        // A narrow spike: the mitre would reach many half-widths out, past
        // the limit, so it has to be cut off.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 100, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 17.6))

        let limited = try XCTUnwrap(
            PathRasteriser.stroke(path, width: 6, join: .miter, miterLimit: 4, scale: 1)
        )
        let unlimited = try XCTUnwrap(
            PathRasteriser.stroke(path, width: 6, join: .miter, miterLimit: 100, scale: 1)
        )
        XCTAssertLessThan(limited.bounds.maxX, unlimited.bounds.maxX)
        XCTAssertLessThan(limited.bounds.maxX, 110)
        XCTAssertGreaterThan(unlimited.bounds.maxX, 120)
    }

    func testAClosedStrokeHasNoCaps() throws {
        let square = rectanglePath(CGRect(x: 0, y: 0, width: 20, height: 20))
        let mask = try XCTUnwrap(
            PathRasteriser.stroke(square, width: 4, cap: .round, join: .miter, scale: 1)
        )
        // Mitred corners, so the outline is exactly 2 points proud all round.
        XCTAssertEqual(mask.bounds.minX, -3, accuracy: 0.001)
        XCTAssertEqual(mask.bounds.maxX, 23, accuracy: 0.001)
        XCTAssertEqual(coverage(mask, 13, 13), 0, "the middle of a stroked square is empty")
        XCTAssertEqual(coverage(mask, 13, 4), 255, "its top edge is not")
    }

    func testOverlappingStrokePartsUnionRatherThanCancel() throws {
        // A hairpin: the two segments all but coincide. Non-zero filling has
        // to leave it solid, which it only does if every piece of the
        // outline is wound the same way.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 20, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 0.5))
        let mask = try XCTUnwrap(PathRasteriser.stroke(path, width: 6, join: .round, scale: 1))
        XCTAssertEqual(coverage(mask, 10, mask.height / 2), 255)
    }

    func testAStrokedDotIsADotOnlyWithARoundOrSquareCap() throws {
        let dot = CGMutablePath()
        dot.move(to: CGPoint(x: 5, y: 5))
        dot.addLine(to: CGPoint(x: 5, y: 5))

        XCTAssertNil(PathRasteriser.stroke(dot, width: 4, cap: .butt, scale: 1))
        let round = try XCTUnwrap(PathRasteriser.stroke(dot, width: 4, cap: .round, scale: 1))
        XCTAssertEqual(area(round), Double.pi * 4, accuracy: 1)
    }

    // MARK: Arcs

    func testAnArcSweepsTheWayUIKitMeansIt() {
        // `clockwise: true` is UIKit's y-down clockwise, which is a *rising*
        // angle in SpriteKit's y-up space. The loading spinner relies on it:
        // its arc grows from nothing as its end angle grows.
        let quarter = arcPoints(from: 0, to: .pi / 2, clockwise: true)
        XCTAssertEqual(quarter.first?.x ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(quarter.first?.y ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(quarter.last?.x ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(quarter.last?.y ?? 0, 10, accuracy: 0.01)
        XCTAssertTrue(quarter.allSatisfy { $0.y >= -0.01 }, "the short way round, not the long")

        let other = arcPoints(from: 0, to: .pi / 2, clockwise: false)
        XCTAssertTrue(other.contains { $0.y < -5 }, "counter-clockwise takes the long way")
    }

    func testTheShimsRoundedRectMatchesCoreGraphicsOwn() throws {
        // The shim builds a rounded rectangle out of lines and `.arc`s; a
        // real CGPath builds one out of curves. Rasterising both is the
        // check that the arc convention above is the one UIKit means —
        // get it backwards and the corners bulge outward instead.
        let box = CGRect(x: 0, y: 0, width: 40, height: 24)
        let radius: CGFloat = 8
        let theirs = try XCTUnwrap(PathRasteriser.fill(
            CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil),
            scale: 2
        ))
        let ours = try XCTUnwrap(PathRasteriser.rasterise(
            PathRasteriser.flatten(Self.shimRoundedRect(box, radius: radius), scale: 2)
                .map(\.points),
            rule: .nonZero,
            scale: 2
        ))

        XCTAssertEqual(ours.width, theirs.width)
        XCTAssertEqual(ours.height, theirs.height)
        // A circular arc and CoreGraphics' four-cubic approximation of one
        // differ by a fraction of a pixel; anything larger means the arc
        // went the wrong way round.
        XCTAssertEqual(area(ours), area(theirs), accuracy: Double(ours.width) / 4)
        var worst = 0
        for i in 0 ..< min(ours.pixels.count, theirs.pixels.count) {
            worst = max(worst, abs(Int(ours.pixels[i]) - Int(theirs.pixels[i])))
        }
        XCTAssertLessThan(worst, 60, "corner pixels should agree to within rounding")
    }

    // MARK: Helpers

    /// `UIBezierPath(roundedRect:cornerRadius:)` as the shim records it,
    /// which is what the rasteriser meets on a device.
    private static func shimRoundedRect(_ rect: CGRect, radius r: CGFloat) -> [PathElement] {
        [
            .move(CGPoint(x: rect.minX + r, y: rect.minY)),
            .line(CGPoint(x: rect.maxX - r, y: rect.minY)),
            .arc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                 start: -.pi / 2, end: 0, clockwise: true),
            .line(CGPoint(x: rect.maxX, y: rect.maxY - r)),
            .arc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                 start: 0, end: .pi / 2, clockwise: true),
            .line(CGPoint(x: rect.minX + r, y: rect.maxY)),
            .arc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 start: .pi / 2, end: .pi, clockwise: true),
            .line(CGPoint(x: rect.minX, y: rect.minY + r)),
            .arc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 start: .pi, end: .pi * 1.5, clockwise: true),
            .close,
        ]
    }

    private func arcPoints(from: CGFloat, to: CGFloat, clockwise: Bool) -> [CGPoint] {
        PathRasteriser.flatten(
            [.arc(center: .zero, radius: 10, start: from, end: to, clockwise: clockwise)],
            scale: 1
        ).first?.points ?? []
    }

    private func rectanglePath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func coverage(_ mask: PathRasteriser.Mask, _ x: Int, _ y: Int) -> Int {
        guard x >= 0, y >= 0, x < mask.width, y < mask.height else { return -1 }
        return Int(mask.pixels[y * mask.width + x])
    }

    private func area(_ mask: PathRasteriser.Mask) -> Double {
        mask.pixels.reduce(0.0) { $0 + Double($1) / 255 }
    }
}
