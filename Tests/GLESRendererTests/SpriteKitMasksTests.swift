import XCTest
@testable import GLESRenderer
@testable import SpriteKitShim

#if canImport(Darwin)
import CoreGraphics
#endif

/// The masks a shape node falls back to (a textured fill, a self-crossing
/// fill, a crop's mask) drawn with SpriteKit's edges, as its triangles are
/// (`SpriteKitShapeEdgesTests`). A fill's measured area holds at 2x for a
/// crop node's shape mask too.
final class SpriteKitMasksTests: XCTestCase {

    func testAFillMaskIsSampledAtPixelCentres() throws {
        let circle = CGPath(ellipseIn: CGRect(x: -12, y: -12, width: 24, height: 24), transform: nil)
        let mask = try XCTUnwrap(SpriteKitMasks.fill(circle, scale: 2))
        XCTAssertTrue(mask.pixels.allSatisfy { $0 == 0 || $0 == 255 }, "no partial pixels")
        // 1804 pixels on a Mac, standalone and as a crop node's mask.
        XCTAssertEqual(Double(mask.pixels.filter { $0 == 255 }.count), 1804, accuracy: 6)
    }

    /// A mask's pixels sit on a grid of its own (its bounds and a margin),
    /// so it is held to its triangles where its pixels' centres are: the
    /// triangles being held to SpriteKit in `SpriteKitShapeEdgesTests`.
    func testAFillMaskCoversWhatItsTrianglesDo() throws {
        let scale: CGFloat = 2
        let panel = CGPath(roundedRect: CGRect(x: -30.3, y: -12.6, width: 60, height: 24), cornerWidth: 7, cornerHeight: 7, transform: nil)
        let mask = try XCTUnwrap(SpriteKitMasks.fill(panel, scale: scale))
        let mesh = try XCTUnwrap(ShapeTessellator.fill(PathRasteriser.flatten(panel, scale: scale * 4), scale: scale, edges: .spriteKit))
        let (differ, covered) = compare(mask, mesh)
        XCTAssertGreaterThan(covered, 5000)
        XCTAssertLessThan(differ, 1e-5)
    }

    func testASelfCrossingFillIsSampledAtCentresToo() throws {
        let bowTie = CGMutablePath()
        bowTie.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 20), CGPoint(x: 20, y: 0), CGPoint(x: 0, y: 20)])
        bowTie.closeSubpath()
        XCTAssertNil(ShapeTessellator.fill(PathRasteriser.flatten(bowTie, scale: 2), scale: 2, edges: .spriteKit), "the mask's case")
        let mask = try XCTUnwrap(SpriteKitMasks.fill(bowTie, scale: 2))
        XCTAssertTrue(mask.pixels.allSatisfy { $0 == 0 || $0 == 255 })
        XCTAssertGreaterThan(mask.pixels.filter { $0 == 255 }.count, 700)
    }

    func testAStrokeMaskCoversWhatItsTrianglesDo() throws {
        let scale: CGFloat = 2
        let ring = CGPath(ellipseIn: CGRect(x: -20, y: -20, width: 40, height: 40), transform: nil)
        for width: CGFloat in [0.5, 2, 5] {
            let mask = try XCTUnwrap(SpriteKitMasks.stroke(ring, width: width, cap: .butt, join: .miter, scale: scale, edgePixels: scale))
            let mesh = try XCTUnwrap(ShapeTessellator.stroke(
                PathRasteriser.flatten(ring, scale: scale), width: width, cap: .butt, join: .miter, scale: scale,
                edges: .spriteKit, edgePixels: scale
            ))
            let (differ, covered) = compare(mask, mesh)
            XCTAssertGreaterThan(covered, 100)
            XCTAssertLessThan(differ, 1.5 / 255, "width \(width)")
        }
    }

    // MARK: Helpers

    /// The largest difference between the mask's pixels and the mesh's
    /// coverage at their centres, and how many pixels are covered.
    private func compare(_ mask: PathRasteriser.Mask, _ mesh: ShapeTessellator.Mesh) -> (Float, Int) {
        var worst: Float = 0, covered = 0
        for y in 0 ..< mask.height {
            for x in 0 ..< mask.width {
                // Where the mask sampled it, off the centre by its nudge.
                let nudge = SpriteKitMasks.sampleNudge
                let px = Float(mask.bounds.minX + (CGFloat(x) + 0.5 + CGFloat(nudge.x)) / mask.scale)
                let py = Float(mask.bounds.maxY - (CGFloat(y) + 0.5 + CGFloat(nudge.y)) / mask.scale)
                let mine = Float(mask.pixels[y * mask.width + x]) / 255
                if mine > 0.5 { covered += 1 }
                worst = max(worst, abs(mine - coverage(of: mesh, at: SIMD2(px, py))))
            }
        }
        return (worst, covered)
    }

    /// The mesh's coverage at one point, interpolated and composited.
    private func coverage(of mesh: ShapeTessellator.Mesh, at q: SIMD2<Float>) -> Float {
        var out: Float = 0
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let ia = Int(mesh.indices[t]), ib = Int(mesh.indices[t + 1]), ic = Int(mesh.indices[t + 2])
            let a = mesh.positions[ia], b = mesh.positions[ib], c = mesh.positions[ic]
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            guard abs(area) > 1e-12 else { continue }
            let wa = ((b.x - q.x) * (c.y - q.y) - (b.y - q.y) * (c.x - q.x)) / area
            let wb = ((c.x - q.x) * (a.y - q.y) - (c.y - q.y) * (a.x - q.x)) / area
            let wc = 1 - wa - wb
            guard wa >= 0, wb >= 0, wc >= 0 else { continue }
            let v = wa * mesh.coverage[ia] + wb * mesh.coverage[ib] + wc * mesh.coverage[ic]
            out = v + out * (1 - v)
        }
        return out
    }
}
