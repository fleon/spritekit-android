import XCTest
@testable import GLESRenderer
@testable import SpriteKitShim

#if canImport(Darwin)
import CoreGraphics
#endif

/// An arc that begins a path begins a subpath of its own, as CoreGraphics
/// records it: a move to its first point, then the arc. A path built from
/// such arcs, each in its own path and added to one (`addPath`, as a ring
/// drawn in segments is), keeps them apart; within one path, an arc after
/// a pen is joined to it with a line.
///
/// On Android the shim records arcs itself (`PathGeometry.arc`); the cases
/// here build its recording and CoreGraphics' own path for the same calls,
/// and compare what the rasteriser makes of each.
final class ArcSubpathTests: XCTestCase {
    private let radius: CGFloat = 60

    /// The shim's recording of `addArc` (UIKit's rising sense: `clockwise`
    /// true for CoreGraphics' counter-clockwise), on a path with or without
    /// a pen.
    private func recorded(_ start: CGFloat, _ end: CGFloat, hasPen: Bool) -> [PathElement] {
        PathGeometry.arc(center: .zero, radius: radius, start: start, end: end, clockwise: true, hasPen: hasPen)
    }

    func testAnArcBeginningAPathStartsWithAMoveToItsFirstPoint() {
        let elements = recorded(0.5, 2, hasPen: false)
        XCTAssertEqual(elements.count, 2)
        guard case let .move(first) = elements[0] else { return XCTFail("no move first: \(elements)") }
        XCTAssertEqual(first.x, radius * cos(0.5), accuracy: 1e-9)
        XCTAssertEqual(first.y, radius * sin(0.5), accuracy: 1e-9)
        XCTAssertEqual(recorded(0.5, 2, hasPen: true).count, 1, "after a pen, the arc alone")
    }

    func testArcsAddedFromTheirOwnPathsStayApartAsCoreGraphicsKeepsThem() throws {
        // What `addPath` appends: each path's own elements, one after another.
        let shim = recorded(0, 2, hasPen: false) + recorded(3, 5, hasPen: false)
        let subpaths = PathRasteriser.flatten(shim, scale: 2)
        XCTAssertEqual(subpaths.count, 2)
        XCTAssertFalse(subpaths.contains(where: \.isClosed))

        #if canImport(Darwin)
        func cgArc(_ start: CGFloat, _ end: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            return path
        }
        let combined = CGMutablePath()
        combined.addPath(cgArc(0, 2))
        combined.addPath(cgArc(3, 5))
        let measured = PathRasteriser.flatten(combined, scale: 2)
        XCTAssertEqual(measured.count, 2, "CoreGraphics: two subpaths")
        for (ours, theirs) in zip(subpaths, measured) {
            XCTAssertEqual(ours.points.first!.x, theirs.points.first!.x, accuracy: 1e-6)
            XCTAssertEqual(ours.points.first!.y, theirs.points.first!.y, accuracy: 1e-6)
            XCTAssertEqual(ours.points.last!.x, theirs.points.last!.x, accuracy: 1e-6)
            XCTAssertEqual(ours.points.last!.y, theirs.points.last!.y, accuracy: 1e-6)
        }
        #endif
    }

    #if canImport(Darwin)
    /// Element for element: what `addPath` of two arc-started paths records
    /// in the shim, its arcs made curves as CoreGraphics makes them, against
    /// CoreGraphics' own elements for the same calls.
    func testAddedArcPathsRecordCoreGraphicsElements() {
        func cgArc(_ start: CGFloat, _ end: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            return path
        }
        let combined = CGMutablePath()
        combined.addPath(cgArc(0.25, 2))
        combined.addPath(cgArc(3, 5.5))
        let measured = combined.pathElements
        let ours = PathGeometry.curvesOnly(recorded(0.25, 2, hasPen: false) + recorded(3, 5.5, hasPen: false))

        func kinds(_ elements: [PathElement]) -> [String] {
            elements.map {
                switch $0 {
                case .move: "move"
                case .line: "line"
                case .quadCurve: "quad"
                case .curve: "curve"
                case .arc: "arc"
                case .close: "close"
                }
            }
        }
        XCTAssertEqual(kinds(ours).filter { $0 == "move" }.count, 2, "\(kinds(ours))")
        XCTAssertEqual(kinds(ours).filter { $0 == "line" }.count, 0, "no line joins the two")
        XCTAssertEqual(kinds(measured).filter { $0 == "move" }.count, 2, "CoreGraphics: \(kinds(measured))")
        XCTAssertEqual(kinds(measured).filter { $0 == "line" }.count, 0)

        // Each move lands on its arc's first point, as CoreGraphics' do.
        let moves: ([PathElement]) -> [CGPoint] = { $0.compactMap { if case let .move(p) = $0 { return p } else { return nil } } }
        for (a, b) in zip(moves(ours), moves(measured)) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
        }
        // And every curve ends where CoreGraphics' does, to within its approximation.
        let ends: ([PathElement]) -> [CGPoint] = { $0.compactMap { if case let .curve(p, _, _) = $0 { return p } else { return nil } } }
        XCTAssertEqual(ends(ours).last!.x, ends(measured).last!.x, accuracy: 1e-6)
        XCTAssertEqual(ends(ours).last!.y, ends(measured).last!.y, accuracy: 1e-6)
    }
    #endif

    func testNoStrokeRunsBetweenArcsAddedApart() throws {
        // Two halves of a ring with gaps between them, as a merged ring's
        // segments are: the line from one's end to the next's start would
        // cross the middle.
        let shim = recorded(0.3, .pi - 0.3, hasPen: false) + recorded(.pi + 0.3, 2 * .pi - 0.3, hasPen: false)
        let subpaths = PathRasteriser.flatten(shim, scale: 2)
        let outlines = PathRasteriser.strokeOutlines(subpaths, width: 16, cap: .round, join: .miter, miterLimit: 10)
        let mask = try XCTUnwrap(PathRasteriser.rasterise(outlines, rule: .nonZero, scale: 2))
        XCTAssertEqual(coverage(mask, atPoint: CGPoint(x: -57, y: 0)), 0, "nothing joins the first arc's end to the second's start")
        XCTAssertEqual(coverage(mask, atPoint: .zero), 0)
        XCTAssertEqual(coverage(mask, atPoint: CGPoint(x: 0, y: radius)), 255, "the arcs themselves draw")
        XCTAssertEqual(coverage(mask, atPoint: CGPoint(x: 0, y: -radius)), 255)
    }

    func testAnArcAfterAPenIsJoinedToItWithALineAsInCoreGraphics() {
        let shim = recorded(0, 2, hasPen: false) + recorded(3, 5, hasPen: true)
        XCTAssertEqual(PathRasteriser.flatten(shim, scale: 2).count, 1)

        #if canImport(Darwin)
        let path = CGMutablePath()
        path.addArc(center: .zero, radius: radius, startAngle: 0, endAngle: 2, clockwise: false)
        path.addArc(center: .zero, radius: radius, startAngle: 3, endAngle: 5, clockwise: false)
        XCTAssertEqual(PathRasteriser.flatten(path, scale: 2).count, 1, "CoreGraphics: one subpath")
        #endif
    }

    func testCurvesForAnArcAfterAMoveToItsStartAddNoLine() {
        let curves = PathGeometry.curvesOnly(recorded(0, 2, hasPen: false))
        guard case .move = curves.first else { return XCTFail("no move first: \(curves)") }
        XCTAssertFalse(curves.dropFirst().contains { if case .line = $0 { return true } else { return false } },
                       "no zero-length line from the move to the arc's start")
    }

    /// Coverage at `point` in path space (row 0 is the mask's top).
    private func coverage(_ mask: PathRasteriser.Mask, atPoint point: CGPoint) -> Int {
        let x = Int(((point.x - mask.bounds.minX) * mask.scale).rounded(.down))
        let y = Int(((mask.bounds.maxY - point.y) * mask.scale).rounded(.down))
        guard x >= 0, y >= 0, x < mask.width, y < mask.height else { return 0 }
        return Int(mask.pixels[y * mask.width + x])
    }
}
