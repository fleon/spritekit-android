import XCTest
@testable import GLESRenderer
@testable import SpriteKitShim

#if canImport(Darwin)
import CoreGraphics
#endif

/// Shapes as triangles, held to the rasteriser's masks: each mesh is
/// sampled at pixel centres as a GPU samples it (coverage interpolated
/// across each triangle, triangles composited over each other), on the
/// mask's own grid, and must come to the same pixels within what a
/// one-pixel feather can differ from exact area coverage at a corner.
final class ShapeTessellatorTests: XCTestCase {

    // MARK: Fills

    func testRectangleFillMatchesTheMask() throws {
        for scale: CGFloat in [1, 2.625] {
            try assertFillMatches(CGPath(rect: CGRect(x: 0.3, y: -4.2, width: 37.1, height: 12.6), transform: nil), scale: scale)
        }
    }

    func testRoundedPanelFillMatchesTheMask() throws {
        let path = CGPath(roundedRect: CGRect(x: -90, y: -30, width: 180, height: 60), cornerWidth: 14, cornerHeight: 14, transform: nil)
        try assertFillMatches(path, scale: 2.625)
    }

    func testCircleFillMatchesTheMask() throws {
        try assertFillMatches(CGPath(ellipseIn: CGRect(x: -20, y: -20, width: 40, height: 40), transform: nil), scale: 3)
    }

    func testConcaveFillMatchesTheMask() throws {
        // A five-pointed star drawn round its outline, and an L.
        let star = CGMutablePath()
        for i in 0 ..< 10 {
            let radius: CGFloat = i % 2 == 0 ? 30 : 12
            let angle = CGFloat(i) * .pi / 5 + .pi / 2
            let p = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
        }
        star.closeSubpath()
        try assertFillMatches(star, scale: 2)

        let ell = CGMutablePath()
        ell.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 10), CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 40), CGPoint(x: 0, y: 40)])
        ell.closeSubpath()
        try assertFillMatches(ell, scale: 1.5)
    }

    func testSubpathsApartFillAsEach() throws {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: 10, height: 10))
        path.addEllipse(in: CGRect(x: 20, y: 0, width: 10, height: 10))
        try assertFillMatches(path, scale: 2)
    }

    func testFillsItCannotTakeAreLeftToTheMask() {
        // A bow tie crosses itself; a ring is two subpaths, one in the other.
        let bowTie = CGMutablePath()
        bowTie.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)])
        bowTie.closeSubpath()
        XCTAssertNil(ShapeTessellator.fill(PathRasteriser.flatten(bowTie, scale: 1), scale: 1))

        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: 0, y: 0, width: 20, height: 20))
        ring.addEllipse(in: CGRect(x: 5, y: 5, width: 10, height: 10))
        XCTAssertNil(ShapeTessellator.fill(PathRasteriser.flatten(ring, scale: 1), scale: 1))
    }

    func testAnEmptyFillIsAnEmptyMeshNotAFallback() throws {
        let line = CGMutablePath()
        line.move(to: .zero)
        line.addLine(to: CGPoint(x: 10, y: 0))
        let mesh = try XCTUnwrap(ShapeTessellator.fill(PathRasteriser.flatten(line, scale: 1), scale: 1))
        XCTAssertTrue(mesh.isEmpty)
    }

    // MARK: Strokes

    func testPanelOutlineMatchesTheMask() throws {
        let path = CGPath(roundedRect: CGRect(x: -90, y: -30, width: 180, height: 60), cornerWidth: 14, cornerHeight: 14, transform: nil)
        for join in [CGLineJoin.miter, .round, .bevel] {
            try assertStrokeMatches(path, width: 3, cap: .butt, join: join, scale: 2.625)
        }
    }

    func testSquareCornersMatchForEveryJoin() throws {
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 24), transform: nil)
        for join in [CGLineJoin.miter, .round, .bevel] {
            try assertStrokeMatches(path, width: 6, cap: .butt, join: join, scale: 2)
        }
    }

    func testOpenZigzagMatchesForEveryCapAndJoin() throws {
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 18), CGPoint(x: 40, y: 2), CGPoint(x: 62, y: 20)])
        for cap in [CGLineCap.butt, .round, .square] {
            for join in [CGLineJoin.miter, .round, .bevel] {
                try assertStrokeMatches(path, width: 5, cap: cap, join: join, scale: 2)
            }
        }
    }

    func testSpinnerArcMatchesTheMask() throws {
        let path = CGMutablePath()
        path.addArc(center: .zero, radius: 18, startAngle: 0.3, endAngle: 4.4, clockwise: false)
        try assertStrokeMatches(path, width: 4, cap: .round, join: .miter, scale: 2.625)
    }

    func testHairlineMatchesTheMask() throws {
        let path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 30, height: 20), transform: nil)
        // Drawn a pixel wide at half strength, which spreads it a little
        // where exact coverage would not.
        try assertStrokeMatches(path, width: 0.5, cap: .butt, join: .miter, scale: 1, meanTolerance: 0.08)
    }

    func testDashedOutlineMatchesTheMask() throws {
        let base = CGPath(roundedRect: CGRect(x: -60, y: -20, width: 120, height: 40), cornerWidth: 10, cornerHeight: 10, transform: nil)
        let dashed = base.copy(dashingWithPhase: 1.7, lengths: [8, 6])
        try assertStrokeMatches(dashed, width: 2, cap: .butt, join: .miter, scale: 2.625)
    }

    func testAStrokeDoesNotCoverAnyPixelTwice() throws {
        // A translucent outline would darken wherever its own triangles
        // overlap: along a smooth curve and round a square corner they
        // must not.
        let panel = CGPath(roundedRect: CGRect(x: -90, y: -30, width: 180, height: 60), cornerWidth: 14, cornerHeight: 14, transform: nil)
        let box = CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 24), transform: nil)
        for (path, join) in [(panel, CGLineJoin.round), (panel, .miter), (box, .miter), (box, .round), (box, .bevel)] {
            let scale: CGFloat = 2
            let mesh = try XCTUnwrap(ShapeTessellator.stroke(PathRasteriser.flatten(path, scale: scale), width: 4, cap: .butt, join: join, scale: scale))
            let mask = try XCTUnwrap(PathRasteriser.stroke(path, width: 4, join: join, scale: scale))
            let summed = sample(mesh, on: mask, compositing: false)
            XCTAssertLessThanOrEqual(summed.max() ?? 0, 1.02, "\(join) overlaps itself")
        }
    }

    // MARK: Batching

    func testShapesMergeWithTheColourSpritesAroundThem() {
        var batcher = SpriteBatcher()
        let meshes = ShapeMeshes()
        meshes.pixelsPerPoint = 2
        batcher.shapeMeshes = meshes

        var list = DrawList()
        list.commands = [
            .sprite(colourSprite()),
            .shape(shape(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 40, height: 20), cornerWidth: 6, cornerHeight: 6, transform: nil))),
            .shape(shape(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil))),
            .sprite(colourSprite()),
        ]
        let passes = batcher.passes(for: list)
        XCTAssertEqual(passes.count, 1)
        guard case let .batches(batches) = passes.first else { return XCTFail("expected batches") }
        XCTAssertEqual(batches.count, 1, "one draw for both sprites and both shapes")
    }

    func testTexturedShapesAndCropMasksKeepTheirMasks() {
        var batcher = SpriteBatcher()
        batcher.shapeMeshes = ShapeMeshes()
        var textured = shape(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil))
        textured.fillTexture = SKTexture(color: .red, size: CGSize(width: 1, height: 1))

        var mask = DrawList()
        mask.commands = [.shape(shape(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil)))]
        var contents = DrawList()
        contents.commands = [.sprite(colourSprite())]

        var list = DrawList()
        list.commands = [
            .shape(textured),
            .crop(DrawList.Crop(transform: .identity, mask: mask, contents: contents)),
        ]
        let passes = batcher.passes(for: list)
        guard passes.count == 2, case .shape = passes[0], case let .crop(_, maskPasses, _) = passes[1],
              case .shape = maskPasses.first else {
            return XCTFail("expected the textured shape and the crop's mask as shape passes, got \(passes)")
        }
    }

    // MARK: Helpers

    private func shape(_ path: CGPath) -> DrawList.Shape {
        DrawList.Shape(
            transform: .identity, path: path, fillColor: .red, strokeColor: .white,
            lineWidth: 2, lineCap: .butt, lineJoin: .miter, alpha: 1
        )
    }

    private func colourSprite() -> DrawList.Sprite {
        DrawList.Sprite(
            transform: .identity, size: CGSize(width: 4, height: 4), anchorPoint: CGPoint(x: 0.5, y: 0.5),
            texture: nil, textureRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            color: .blue, colorBlendFactor: 1, alpha: 1, blendMode: .alpha, shader: nil, attributeValues: [:]
        )
    }

    private func assertFillMatches(_ path: CGPath, scale: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        let mesh = try XCTUnwrap(ShapeTessellator.fill(PathRasteriser.flatten(path, scale: scale), scale: scale), file: file, line: line)
        let mask = try XCTUnwrap(PathRasteriser.fill(path, scale: scale), file: file, line: line)
        compare(mesh, mask, file: file, line: line)
    }

    private func assertStrokeMatches(
        _ path: CGPath, width: CGFloat, cap: CGLineCap, join: CGLineJoin, scale: CGFloat, meanTolerance: Float = 0.05,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let mesh = try XCTUnwrap(
            ShapeTessellator.stroke(PathRasteriser.flatten(path, scale: scale), width: width, cap: cap, join: join, scale: scale),
            file: file, line: line
        )
        let mask = try XCTUnwrap(PathRasteriser.stroke(path, width: width, cap: cap, join: join, scale: scale), file: file, line: line)
        compare(mesh, mask, label: "\(cap) \(join)", meanTolerance: meanTolerance, file: file, line: line)
    }

    /// Edge pixels may differ (a feather is linear where area coverage is
    /// not, and a miter's feather rounds its tip), but not by much, not
    /// often, and not in total.
    private func compare(_ mesh: ShapeTessellator.Mesh, _ mask: PathRasteriser.Mask, label: String = "", meanTolerance: Float = 0.05, file: StaticString, line: UInt) {
        let drawn = sample(mesh, on: mask, compositing: true)
        var worst: Float = 0, total: Float = 0, drawnArea: Float = 0, maskArea: Float = 0, far = 0, touched = 0
        for i in 0 ..< drawn.count {
            let expected = Float(mask.pixels[i]) / 255
            let difference = abs(drawn[i] - expected)
            worst = max(worst, difference)
            drawnArea += drawn[i]
            maskArea += expected
            if drawn[i] > 0 || expected > 0 {
                touched += 1
                total += difference
                if difference > 0.25 { far += 1 }
            }
        }
        let mean = total / Float(max(touched, 1))
        XCTAssertLessThan(worst, 0.6, "\(label): worst pixel", file: file, line: line)
        XCTAssertLessThan(mean, meanTolerance, "\(label): mean over touched pixels", file: file, line: line)
        XCTAssertLessThan(Float(far) / Float(max(touched, 1)), 0.02, "\(label): share of pixels off by a quarter", file: file, line: line)
        XCTAssertEqual(drawnArea / max(maskArea, 1), 1, accuracy: 0.03, "\(label): total coverage", file: file, line: line)
    }

    /// The mesh drawn onto the mask's grid: each pixel sampled at its
    /// centre, nudged off exact edges, triangles composited over each other
    /// (or summed, to find overlaps).
    private func sample(_ mesh: ShapeTessellator.Mesh, on mask: PathRasteriser.Mask, compositing: Bool) -> [Float] {
        var out = [Float](repeating: 0, count: mask.width * mask.height)
        let s = Float(mask.scale)
        let left = Float(mask.bounds.minX), top = Float(mask.bounds.maxY)
        // Into the mask's pixels: x right, y down from its top row.
        let pixels = mesh.positions.map { SIMD2(($0.x - left) * s, (top - $0.y) * s) }
        let nudge = SIMD2<Float>(0.000137, 0.000291)
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let ia = Int(mesh.indices[t]), ib = Int(mesh.indices[t + 1]), ic = Int(mesh.indices[t + 2])
            let a = pixels[ia], b = pixels[ib], c = pixels[ic]
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            guard abs(area) > 1e-9 else { continue }
            let x0 = max(0, Int(min(a.x, b.x, c.x).rounded(.down))), x1 = min(mask.width - 1, Int(max(a.x, b.x, c.x).rounded(.up)))
            let y0 = max(0, Int(min(a.y, b.y, c.y).rounded(.down))), y1 = min(mask.height - 1, Int(max(a.y, b.y, c.y).rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0 ... y1 {
                for x in x0 ... x1 {
                    let p = SIMD2(Float(x) + 0.5, Float(y) + 0.5) + nudge
                    let wa = ((b.x - p.x) * (c.y - p.y) - (b.y - p.y) * (c.x - p.x)) / area
                    let wb = ((c.x - p.x) * (a.y - p.y) - (c.y - p.y) * (a.x - p.x)) / area
                    let wc = 1 - wa - wb
                    guard wa >= 0, wb >= 0, wc >= 0 else { continue }
                    let value = wa * mesh.coverage[ia] + wb * mesh.coverage[ib] + wc * mesh.coverage[ic]
                    let i = y * mask.width + x
                    out[i] = compositing ? value + out[i] * (1 - value) : out[i] + value
                }
            }
        }
        return out
    }
}
