import XCTest
@testable import GLESRenderer
@testable import SpriteKitShim

/// Label geometry, with a fake glyph source.
///
/// The seam is what makes this testable on the host: the renderer asks for
/// glyphs through `CoverageGeometry.GlyphSource`, and a test can answer with
/// a square per character and then check exactly where the quads landed —
/// including the cases that are awkward to see on a device, like a second
/// line hanging below the first and a right-aligned label ending at its
/// origin.
final class CoverageGeometryTests: XCTestCase {

    /// One 10x10 glyph per character, 12 points of advance, sitting on the
    /// baseline. Page 0 is 100x100, page 1 is 50x50, and a character can be
    /// put on page 1 to check runs are split by page.
    private final class Squares: CoverageGeometry.GlyphSource {
        var onPageOne: Set<Character> = []
        private(set) var asked: [String] = []

        func glyphs(for line: String, font: FontKey) -> [CoverageGeometry.Glyph] {
            asked.append(line)
            var offset = 0
            return line.enumerated().map { index, character in
                defer { offset += character.utf8.count }
                return CoverageGeometry.Glyph(
                    page: onPageOne.contains(character) ? 1 : 0,
                    rect: CGRect(x: 10, y: 20, width: 10, height: 10),
                    frame: CGRect(x: CGFloat(index) * 12, y: 0, width: 10, height: 10),
                    cluster: offset
                )
            }
        }

        func pageSize(_ page: Int) -> CGSize? {
            switch page {
            case 0: return CGSize(width: 100, height: 100)
            case 1: return CGSize(width: 50, height: 50)
            default: return nil
            }
        }
    }

    private func label(
        _ text: String,
        lines: [(String, CGPoint)],
        transform: CGAffineTransform = .identity,
        alpha: CGFloat = 1,
        colour: SKColor = SKColor(red: 1, green: 0, blue: 0, alpha: 1)
    ) -> DrawList.Label {
        DrawList.Label(
            transform: transform,
            text: text,
            fontName: "Test",
            fontSize: 10,
            color: colour,
            horizontal: .left,
            vertical: .baseline,
            alpha: alpha,
            layout: TextLayout(
                lines: lines.map {
                    TextLayout.Placed(
                        line: TextLine(text: $0.0, advance: CGFloat($0.0.count) * 12,
                                       inkBounds: .zero),
                        origin: $0.1
                    )
                },
                bounds: .zero
            )
        )
    }

    func testNoLayoutMeansNothingToDraw() {
        var bare = label("ab", lines: [])
        bare.layout = nil
        XCTAssertTrue(CoverageGeometry.runs(for: bare, source: Squares()).isEmpty,
                      "a label with no provider registered draws nothing, not a guess")
    }

    func testDrawsOneQuadPerGlyphAtTheLinesPenOrigin() throws {
        let source = Squares()
        let runs = CoverageGeometry.runs(
            for: label("ab", lines: [("ab", CGPoint(x: 100, y: 50))]),
            source: source
        )
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(run.quadCount, 2)
        XCTAssertEqual(source.asked, ["ab"], "the line is shaped once, not once a glyph")

        // First glyph: x 100...110, y 50...60.
        XCTAssertEqual(corner(run, quad: 0, 0), CGPoint(x: 100, y: 50))
        XCTAssertEqual(corner(run, quad: 0, 2), CGPoint(x: 110, y: 60))
        // Second: one 12-point advance on.
        XCTAssertEqual(corner(run, quad: 1, 0), CGPoint(x: 112, y: 50))
    }

    func testLetterSpacingMovesEachCharacterOnByTheSpacingBeforeIt() throws {
        // "é" is two UTF-8 bytes: glyph clusters count bytes, spacing counts
        // characters.
        var spaced = label("aéb", lines: [("aéb", CGPoint(x: 100, y: 0))])
        spaced.kern = 3
        let run = try XCTUnwrap(CoverageGeometry.runs(for: spaced, source: Squares()).first)
        XCTAssertEqual(corner(run, quad: 0, 0).x, 100)
        XCTAssertEqual(corner(run, quad: 1, 0).x, 100 + 12 + 3)
        XCTAssertEqual(corner(run, quad: 2, 0).x, 100 + 24 + 6)
    }

    func testAShapesTextureStretchesOverThePathsBounds() {
        // A mask padded 2 points round a 100×50 path at (10, 20).
        let path = CGRect(x: 10, y: 20, width: 100, height: 50)
        let mask = path.insetBy(dx: -2, dy: -2)
        let map = CoverageGeometry.fillMap(mask: mask, path: path)
        func fill(_ u: Float, _ v: Float) -> SIMD2<Float> { SIMD2(map.x + u * map.z, map.y + v * map.w) }
        // The mask's top-left corner is 2 points beyond the path's.
        XCTAssertEqual(fill(0, 0).x, -0.02, accuracy: 1e-6)
        XCTAssertEqual(fill(0, 0).y, -0.04, accuracy: 1e-6)
        // Its bottom-right, 2 points beyond the path's bottom-right.
        XCTAssertEqual(fill(1, 1).x, 1.02, accuracy: 1e-6)
        XCTAssertEqual(fill(1, 1).y, 1.04, accuracy: 1e-6)
        // The path's own top-left is the texture's (0, 0).
        let u = Float((path.minX - mask.minX) / mask.width), v = Float((mask.maxY - path.maxY) / mask.height)
        XCTAssertEqual(fill(u, v).x, 0, accuracy: 1e-6)
        XCTAssertEqual(fill(u, v).y, 0, accuracy: 1e-6)
        XCTAssertEqual(CoverageGeometry.fillMap(mask: mask, path: .zero), SIMD4(0, 0, 0, 0))
    }

    func testTheLayoutIsWhatIsDrawn() throws {
        // The lines' pen origins already carry both alignment modes — the
        // node worked them out when it measured itself, and this is the
        // check that they are honoured by being used rather than redone.
        let source = Squares()
        let centred = CoverageGeometry.runs(
            for: label("ab", lines: [("ab", CGPoint(x: -12, y: 0))]),
            source: source
        )
        let right = CoverageGeometry.runs(
            for: label("ab", lines: [("ab", CGPoint(x: -24, y: 0))]),
            source: source
        )
        XCTAssertEqual(corner(try XCTUnwrap(centred.first), quad: 0, 0).x, -12)
        XCTAssertEqual(corner(try XCTUnwrap(right.first), quad: 0, 0).x, -24)
    }

    func testASecondLineHangsBelowTheFirst() throws {
        let runs = CoverageGeometry.runs(
            for: label("a\nb", lines: [("a", .zero), ("b", CGPoint(x: 0, y: -14))]),
            source: Squares()
        )
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.quadCount, 2)
        XCTAssertEqual(corner(run, quad: 0, 0).y, 0)
        XCTAssertEqual(corner(run, quad: 1, 0).y, -14)
    }

    func testGlyphsAreSplitByPageAndKeepTheirOrder() throws {
        let source = Squares()
        source.onPageOne = ["b"]
        let runs = CoverageGeometry.runs(
            for: label("ab", lines: [("ab", .zero)]),
            source: source
        )
        XCTAssertEqual(runs.map(\.page), [0, 1], "page 0 first, because 'a' came first")
        XCTAssertEqual(runs.map(\.quadCount), [1, 1])
    }

    func testTextureCoordinatesRunDownThePage() throws {
        // Atlas pages are uploaded top row first, so v grows down them: the
        // quad's top edge takes the rect's minY. Get this backwards and
        // every glyph draws upside down.
        let runs = CoverageGeometry.runs(
            for: label("a", lines: [("a", .zero)]),
            source: Squares()
        )
        let run = try XCTUnwrap(runs.first)
        assertPoint(uv(run, quad: 0, 0), CGPoint(x: 0.1, y: 0.3), "bottom left of the quad")
        assertPoint(uv(run, quad: 0, 2), CGPoint(x: 0.2, y: 0.2), "top right")
    }

    func testTheTransformPlacesTheQuadsInTheScene() throws {
        let runs = CoverageGeometry.runs(
            for: label("a", lines: [("a", .zero)],
                       transform: CGAffineTransform(translationX: 5, y: 7)),
            source: Squares()
        )
        XCTAssertEqual(corner(try XCTUnwrap(runs.first), quad: 0, 0), CGPoint(x: 5, y: 7))
    }

    func testColourCarriesTheCompositedAlpha() throws {
        let runs = CoverageGeometry.runs(
            for: label("a", lines: [("a", .zero)], alpha: 0.5,
                       colour: SKColor(red: 1, green: 0.5, blue: 0, alpha: 0.5)),
            source: Squares()
        )
        let run = try XCTUnwrap(runs.first)
        let tint = colour(run, quad: 0, 0)
        XCTAssertEqual(tint.0, 1)
        XCTAssertEqual(tint.1, 0.5)
        XCTAssertEqual(tint.2, 0)
        XCTAssertEqual(tint.3, 0.25, accuracy: 0.0001,
                       "the node's alpha and the colour's multiply, once")
    }

    func testAMaskIsOneQuadOverItsOwnBounds() {
        let run = CoverageGeometry.run(
            mask: CGRect(x: -5, y: -2, width: 10, height: 4),
            transform: CGAffineTransform(translationX: 100, y: 100),
            colour: SKColor(red: 0, green: 0, blue: 1, alpha: 1),
            alpha: 1
        )
        XCTAssertEqual(run.quadCount, 1)
        XCTAssertEqual(corner(run, quad: 0, 0), CGPoint(x: 95, y: 98))
        XCTAssertEqual(corner(run, quad: 0, 2), CGPoint(x: 105, y: 102))
        XCTAssertEqual(uv(run, quad: 0, 0), CGPoint(x: 0, y: 1), "row 0 is the mask's top")
        XCTAssertEqual(uv(run, quad: 0, 2), CGPoint(x: 1, y: 0))
    }

    /// Vertices are `Float`, so a texture coordinate that is a tenth comes
    /// back a hair off.
    private func assertPoint(
        _ got: CGPoint, _ want: CGPoint, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(got.x, want.x, accuracy: 1e-6, message, file: file, line: line)
        XCTAssertEqual(got.y, want.y, accuracy: 1e-6, message, file: file, line: line)
    }

    // MARK: Reading the interleaved vertices back

    private func floats(_ run: CoverageGeometry.Run, quad: Int, _ vertex: Int) -> [Float] {
        let stride = SpriteBatcher.floatsPerVertex
        let start = (quad * 4 + vertex) * stride
        return Array(run.vertices[start ..< start + stride])
    }

    private func corner(_ run: CoverageGeometry.Run, quad: Int, _ vertex: Int) -> CGPoint {
        let v = floats(run, quad: quad, vertex)
        return CGPoint(x: CGFloat(v[0]), y: CGFloat(v[1]))
    }

    private func uv(_ run: CoverageGeometry.Run, quad: Int, _ vertex: Int) -> CGPoint {
        let v = floats(run, quad: quad, vertex)
        return CGPoint(x: CGFloat(v[2]), y: CGFloat(v[3]))
    }

    private func colour(
        _ run: CoverageGeometry.Run, quad: Int, _ vertex: Int
    ) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let v = floats(run, quad: quad, vertex)
        return (CGFloat(v[4]), CGFloat(v[5]), CGFloat(v[6]), CGFloat(v[7]))
    }
}
