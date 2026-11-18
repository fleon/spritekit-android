#if SPRITEKIT_SHIM
import Foundation

/// One glyph's 8-bit coverage, rasterised at a scale for drawing into a
/// bitmap (`NSAttributedString.draw(in:)`).
///
/// `origin` is the bitmap's top-left in **pixels**, y up, from the whole
/// pixel the line's pen starts in; `coverage` is `width × height` bytes,
/// rows top first.
public struct GlyphMask: Equatable, Sendable {
    public var origin: CGPoint
    public var width: Int
    public var height: Int
    public var coverage: [UInt8]

    public init(origin: CGPoint, width: Int, height: Int, coverage: [UInt8]) {
        self.origin = origin
        self.width = width
        self.height = height
        self.coverage = coverage
    }
}

public extension TextProvider {
    /// No masks where the provider can't rasterise: text draws nothing.
    func glyphMasks(_ text: String, font: FontKey, scale: CGFloat, offset: CGPoint) -> [GlyphMask] { [] }
}

/// Text laid out as UIKit's string drawing lays it out
/// (`NSAttributedString.boundingRect(with:options:context:)` and
/// `draw(in:)`), for one font, pinned against AppKit's on the same files
/// (`StringDrawingParityTests`): each paragraph broken to the width it's
/// given; lines the rounded ascent plus the rounded descent apart (and the
/// rounded leading, with `.usesFontLeading`), each baseline the rounded
/// ascent below its line's top; the block as wide as its widest line,
/// trailing spaces and all, but no wider than the width it was broken to.
public struct TextBlock: Equatable, Sendable {
    public enum Alignment: Sendable {
        case left, center, right
    }

    public struct Line: Equatable, Sendable {
        public var text: String
        /// What the line counts toward the block's width.
        public var width: CGFloat
        /// Without its trailing spaces, which hang past an aligned line's end.
        public var visibleWidth: CGFloat
    }

    public let font: FontKey
    public let lines: [Line]
    public let ascent: CGFloat
    /// From one baseline to the next.
    public let lineHeight: CGFloat

    /// The used rect's size: the widest line by every line's height.
    public var size: CGSize {
        CGSize(width: lines.map(\.width).max() ?? 0, height: CGFloat(lines.count) * lineHeight)
    }

    /// Nil with no provider or an unknown face. `maxWidth` nil lays each
    /// paragraph on one line.
    public init?(_ text: String, font: FontKey, maxWidth: CGFloat?, usesFontLeading: Bool = false) {
        guard let provider = TextMetrics.provider, let metrics = provider.fontMetrics(font) else { return nil }
        self.font = font
        ascent = metrics.ascent.rounded()
        lineHeight = ascent + metrics.descent.rounded() + (usesFontLeading ? metrics.leading.rounded() : 0)
        var lines: [Line] = []
        for paragraph in text.components(separatedBy: "\n") {
            let broken = maxWidth.map { provider.breakLines(paragraph, font: font, maxWidth: $0) } ?? [paragraph]
            // The breaker drops the spaces a line broke at; AppKit counts
            // them in the line's width, so they're found again here.
            var cursor = paragraph.startIndex
            for line in broken.isEmpty ? [""] : broken {
                var counted = line
                if let found = paragraph.range(of: line, range: cursor ..< paragraph.endIndex) {
                    cursor = found.upperBound
                    while cursor < paragraph.endIndex, paragraph[cursor] == " " || paragraph[cursor] == "\t" {
                        counted.append(paragraph[cursor])
                        cursor = paragraph.index(after: cursor)
                    }
                }
                let advance = counted.isEmpty ? 0 : provider.measure(counted, font: font).advance
                let visible = String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
                lines.append(Line(
                    text: line,
                    width: maxWidth.map { min(advance, $0) } ?? advance,
                    visibleWidth: visible.isEmpty ? 0 : provider.measure(visible, font: font).advance
                ))
            }
        }
        self.lines = lines
    }

    /// Draws the lines into `context`, laid out in `rect` of its user space,
    /// which is UIKit's (y down, as a context UIKit hands over is): the first
    /// baseline an ascent below the top, each line placed across the rect's
    /// width by `alignment`.
    public func draw(in rect: CGRect, alignment: Alignment, colour: SKColor, context: BitmapContext) {
        guard let provider = TextMetrics.provider else { return }
        let ctm = context.ctm
        // Axis-aligned only, as text is drawn here: no rotation or shear.
        guard ctm.b == 0, ctm.c == 0, ctm.a > 0, ctm.d != 0 else { return }
        let scale = ctm.a
        // Whether up on the page (toward the ascent, -y in UIKit's space) is
        // up in memory too (toward row 0). In a context that isn't flipped
        // for UIKit, text comes out upside down, as UIKit draws it there.
        let upright = ctm.d > 0
        for (index, line) in lines.enumerated() where !line.text.isEmpty {
            let x: CGFloat = switch alignment {
            case .left: rect.minX
            case .center: rect.minX + (rect.width - line.visibleWidth) / 2
            case .right: rect.maxX - line.visibleWidth
            }
            let pen = CGPoint(x: x, y: rect.minY + ascent + CGFloat(index) * lineHeight).applying(ctm)
            let column = pen.x.rounded(.down)
            // The pen in glyph space (y up, in pixels), split into whole pixels and the rest.
            let up = upright ? -pen.y : pen.y
            let row = up.rounded(.down)
            let masks = provider.glyphMasks(line.text, font: font, scale: scale,
                                            offset: CGPoint(x: pen.x - column, y: up - row))
            for mask in masks {
                let left = Int(column) + Int(mask.origin.x)
                let top = Int(row) + Int(mask.origin.y)
                context.fillMask(
                    mask.coverage, width: mask.width, height: mask.height,
                    // Row 0 of the mask is its top: `top - 1` up in glyph space.
                    atDeviceX: left, y: upright ? -top : top - 1, rowsDown: upright,
                    colour: colour
                )
            }
        }
    }
}
#endif
