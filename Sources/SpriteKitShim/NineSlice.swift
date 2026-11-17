#if SPRITEKIT_SHIM
import Foundation

// 9-slicing, which painted art drawn at any length needs before it looks
// right: a wall running the length of a stretch, or a panel stretched to
// its contents, is a sliced sprite whose corners must keep their size.
// Stretching the whole painting instead distorts it.
//
// It is done here, where a sprite flattens, rather than in the renderer:
// one sliced sprite becomes nine ordinary `DrawList.Sprite` commands, each
// with its own frame and its own sub-rect of the texture. So the draw list's
// shape does not change, the batcher needs no new case, and the nine quads
// batch with everything else on the same page.

extension SKSpriteNode {
    /// The stretchable middle of the texture, in unit texture coordinates
    /// with the origin at the bottom left — SpriteKit's own meaning. The
    /// default covers the whole texture, which is no slicing at all.
    ///
    /// A game sets this from its art's cap insets.
    public var centerRect: CGRect {
        get { sliceCenterRect }
        set { sliceCenterRect = newValue }
    }

    /// Whether this sprite is actually sliced: a centre rect covering the
    /// whole texture means it is not, and so does having no texture to take
    /// the border widths from.
    var isSliced: Bool {
        texture != nil && sliceCenterRect != NineSlice.whole
    }
}

enum NineSlice {
    static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// One slice of the grid: where it draws, and which part of the texture
    /// it samples.
    struct Patch {
        var frame: CGRect
        /// In unit texture coordinates within the sprite's own texture rect.
        var unit: CGRect
    }

    /// The nine patches for a sprite drawn into `frame` from a texture whose
    /// whole art is `textureSize` points, with `center` as its stretchable
    /// middle. Empty rows and columns are left out, so an image sliced only
    /// across gives three patches rather than nine with zero-height ones.
    ///
    /// When the frame is narrower (or shorter) than its two fixed borders,
    /// the borders are scaled down together to fit rather than overlapping,
    /// which is what SpriteKit does and keeps a shrunk slice from inverting.
    ///
    /// `base` is the sprite's own size before its scale: the borders are
    /// first fitted to it, then kept as they are while the scale stretches
    /// the middle (and fitted again only if the scaled frame is smaller
    /// still). That is SpriteKit's: an 8-point dot drawn from a 16-point
    /// texture and stretched 3× across is a pill with round ends, the caps
    /// fitted to the dot, not to the texture.
    static func patches(frame: CGRect, textureSize: CGSize, center: CGRect, base: CGSize? = nil) -> [Patch] {
        guard textureSize.width > 0, textureSize.height > 0 else { return [] }

        var fixed = (
            left: center.minX * textureSize.width,
            right: (1 - center.maxX) * textureSize.width,
            bottom: center.minY * textureSize.height,
            top: (1 - center.maxY) * textureSize.height
        )
        if let base {
            (fixed.left, fixed.right) = borders(fixed.left, fixed.right, within: base.width)
            (fixed.bottom, fixed.top) = borders(fixed.bottom, fixed.top, within: base.height)
        }
        let horizontal = borders(fixed.left, fixed.right, within: frame.width)
        let vertical = borders(fixed.bottom, fixed.top, within: frame.height)

        // Column and row spans in the frame, and the unit coordinates each
        // samples. The middle takes whatever the borders leave.
        let columns = spans(
            frame.minX,
            [horizontal.0, frame.width - horizontal.0 - horizontal.1, horizontal.1],
            [0, center.minX, center.maxX, 1]
        )
        let rows = spans(
            frame.minY,
            [vertical.0, frame.height - vertical.0 - vertical.1, vertical.1],
            [0, center.minY, center.maxY, 1]
        )

        var patches: [Patch] = []
        for row in rows {
            for column in columns {
                patches.append(Patch(
                    frame: CGRect(x: column.start, y: row.start, width: column.length, height: row.length),
                    unit: CGRect(x: column.from, y: row.from, width: column.to - column.from, height: row.to - row.from)
                ))
            }
        }
        return patches
    }

    /// `first` and `second` as they fit in `total`: both as authored when
    /// there is room, scaled down together when there is not.
    private static func borders(_ first: CGFloat, _ second: CGFloat, within total: CGFloat) -> (CGFloat, CGFloat) {
        let sum = first + second
        guard sum > total, sum > 0 else { return (first, second) }
        let scale = max(total, 0) / sum
        return (first * scale, second * scale)
    }

    private struct Span {
        var start: CGFloat
        var length: CGFloat
        var from: CGFloat
        var to: CGFloat
    }

    /// Three spans laid end to end from `origin`, each sampling between two
    /// of the four unit edges. Spans with no length are dropped.
    private static func spans(_ origin: CGFloat, _ lengths: [CGFloat], _ edges: [CGFloat]) -> [Span] {
        var spans: [Span] = []
        var cursor = origin
        for index in 0 ..< 3 {
            let length = lengths[index]
            guard length > 0 else { continue }
            spans.append(Span(start: cursor, length: length, from: edges[index], to: edges[index + 1]))
            cursor += length
        }
        return spans
    }

    /// A sub-rect of `rect` in its own unit coordinates.
    static func within(_ rect: CGRect, _ unit: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + unit.minX * rect.width,
            y: rect.minY + unit.minY * rect.height,
            width: unit.width * rect.width,
            height: unit.height * rect.height
        )
    }
}

#endif
