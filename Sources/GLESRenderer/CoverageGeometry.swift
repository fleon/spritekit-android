import Foundation
import SpriteKitShim

/// Quads whose texture is 8-bit coverage rather than colour: glyphs off the
/// atlas, and the masks the path rasteriser makes for shapes.
///
/// Both end up in the same vertex format as a sprite — `SpriteBatcher`'s
/// nine interleaved floats — so they share the vertex array, the buffers and
/// the attribute slots, and differ only in the fragment shader. That is why
/// this sits beside the batcher rather than inside the GL module: the
/// geometry is pure, so the awkward half (a Thai line's reordered marks
/// landing where they were measured) is testable on the Mac.
public enum CoverageGeometry {

    /// A run of coverage quads sharing one page of coverage.
    public struct Run {
        /// The atlas page these glyphs are on; `-1` for a one-off mask.
        public var page: Int
        public var vertices: [Float]
        public var indices: [UInt16]

        public var quadCount: Int { indices.count / 6 }
    }

    /// One glyph as the renderer needs it: where it is on its page, and
    /// where it goes on the line.
    public struct Glyph: Equatable {
        /// Index of the atlas page it was rasterised onto.
        public var page: Int
        /// Its rectangle on the page, in page pixels, origin top-left.
        public var rect: CGRect
        /// Where to draw it, in points, relative to the line's pen origin on
        /// the baseline, y up.
        public var frame: CGRect

        public init(page: Int, rect: CGRect, frame: CGRect) {
            self.page = page
            self.rect = rect
            self.frame = frame
        }
    }

    /// Where the glyphs of a line come from. The renderer's GL half supplies
    /// one backed by `TextShaping`; the tests supply a fake, which is the
    /// point of the seam.
    public protocol GlyphSource {
        /// Shaped and rasterised glyphs for one already-broken line.
        func glyphs(for line: String, font: FontKey) -> [Glyph]
        /// The page's size in pixels, for turning rects into texture
        /// coordinates. Nil for a page that does not exist.
        func pageSize(_ page: Int) -> CGSize?
    }

    // MARK: - Labels

    /// Turns a label into coverage quads, in page order.
    ///
    /// The lines are **not** measured again: `label.layout` is what the node
    /// broke, placed and reported as its `contentFrame`, both alignment
    /// modes already applied to each line's pen origin. Measuring here would
    /// be a second opinion, and the two would drift.
    public static func runs(for label: DrawList.Label, source: GlyphSource) -> [Run] {
        guard let layout = label.layout, !layout.lines.isEmpty else { return [] }
        let font = FontKey(name: label.fontName ?? "", size: label.fontSize)
        let colour = tint(label.color, alpha: label.alpha)

        var runs: [Int: Run] = [:]
        var order: [Int] = []

        for placed in layout.lines {
            for glyph in source.glyphs(for: placed.line.text, font: font) {
                guard let page = source.pageSize(glyph.page), page.width > 0, page.height > 0
                else { continue }

                let frame = glyph.frame.offsetBy(dx: placed.origin.x, dy: placed.origin.y)
                guard frame.width > 0, frame.height > 0 else { continue }

                if runs[glyph.page] == nil {
                    runs[glyph.page] = Run(page: glyph.page, vertices: [], indices: [])
                    order.append(glyph.page)
                }
                runs[glyph.page]!.append(
                    quad: frame,
                    uv: textureRect(of: glyph.rect, on: page),
                    transform: label.transform,
                    colour: colour
                )
            }
        }

        return order.compactMap { runs[$0] }
    }

    /// A glyph's rect on its page as texture coordinates.
    ///
    /// Pages are uploaded top row first, so v grows **down** the page and
    /// the quad's top edge takes `minY`. Flipping the UVs rather than the
    /// pixels keeps the upload a straight `glTexSubImage2D` of the atlas's
    /// own dirty rect.
    static func textureRect(of rect: CGRect, on page: CGSize) -> CGRect {
        CGRect(
            x: rect.minX / page.width,
            y: rect.minY / page.height,
            width: rect.width / page.width,
            height: rect.height / page.height
        )
    }

    // MARK: - Shapes

    /// One rasterised mask as a quad in the shape's own space.
    ///
    /// The mask was rasterised axis-aligned at the transform's own scale;
    /// drawing it through the transform is what puts any rotation back.
    public static func run(
        mask bounds: CGRect,
        transform: CGAffineTransform,
        colour: SKColor,
        alpha: CGFloat
    ) -> Run {
        var run = Run(page: -1, vertices: [], indices: [])
        run.append(
            quad: bounds,
            // Row 0 of a mask is its top, so v runs down it as it does for
            // an atlas page.
            uv: CGRect(x: 0, y: 0, width: 1, height: 1),
            transform: transform,
            colour: tint(colour, alpha: alpha)
        )
        return run
    }

    // MARK: - Shared

    /// rgb and the composited alpha, as `v_color_mix` carries them. The
    /// coverage shader multiplies the two and premultiplies, so a clear
    /// colour draws nothing rather than a black box.
    static func tint(_ colour: SKColor, alpha: CGFloat) -> [Float] {
        [
            Float(colour.red), Float(colour.green), Float(colour.blue),
            Float(colour.alpha * alpha),
            0,
        ]
    }
}

extension CoverageGeometry.Run {
    /// Appends one quad. `quad` is in the node's own space, `uv` has v
    /// growing down the page, so the quad's top-left corner takes
    /// `uv.minY` and its bottom-left takes `uv.maxY`.
    mutating func append(
        quad: CGRect,
        uv: CGRect,
        transform: CGAffineTransform,
        colour: [Float]
    ) {
        let corners = [
            CGPoint(x: quad.minX, y: quad.minY),
            CGPoint(x: quad.maxX, y: quad.minY),
            CGPoint(x: quad.maxX, y: quad.maxY),
            CGPoint(x: quad.minX, y: quad.maxY),
        ].map { $0.applying(transform) }

        let uvs = [
            CGPoint(x: uv.minX, y: uv.maxY),
            CGPoint(x: uv.maxX, y: uv.maxY),
            CGPoint(x: uv.maxX, y: uv.minY),
            CGPoint(x: uv.minX, y: uv.minY),
        ]

        let first = UInt16(vertices.count / SpriteBatcher.floatsPerVertex)
        for i in 0 ..< 4 {
            vertices.append(Float(corners[i].x))
            vertices.append(Float(corners[i].y))
            vertices.append(Float(uvs[i].x))
            vertices.append(Float(uvs[i].y))
            vertices.append(contentsOf: colour)
        }
        indices.append(contentsOf: [
            first, first + 1, first + 2,
            first, first + 2, first + 3,
        ])
    }
}
