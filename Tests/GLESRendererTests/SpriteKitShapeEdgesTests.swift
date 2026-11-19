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
    private func strokeProfile(width: CGFloat, scale: CGFloat, nodeScale: CGFloat, count: Int, centredOnPixel: Bool = true) throws -> [Double] {
        // In the node's own units; the line at x = 0.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -20))
        path.addLine(to: CGPoint(x: 0, y: 20))
        let mesh = try XCTUnwrap(ShapeTessellator.stroke(
            PathRasteriser.flatten(path, scale: scale * nodeScale), width: width, cap: .butt, join: .miter,
            scale: scale * nodeScale, edges: .spriteKit, edgePixels: scale
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
