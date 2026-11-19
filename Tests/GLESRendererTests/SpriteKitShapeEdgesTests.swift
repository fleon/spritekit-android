import XCTest
@testable import GLESRenderer
@testable import SpriteKitShim

#if canImport(Darwin)
import CoreGraphics
#endif

/// An `SKShapeNode`'s edges as SpriteKit draws them (`ShapeTessellator.Edges.spriteKit`),
/// held to what SpriteKit renders in an `SKView` on the iPhone 17 Pro (3x)
/// and iPad Air (2x) simulators, read back through `texture(from:)`: white
/// on black, a row of pixels across a vertical line or a fill's edge. (A
/// windowless `SKRenderer` on a Mac softens strokes over a whole node unit
/// whatever the density, which is not what a device draws.)
final class SpriteKitShapeEdgesTests: XCTestCase {

    // MARK: Strokes

    /// Measured in an `SKView` on the iPhone 17 Pro (3x) and iPad Air (2x)
    /// simulators: across a vertical line, the pixels from the one holding
    /// its centre outward, the centre on a pixel's centre.
    func testStrokesAreSoftenedAsSpriteKitSoftensThem() throws {
        let measured: [(width: CGFloat, scale: CGFloat, nodeScale: CGFloat, profile: [Double])] = [
            (0.25, 3, 1, [1.00, 0.46, 0]),
            (0.5, 3, 1, [1.00, 0.46, 0]),
            (1, 3, 1, [1.00, 0.67, 0.01]),
            (2, 3, 1, [1.00, 1.00, 0.93, 0.34, 0]),
            (6, 3, 1, [1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 0.93]),
            (0.5, 2, 1, [1.00, 0.38, 0]),
            (1, 2, 1, [1.00, 0.47, 0]),
            (2, 2, 1, [1.00, 0.93, 0.34, 0]),
            (6, 2, 1, [1.00, 1.00, 1.00, 1.00, 1.00, 0.93, 0.34, 0]),
            // In a node scaled 2x the edge is twice as soft on the screen.
            (0.5, 3, 2, [1.00, 0.85, 0.46, 0.08, 0]),
            (1, 3, 2, [1.00, 1.00, 0.67, 0.34, 0.01]),
            (2, 3, 2, [1.00, 1.00, 1.00, 1.00, 0.93, 0.64, 0.34, 0.05, 0]),
        ]
        for (width, scale, nodeScale, profile) in measured {
            let drawn = try strokeProfile(width: width, scale: scale, nodeScale: nodeScale, count: profile.count)
            for (d, (got, want)) in zip(drawn, profile).enumerated() {
                XCTAssertEqual(got, want, accuracy: 0.12, "width \(width) at \(scale)x, node scale \(nodeScale), \(d) px out")
            }
        }
    }

    /// `glowWidth`, measured on the iPhone 17 Pro simulator (3x): a white
    /// 2-unit line, from the pixel holding its centre outward. The edge's
    /// foot moves out by the glow; full coverage stays where it was.
    func testAGlowWidensTheStrokesEdgeByItsWidth() throws {
        let measured: [(glow: CGFloat, nodeScale: CGFloat, profile: [Double])] = [
            (1, 1, [1.00, 1.00, 0.97, 0.76, 0.55, 0.34, 0.12, 0]),
            (2, 1, [1.00, 1.00, 0.98, 0.85, 0.73, 0.60, 0.47, 0.33, 0.20, 0.07, 0]),
            (5, 1, [1.00, 1.00, 0.99, 0.93, 0.87, 0.81, 0.75, 0.69, 0.64, 0.57, 0.51, 0.45, 0.39, 0.33, 0.27, 0.22, 0.15, 0.09, 0.04, 0]),
            (5, 2, [1.00, 1.00, 1.00, 1.00, 0.99, 0.96, 0.93, 0.90, 0.87, 0.84, 0.81, 0.78, 0.75, 0.72, 0.69, 0.66, 0.64, 0.60, 0.57, 0.55,
                    0.51, 0.48, 0.45, 0.42, 0.39, 0.36, 0.33, 0.31, 0.27, 0.24, 0.22, 0.18, 0.15, 0.13, 0.09, 0.06, 0.04, 0]),
        ]
        for (glow, nodeScale, profile) in measured {
            let drawn = try strokeProfile(width: 2, scale: 3, nodeScale: nodeScale, count: profile.count, glow: glow)
            for (d, (got, want)) in zip(drawn, profile).enumerated() {
                XCTAssertEqual(got, want, accuracy: 0.12, "glow \(glow), node scale \(nodeScale), \(d) px out")
            }
        }
    }

    /// `isAntialiased = false`, measured at 3x: a hard band the stroke's own
    /// width, each pixel in when its centre is.
    func testAnUnantialiasedStrokeIsAHardBandItsOwnWidth() throws {
        let measured: [(width: CGFloat, profile: [Double])] = [
            (0.5, [1, 0]),
            (1, [1, 1, 0]),
            (2, [1, 1, 1, 0]),
            (2.5, [1, 1, 1, 1, 0]),
        ]
        for (width, profile) in measured {
            let drawn = try strokeProfile(width: width, scale: 3, nodeScale: 1, count: profile.count, antialiased: false)
            for (d, (got, want)) in zip(drawn, profile).enumerated() {
                XCTAssertEqual(got, want, accuracy: 1e-3, "width \(width), \(d) px out")
            }
        }
    }

    // MARK: Joins

    /// A 6-unit line turning by `degrees` at the origin, its `.miter` join
    /// cut at `limit` widths as `ShapeMeshes` makes it.
    private func join(turning degrees: CGFloat, limit: CGFloat) throws -> ShapeTessellator.Mesh {
        let turn = degrees * .pi / 180
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -10, y: 0))
        path.addLine(to: .zero)
        path.addLine(to: CGPoint(x: 10 * cos(turn), y: 10 * sin(turn)))
        return try XCTUnwrap(ShapeTessellator.stroke(
            PathRasteriser.flatten(path, scale: 3), width: 6, cap: .butt, join: .miter, miterLimit: .greatestFiniteMagnitude,
            scale: 3, edges: .spriteKit, edgePixels: 3,
            miterClip: ShapeMeshes.miterClip(limit: limit, width: 6)
        ))
    }

    /// How far out along the outside bisector the join is drawn, as it was
    /// measured: the last point with coverage above 0.2.
    private func reach(_ mesh: ShapeTessellator.Mesh, turning degrees: CGFloat) -> CGFloat {
        let turn = degrees * .pi / 180
        var bx = 1 - cos(turn), by = -sin(turn)
        let n = hypot(bx, by)
        bx /= n; by /= n
        var last: CGFloat = 0
        for step in 0 ..< 1600 {
            let k = CGFloat(step) * 0.25
            if coverage(of: mesh, at: SIMD2(Float(bx * k), Float(by * k))) > 0.2 { last = k }
        }
        return last
    }

    /// Measured on the iPhone 17 Pro simulator: past `miterLimit` widths
    /// from its vertex, SpriteKit cuts a `.miter` join straight across
    /// (CoreGraphics bevels it); a 6-point line's join reaches 3.25, 6.25,
    /// 12.25 and 60.25 points at limits 0.5 (SpriteKit's default), 1, 2 and
    /// 10, however sharp the turn, and a shorter join keeps its whole tip.
    func testAMitredJoinIsCutAcrossAtItsLimit() throws {
        for degrees: CGFloat in [178, 179.9] {
            for (limit, measured) in [(0.5, 3.25), (1, 6.25), (2, 12.25), (10, 60.25)] as [(CGFloat, CGFloat)] {
                let drawn = reach(try join(turning: degrees, limit: limit), turning: degrees)
                XCTAssertEqual(drawn, measured, accuracy: 0.75, "\(degrees)° at limit \(limit)")
            }
        }
        // 170°: the tip, 34.4 out, is short of 60, so it isn't cut. Where
        // the needle fades under the threshold differs (29.75 measured,
        // ~35 here, the feather holding up a sub-pixel point longer); the
        // join itself is whole.
        let whole = reach(try join(turning: 170, limit: 10), turning: 170)
        XCTAssertGreaterThan(whole, 28)
        XCTAssertLessThan(whole, 36)
    }

    func testATurnStraightBackHasNoJoinAndNoNaN() throws {
        let mesh = try join(turning: 180, limit: 10)
        XCTAssertTrue(mesh.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        // Measured: nothing past the vertex.
        XCTAssertLessThanOrEqual(reach(mesh, turning: 180), 0.5)
    }

    /// A join's mask is sized by the join: never by a miter thousands of
    /// widths long, whatever the limit.
    func testAJoinsMaskStaysBounded() throws {
        for degrees: CGFloat in [179.9, 180] {
            let turn = degrees * .pi / 180
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -10, y: 0))
            path.addLine(to: .zero)
            path.addLine(to: CGPoint(x: 10 * cos(turn), y: 10 * sin(turn)))
            let mask = try XCTUnwrap(SpriteKitMasks.stroke(
                path, width: 6, cap: .butt, join: .miter, scale: 3, edgePixels: 3,
                miterClip: ShapeMeshes.miterClip(limit: 1000, width: 6)
            ))
            XCTAssertTrue(mask.bounds.width.isFinite && mask.bounds.height.isFinite)
            // 64 widths at most: 384 points, under 1,200 pixels at 3x.
            XCTAssertLessThan(max(mask.width, mask.height), 1200, "\(degrees)°")
        }
    }

    // MARK: Fills

    /// SpriteKit doesn't antialias a fill: a pixel is in when its centre is.
    func testFillsAreNotAntialiased() throws {
        let scale: CGFloat = 2
        let circle = CGPath(ellipseIn: CGRect(x: -12, y: -12, width: 24, height: 24), transform: nil)
        // Flattened as `ShapeMeshes` flattens a fill: four times as fine.
        let mesh = try XCTUnwrap(ShapeTessellator.fill(PathRasteriser.flatten(circle, scale: scale * 4), scale: scale, edges: .spriteKit))
        XCTAssertTrue(mesh.coverage.allSatisfy { $0 == 1 }, "no feathered rim")
        let pixels = sample(mesh, box: CGRect(x: -14, y: -14, width: 28, height: 28), scale: scale)
        XCTAssertTrue(pixels.allSatisfy { $0 < 1e-5 || $0 > 1 - 1e-5 }, "no partial pixels")
        // Measured at 2x (the iPad Air simulator, and a Mac): 1804 pixels, against 1809.6 exact.
        XCTAssertEqual(pixels.reduce(0, +), 1804, accuracy: 6)
    }

    func testAFillThinnerThanAPixelIsDrawnNotLeftToTheMask() throws {
        let sliver = CGPath(rect: CGRect(x: 0, y: 0, width: 60, height: 0.25), transform: nil)
        XCTAssertNotNil(ShapeTessellator.fill(PathRasteriser.flatten(sliver, scale: 1), scale: 1, edges: .spriteKit))
    }

    // MARK: Helpers

    /// A vertical line's coverage, from the pixel holding its centre outward.
    private func strokeProfile(
        width: CGFloat, scale: CGFloat, nodeScale: CGFloat, count: Int, centredOnPixel: Bool = true,
        glow: CGFloat = 0, antialiased: Bool = true
    ) throws -> [Double] {
        // In the node's own units; the line at x = 0.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -20))
        path.addLine(to: CGPoint(x: 0, y: 20))
        let mesh = try XCTUnwrap(ShapeTessellator.stroke(
            PathRasteriser.flatten(path, scale: scale * nodeScale), width: width, cap: .butt, join: .miter,
            scale: scale * nodeScale, edges: .spriteKit, edgePixels: scale, glow: glow, antialiased: antialiased
        ))
        // Pixels across the middle row, their centres `k` pixels out from the
        // line (or `k + 0.5` with the line on a boundary).
        return (0 ..< count).map { k in
            let px = (centredOnPixel ? CGFloat(k) : CGFloat(k) + 0.5) / (scale * nodeScale)
            return Double(coverage(of: mesh, at: SIMD2(Float(px), 0)))
        }
    }

    /// The mesh's coverage at one point, as a GPU interpolates it, composited.
    private func coverage(of mesh: ShapeTessellator.Mesh, at p: SIMD2<Float>) -> Float {
        var out: Float = 0
        let q = p + SIMD2(0.000137, 0.000291)
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let ia = Int(mesh.indices[t]), ib = Int(mesh.indices[t + 1]), ic = Int(mesh.indices[t + 2])
            let a = mesh.positions[ia], b = mesh.positions[ib], c = mesh.positions[ic]
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            guard abs(area) > 1e-9 else { continue }
            let wa = ((b.x - q.x) * (c.y - q.y) - (b.y - q.y) * (c.x - q.x)) / area
            let wb = ((c.x - q.x) * (a.y - q.y) - (c.y - q.y) * (a.x - q.x)) / area
            let wc = 1 - wa - wb
            guard wa >= 0, wb >= 0, wc >= 0 else { continue }
            let v = wa * mesh.coverage[ia] + wb * mesh.coverage[ib] + wc * mesh.coverage[ic]
            out = v + out * (1 - v)
        }
        return out
    }

    /// Every pixel of `box` (in points) at `scale`, sampled at its centre.
    private func sample(_ mesh: ShapeTessellator.Mesh, box: CGRect, scale: CGFloat) -> [Float] {
        let w = Int(box.width * scale), h = Int(box.height * scale)
        var out: [Float] = []
        for y in 0 ..< h {
            for x in 0 ..< w {
                let p = SIMD2(Float(box.minX + (CGFloat(x) + 0.5) / scale), Float(box.minY + (CGFloat(y) + 0.5) / scale))
                out.append(coverage(of: mesh, at: p))
            }
        }
        return out
    }
}
