import XCTest
@testable import GLESRenderer
@testable import SpriteKitShim

#if canImport(Darwin)
import CoreGraphics
#endif

/// An `SKShapeNode`'s edges as SpriteKit draws them (`ShapeTessellator.Edges.spriteKit`),
/// held to what a Mac's SpriteKit renders through `SKRenderer`: white on
/// black, a row of pixels read back across a vertical line or a fill's
/// edge, at 1x, 2x and 3x.
final class SpriteKitShapeEdgesTests: XCTestCase {

    // MARK: Strokes

    /// Measured: across a vertical line, the pixels from the one holding its
    /// centre outward (the centre on a pixel's centre: `off` 0.5).
    func testStrokesAreSoftenedAsSpriteKitSoftensThem() throws {
        let measured: [(width: CGFloat, scale: CGFloat, profile: [Double])] = [
            (2, 2, [1.00, 0.76, 0.34, 0]),
            (4, 2, [1.00, 1.00, 1.00, 0.76, 0.34, 0]),
            (1, 2, [1.00, 0.47, 0]),
            (0.5, 2, [1.00, 0.38, 0]),
            (2, 1, [1.00, 0.34, 0]),
            (4, 1, [1.00, 1.00, 0.34, 0]),
            (2, 3, [1.00, 0.89, 0.62, 0.34, 0.06, 0]),
            (1, 3, [1.00, 0.69, 0.24, 0]),
            (0.25, 3, [1.00, 0.64, 0.13, 0]),
        ]
        for (width, scale, profile) in measured {
            let drawn = try strokeProfile(width: width, scale: scale, nodeScale: 1, count: profile.count)
            for (d, (got, want)) in zip(drawn, profile).enumerated() {
                XCTAssertEqual(got, want, accuracy: 0.09, "width \(width) at \(scale)x, \(d) px out")
            }
        }
    }

    /// The softening is in the node's own units: scaled up, a node's stroke
    /// is softer; measured with a 1-unit line in a node scaled 2x at 2x.
    func testTheSofteningScalesWithTheNode() throws {
        // Measured, from the line's centre (on a pixel boundary) outward:
        // 1.00 0.72 0.38 0.05 on the far side of its centre pixel.
        let drawn = try strokeProfile(width: 1, scale: 2, nodeScale: 2, count: 4, centredOnPixel: false)
        for (got, want) in zip(drawn, [1.00, 0.72, 0.38, 0.05]) {
            XCTAssertEqual(got, want, accuracy: 0.1)
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
        // Measured on a Mac: 1804 pixels at 2x, against 1809.6 exact.
        XCTAssertEqual(pixels.reduce(0, +), 1804, accuracy: 6)
    }

    func testAFillThinnerThanAPixelIsDrawnNotLeftToTheMask() throws {
        let sliver = CGPath(rect: CGRect(x: 0, y: 0, width: 60, height: 0.25), transform: nil)
        XCTAssertNotNil(ShapeTessellator.fill(PathRasteriser.flatten(sliver, scale: 1), scale: 1, edges: .spriteKit))
    }

    // MARK: Helpers

    /// A vertical line's coverage, from the pixel holding its centre outward.
    private func strokeProfile(width: CGFloat, scale: CGFloat, nodeScale: CGFloat, count: Int, centredOnPixel: Bool = true) throws -> [Double] {
        // In the node's own units; the line at x = 0.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -20))
        path.addLine(to: CGPoint(x: 0, y: 20))
        let mesh = try XCTUnwrap(ShapeTessellator.stroke(
            PathRasteriser.flatten(path, scale: scale * nodeScale), width: width, cap: .butt, join: .miter,
            scale: scale * nodeScale, edges: .spriteKit
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
