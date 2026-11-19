import XCTest
@testable import GLESRenderer
@testable import SpriteKitShim

/// How a stroke's texture lies on it, as a Mac's SpriteKit draws one,
/// measured with a texture whose texels say where they are (red the u of
/// their column, green the v of their row) rendered through `SKView` and
/// read back (macOS 27.2):
///
/// - Along: u is the distance along the subpath, in the path's own points,
///   one repeat every `lineWidth` times the texture's aspect (width over
///   height), whatever its size in points: a 200x40 texture repeats every
///   100 points at a width of 20 and every 50 at 10, 100x20 points or
///   200x40. It repeats, runs through joins, curves and arcs alike, either
///   way round, and on past each end into a cap. The node's scale doesn't
///   change it: it's the path's points.
/// - Subpaths: each starts again at 0, but runs as far as every subpath up
///   to its end does: three of 100 points at a repeat of 100 run 1, 2 and 3
///   repeats; 50 then 150 run 0.5 and 2.
/// - Across: v is 0.5 plus the offset to the left of travel over the
///   width, 0 on the right edge to 1 on the left, whatever the texture's
///   height.
/// - Colour: the texel times the stroke's colour and alpha (texel 0.5, 1,
///   0.25 stroked red draws 0.5, 0, 0).
/// - Fills, for comparison, map the path's bounding box, in its own space,
///   onto the texture's 0…1: a rect, a rounded rect, a circle and a
///   triangle alike, rotated or scaled with the node. The mask already
///   does that (`CoverageGeometry.fillMap`).
final class StrokeTextureTests: XCTestCase {
    private func stroke(_ path: CGPath, width: CGFloat = 20, cap: CGLineCap = .butt) throws -> ShapeTessellator.Mesh {
        try XCTUnwrap(ShapeTessellator.stroke(
            PathRasteriser.flatten(path, scale: 2), width: width, cap: cap, join: .miter, scale: 2, alongTexture: true
        ))
    }

    private func line(_ a: CGPoint, _ b: CGPoint, into path: CGMutablePath) {
        path.move(to: a)
        path.addLine(to: b)
    }

    /// The u (in path points) and v of the vertices on the stroke's centre
    /// line or its core edges near `point`.
    private func coordinates(_ mesh: ShapeTessellator.Mesh, near point: CGPoint, within: Float = 0.75) -> [SIMD2<Float>] {
        (0 ..< mesh.vertexCount).compactMap { i in
            let position = mesh.positions[i]
            // The core's vertices; the feathered rim's lie half a pixel out.
            guard mesh.coverage[i] > 0 else { return nil }
            return abs(position.x - Float(point.x)) < within && abs(position.y - Float(point.y)) < within ? mesh.texCoords[i] : nil
        }
    }

    func testUVsRunAlongALineAndAcrossItsWidth() throws {
        let path = CGMutablePath()
        line(CGPoint(x: -150, y: 0), CGPoint(x: 150, y: 0), into: path)
        let mesh = try stroke(path)
        XCTAssertEqual(mesh.texCoords.count, mesh.vertexCount)

        // The core's corners at each end: u 0 and 300 points, v either side.
        let half: CGFloat = 10 - 0.25 // the core sits a quarter-point (half a pixel at 2x) inside the edge
        for (x, u) in [(-150.0, 0.0), (150.0, 300.0)] {
            let left = coordinates(mesh, near: CGPoint(x: x, y: half), within: 0.6)
            let right = coordinates(mesh, near: CGPoint(x: x, y: -half), within: 0.6)
            XCTAssertFalse(left.isEmpty, "a vertex at the left edge, x \(x)")
            XCTAssertFalse(right.isEmpty, "a vertex at the right edge, x \(x)")
            for uv in left {
                XCTAssertEqual(uv.x, Float(u), accuracy: 0.6)
                XCTAssertEqual(uv.y, 0.5 + Float(half / 20), accuracy: 0.01, "left of travel is towards 1")
            }
            for uv in right { XCTAssertEqual(uv.y, 0.5 - Float(half / 20), accuracy: 0.01) }
        }
    }

    func testAcrossFlipsWithTheWayTheStrokeRuns() throws {
        let path = CGMutablePath()
        line(CGPoint(x: 150, y: 0), CGPoint(x: -150, y: 0), into: path)
        let mesh = try stroke(path)
        // Travelling left, its left is down: the lower edge is near 1.
        let lower = coordinates(mesh, near: CGPoint(x: 0, y: -9.75), within: 150)
            .filter { $0.y > 0.5 }
        XCTAssertFalse(lower.isEmpty)
        let start = coordinates(mesh, near: CGPoint(x: 150, y: 0), within: 10.5).map(\.x)
        XCTAssertEqual(start.min() ?? -1, 0, accuracy: 0.6, "u starts where the path does, at its right end")
    }

    func testARoundCapRunsOnPastTheEnd() throws {
        let path = CGMutablePath()
        line(CGPoint(x: -100, y: 0), CGPoint(x: 100, y: 0), into: path)
        let mesh = try stroke(path, cap: .round)
        // The cap's tip, half a width past each end, lies 10 points before 0
        // and 10 past the end.
        let starts = zip(mesh.positions, mesh.texCoords).filter { $0.0.x < -105 }.map(\.1.x)
        let ends = zip(mesh.positions, mesh.texCoords).filter { $0.0.x > 105 }.map(\.1.x)
        XCTAssertEqual(starts.min() ?? 0, -10.25, accuracy: 0.6)
        XCTAssertEqual(ends.max() ?? 0, 210.25, accuracy: 0.6)
    }

    func testEachSubpathRunsAsFarAsAllUpToItsEnd() throws {
        // Three of 100 points: 100, 200 and 300 points along by their ends.
        let three = CGMutablePath()
        for y in [60.0, 0, -60] { line(CGPoint(x: -150, y: y), CGPoint(x: -50, y: y), into: three) }
        let mesh = try stroke(three)
        for (y, end) in [(60.0, 100.0), (0, 200), (-60, 300)] {
            let starts = coordinates(mesh, near: CGPoint(x: -150, y: y), within: 10).map(\.x)
            let ends = coordinates(mesh, near: CGPoint(x: -50, y: y), within: 10).map(\.x)
            // The end's core sits a quarter-point in, at the subpath's pace.
            XCTAssertEqual(starts.min() ?? -1, 0, accuracy: 0.8, "subpath at y \(y) starts at 0")
            XCTAssertEqual(ends.max() ?? -1, Float(end), accuracy: 1.5, "subpath at y \(y) runs to \(end)")
        }

        // 50 then 150: 50, then 200 over its 150.
        let uneven = CGMutablePath()
        line(CGPoint(x: -150, y: 40), CGPoint(x: -100, y: 40), into: uneven)
        line(CGPoint(x: -150, y: -40), CGPoint(x: 0, y: -40), into: uneven)
        let second = try stroke(uneven)
        XCTAssertEqual(coordinates(second, near: CGPoint(x: -100, y: 40), within: 10).map(\.x).max() ?? -1, 50, accuracy: 0.6)
        XCTAssertEqual(coordinates(second, near: CGPoint(x: 0, y: -40), within: 10).map(\.x).max() ?? -1, 200, accuracy: 1.5)
    }

    func testAClosedSubpathRunsOnThroughItsClosingSegment() throws {
        let square = CGPath(rect: CGRect(x: -60, y: -60, width: 120, height: 120), transform: nil)
        let mesh = try stroke(square, width: 10)
        // No triangle runs back along the texture: the closing segment ends
        // at 480 points, its own copy of the start, not back at 0, so no
        // triangle spans more than a side's 120 (and the joins' few more).
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let us = (0 ..< 3).map { mesh.texCoords[Int(mesh.indices[t + $0])].x }
            XCTAssertLessThan(us.max()! - us.min()!, 130, "a triangle spanning \(us)")
        }
        XCTAssertEqual(mesh.texCoords.map(\.x).max() ?? 0, 480, accuracy: 6)
    }

    func testAnArcRunsAlongItsLength() throws {
        let path = CGMutablePath()
        path.addArc(center: .zero, radius: 80, startAngle: 0, endAngle: .pi, clockwise: false)
        let mesh = try stroke(path, width: 10)
        let end = coordinates(mesh, near: CGPoint(x: -80, y: 0), within: 6).map(\.x).max() ?? 0
        XCTAssertEqual(end, Float(80 * CGFloat.pi), accuracy: 1, "half a circle of 80: about 251 points")
    }

    func testATexturedStrokeBatchesAlongItsOwnRepeatingTexture() throws {
        var batcher = SpriteBatcher()
        batcher.shapeMeshes = ShapeMeshes()
        let path = CGMutablePath()
        line(CGPoint(x: -150, y: 0), CGPoint(x: 150, y: 0), into: path)
        let texture = SKTexture(color: .white, size: CGSize(width: 200, height: 40))
        var shape = DrawList.Shape(
            transform: .identity, path: path, fillColor: .clear, strokeColor: SKColor(red: 1, green: 0, blue: 0, alpha: 0.5),
            lineWidth: 20, lineCap: .butt, lineJoin: .miter, alpha: 1
        )
        shape.strokeTexture = texture
        var list = DrawList()
        list.commands = [.shape(shape)]

        guard case let .batches(batches)? = batcher.passes(for: list).first, let batch = batches.first else {
            return XCTFail("expected the stroke as a batch, not its mask")
        }
        XCTAssertTrue(batch.repeatsAlong)
        XCTAssertTrue(batch.texture === texture)
        XCTAssertTrue(batch.ownImage, "its own image, not a page, so it can repeat")
        // u over a repeat of 20 x 200/40 = 100 points: the far end is 3.
        let stride = SpriteBatcher.floatsPerVertex
        let us = Swift.stride(from: 2, to: batch.vertices.count, by: stride).map { batch.vertices[$0] }
        XCTAssertEqual(us.max() ?? 0, 3, accuracy: 0.01)
        XCTAssertEqual(us.min() ?? 1, 0, accuracy: 0.01)
        // The colour multiplies the texel: red, at the colour's alpha times coverage.
        XCTAssertEqual(batch.vertices[4], 1)
        XCTAssertEqual(batch.vertices[5], 0)
        XCTAssertLessThanOrEqual(batch.vertices[7], 0.5)
    }

    /// A texture cut from another: SpriteKit ignores the cut but for its
    /// aspect. Measured with a 400x80 image, the coordinate texture on its
    /// left half and blue on its right, stroked with its left half
    /// (`SKTexture(rect: (0, 0, 0.5, 1), in:)`, 200x80) at a width of 20:
    /// the stroke runs through the blue half too, the whole image every 50
    /// points (20 x 200/80), v across the whole image's height. Its top-left
    /// quarter (200x40) repeats every 100. A fill of the left half maps its
    /// box onto the whole image as well, which the mask already does
    /// (`ResourceCache.imageName` binds the root).
    func testAStrokeTextureCutFromAnotherRunsOverTheWholeImage() throws {
        var batcher = SpriteBatcher()
        batcher.shapeMeshes = ShapeMeshes()
        let path = CGMutablePath()
        line(CGPoint(x: -150, y: 0), CGPoint(x: 150, y: 0), into: path)
        let sheet = SKTexture(color: .white, size: CGSize(width: 400, height: 80))
        let half = SKTexture(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), in: sheet)
        var shape = DrawList.Shape(
            transform: .identity, path: path, fillColor: .clear, strokeColor: .white,
            lineWidth: 20, lineCap: .butt, lineJoin: .miter, alpha: 1
        )
        shape.strokeTexture = half
        var list = DrawList()
        list.commands = [.shape(shape)]
        guard case let .batches(batches)? = batcher.passes(for: list).first, let batch = batches.first else {
            return XCTFail("expected the stroke as a batch, not its mask")
        }
        XCTAssertTrue(batch.texture === sheet, "the whole image it was cut from")
        XCTAssertTrue(batch.repeatsAlong)
        let stride = SpriteBatcher.floatsPerVertex
        let us = Swift.stride(from: 2, to: batch.vertices.count, by: stride).map { batch.vertices[$0] }
        let vs = Swift.stride(from: 3, to: batch.vertices.count, by: stride).map { batch.vertices[$0] }
        // 300 points at a repeat of 20 x 200/80 = 50: six of the whole image.
        XCTAssertEqual(us.max() ?? 0, 6, accuracy: 0.02, "the end's feathered rim runs half a point on")
        XCTAssertLessThanOrEqual(vs.max() ?? 2, 1.05)
        XCTAssertGreaterThanOrEqual(vs.min() ?? -1, -0.05)
    }
}
