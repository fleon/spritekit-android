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

    /// A label or shape made into its runs ahead of drawing, so the frame
    /// writes them into its stream with everything else.
    public struct Staged {
        public enum Origin {
            case label(DrawList.Label)
            case shape(DrawList.Shape)
        }

        public struct Part {
            public var run: Run
            /// A shape's mask texture; 0 for glyphs, whose page `run` names.
            public var mask: UInt32
            /// Where its indices start in the frame's stream; -1 until written.
            public var streamFirstIndex: Int = -1

            public init(run: Run, mask: UInt32) {
                self.run = run
                self.mask = mask
            }
        }

        /// What it was: drawn afresh wherever it isn't in the stream (a kept
        /// target drawn again in a later frame, whose masks may be gone).
        public var origin: Origin
        public var parts: [Part]

        public init(origin: Origin, parts: [Part]) {
            self.origin = origin
            self.parts = parts
        }

        public var isStaged: Bool { !parts.isEmpty && parts.allSatisfy { $0.streamFirstIndex >= 0 } }
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
        /// The UTF-8 offset in the line of the character it came from
        /// (HarfBuzz's cluster), for letter spacing.
        public var cluster: Int

        public init(page: Int, rect: CGRect, frame: CGRect, cluster: Int = 0) {
            self.page = page
            self.rect = rect
            self.frame = frame
            self.cluster = cluster
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
            let characterStarts = label.kern == 0 ? [] : Self.characterStarts(placed.line.text)
            for glyph in source.glyphs(for: placed.line.text, font: font) {
                guard let page = source.pageSize(glyph.page), page.width > 0, page.height > 0
                else { continue }

                // Letter spacing (an attributed label's `.kern`): each
                // character moves on by the spacing of every one before it.
                let spacing = label.kern == 0 ? 0
                    : label.kern * CGFloat(characterStarts.lastIndex { $0 <= glyph.cluster } ?? 0)
                let frame = glyph.frame.offsetBy(dx: placed.origin.x + spacing, dy: placed.origin.y)
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

    /// Where each character of `text` starts, as UTF-8 offsets (glyphs'
    /// clusters are counted in those).
    static func characterStarts(_ text: String) -> [Int] {
        var starts: [Int] = []
        var offset = 0
        for character in text {
            starts.append(offset)
            offset += character.utf8.count
        }
        return starts
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

    /// Where a shape's texture is sampled from a mask's texture coordinate:
    /// `fill = map.xy + mask * map.zw`. The texture is stretched over the
    /// path's bounds (top row at the top, as an image is uploaded); the mask
    /// covers `mask` (its row 0 at the top as well), which is the path's
    /// bounds and the stroke's reach, so the texture runs a little past 0…1
    /// at its edges and clamps there.
    public static func fillMap(mask: CGRect, path: CGRect) -> SIMD4<Float> {
        guard path.width > 0, path.height > 0 else { return SIMD4(0, 0, 0, 0) }
        return SIMD4(
            Float((mask.minX - path.minX) / path.width),
            Float((path.maxY - mask.maxY) / path.height),
            Float(mask.width / path.width),
            Float(mask.height / path.height)
        )
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
