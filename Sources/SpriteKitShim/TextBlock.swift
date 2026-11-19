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
    func glyphMasks(_ text: String, font: FontKey, scale: CGFloat, offset: CGPoint, positionsPerPixel: Int) -> [GlyphMask] { [] }
    func characterAdvances(_ text: String, font: FontKey) -> [CGFloat] {
        text.map { measure(String($0), font: font).advance }
    }
    /// No outlines where the provider has none: stroked text draws nothing.
    func glyphOutline(_ text: String, font: FontKey) -> [PathElement] { [] }
}

/// Text laid out as UIKit's string drawing lays it out
/// (`NSAttributedString.boundingRect(with:options:context:)` and
/// `draw(in:)`), pinned against UIKit on Mac Catalyst
/// (`StringDrawingParityTests`):
///
///   - **Runs**: each run of attributes in its own font, colour, letter
///     spacing and baseline offset; a paragraph takes its style (alignment,
///     wrapping, line spacing) from its first run.
///   - **Breaking**: each paragraph broken to the width, at the places the
///     text allows, the spaces a line ends on hanging past its edge; a word
///     wider than a line, by character. With `.characters` wrapping, as many
///     characters as fit, spaces counted like the rest: one that doesn't fit
///     starts the next line (CoreText's framesetter, which `boundingRect`
///     agrees with where UIKit's layout manager doesn't).
///   - **Lines**: as tall as the largest rounded ascent (raised by a run's
///     baseline offset) plus the largest rounded descent of their runs, and
///     the largest leading, unrounded, with `.usesFontLeading`; the
///     paragraph's line spacing between one line and the next.
///   - **Width**: each line placed across the width by its alignment (by
///     its width without trailing spaces; a justified line but a
///     paragraph's last spans the width), the block as wide as all the
///     placed lines, trailing spaces included, but no wider than the width.
///   - **Drawing**: only the lines that fit wholly in the rect; each
///     baseline down to the next whole device pixel, each glyph's x floored
///     to the sub-pixel step its size allows (`positionsPerPixel`), as
///     UIKit places them whatever `setShouldSubpixelQuantizeFonts` says.
public struct TextBlock {
    public enum Alignment: Sendable {
        case left, center, right, justified
    }

    public enum Wrapping: Sendable {
        case words, characters
    }

    /// A paragraph's style (`NSParagraphStyle`).
    public struct Style: Equatable, Sendable {
        public var alignment: Alignment
        public var wrapping: Wrapping
        public var lineSpacing: CGFloat

        public init(alignment: Alignment = .left, wrapping: Wrapping = .words, lineSpacing: CGFloat = 0) {
            self.alignment = alignment
            self.wrapping = wrapping
            self.lineSpacing = lineSpacing
        }
    }

    /// A stretch of text in one set of attributes.
    public struct Run {
        public var text: String
        public var font: FontKey
        public var colour: SKColor
        public var kern: CGFloat
        public var baselineOffset: CGFloat
        public var style: Style

        public init(_ text: String, font: FontKey, colour: SKColor = .black, kern: CGFloat = 0,
                    baselineOffset: CGFloat = 0, style: Style = Style()) {
            self.text = text
            self.font = font
            self.colour = colour
            self.kern = kern
            self.baselineOffset = baselineOffset
            self.style = style
        }
    }

    /// A line's stretch of one run.
    public struct Piece: Equatable, Sendable {
        public var run: Int
        public var text: String
        /// From the line's start, in points.
        public var x: CGFloat
        public var width: CGFloat
    }

    public struct Line: Equatable, Sendable {
        public var pieces: [Piece]
        /// With the spaces it ends on.
        public var width: CGFloat
        /// Without them.
        public var visibleWidth: CGFloat
        public var ascent: CGFloat
        public var descent: CGFloat
        public var leading: CGFloat
        public var style: Style
        public var endsParagraph: Bool
        /// The spaces before its last visible character, which justifying
        /// widens.
        public var spaces: Int

        public var height: CGFloat { ascent + descent + leading }
    }

    public let runs: [Run]
    public let lines: [Line]

    /// One run of `text` in `font`.
    public init?(_ text: String, font: FontKey, maxWidth: CGFloat?, usesFontLeading: Bool = false, style: Style = Style()) {
        self.init(runs: [Run(text, font: font, style: style)], maxWidth: maxWidth, usesFontLeading: usesFontLeading)
    }

    /// Nil with no provider or no run whose face is known. `maxWidth` nil
    /// lays each paragraph on one line.
    public init?(runs: [Run], maxWidth: CGFloat?, usesFontLeading: Bool = false) {
        guard let provider = TextMetrics.provider, !runs.isEmpty,
              runs.contains(where: { provider.fontMetrics($0.font) != nil }) else { return nil }
        self.runs = runs
        var lines: [Line] = []
        for paragraph in Self.paragraphs(of: runs) {
            lines += Self.lay(paragraph, runs: runs, provider: provider, maxWidth: maxWidth, usesFontLeading: usesFontLeading)
        }
        self.lines = lines
    }

    // MARK: Measuring

    /// The used rect's size, its lines placed across `width` (each line's
    /// own width where there's none).
    public func size(in width: CGFloat?) -> CGSize {
        let height = lines.enumerated().reduce(CGFloat(0)) { total, item in
            total + item.element.height + (item.offset < lines.count - 1 ? item.element.style.lineSpacing : 0)
        }
        guard let width else {
            return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
        }
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        for line in lines {
            let x = Self.offset(of: line, in: width)
                // A justified line but its paragraph's last spans the width.
            let end = line.style.alignment == .justified && !line.endsParagraph ? width : x + line.width
            minX = min(minX, x)
            maxX = max(maxX, end)
        }
        guard minX <= maxX else { return CGSize(width: 0, height: height) }
        return CGSize(width: min(width, maxX - minX), height: height)
    }

    /// `NSAttributedString.boundingRect(with:options:context:)` for `runs`:
    /// with `.usesLineFragmentOrigin`, the text wrapped to `size.width`, its
    /// lines placed by their alignment; without, its first line alone,
    /// measured from its baseline (y its rounded descent up) and no wider
    /// than `size.width`. The origin is zero across.
    public static func boundingRect(
        of runs: [Run], size: CGSize, usesLineFragmentOrigin: Bool, usesFontLeading: Bool
    ) -> CGRect {
        guard usesLineFragmentOrigin else {
            var first: [Run] = []
            for run in runs {
                if let newline = run.text.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
                    var cut = run
                    cut.text = String(run.text[..<newline])
                    first.append(cut)
                    break
                }
                first.append(run)
            }
            guard let block = TextBlock(runs: first, maxWidth: nil, usesFontLeading: usesFontLeading),
                  let line = block.lines.first else { return .zero }
            return CGRect(x: 0, y: -line.descent, width: min(size.width, line.width), height: line.height)
        }
        guard let block = TextBlock(runs: runs, maxWidth: size.width, usesFontLeading: usesFontLeading) else { return .zero }
        return CGRect(origin: .zero, size: block.size(in: size.width))
    }

    /// Where a line starts across `width`.
    static func offset(of line: Line, in width: CGFloat) -> CGFloat {
        switch line.style.alignment {
        case .left: 0
        case .justified: 0
        case .center: (width - line.visibleWidth) / 2
        case .right: width - line.visibleWidth
        }
    }

    static func justifies(_ line: Line) -> Bool {
        line.style.alignment == .justified && !line.endsParagraph && line.spaces > 0
    }

    // MARK: Laying out

    /// A paragraph's characters, each with its run; `empty` the run an
    /// empty paragraph takes its height from.
    private struct Paragraph {
        var characters: [Character] = []
        var runOf: [Int] = []
        var empty: Int
    }

    private static func paragraphs(of runs: [Run]) -> [Paragraph] {
        var paragraphs: [Paragraph] = [Paragraph(empty: 0)]
        for (index, run) in runs.enumerated() {
            if paragraphs[paragraphs.count - 1].characters.isEmpty { paragraphs[paragraphs.count - 1].empty = index }
            for character in run.text {
                if character == "\n" || character == "\r\n" {
                    paragraphs.append(Paragraph(empty: index))
                    continue
                }
                paragraphs[paragraphs.count - 1].characters.append(character)
                paragraphs[paragraphs.count - 1].runOf.append(index)
            }
        }
        return paragraphs
    }

    private static func lay(
        _ paragraph: Paragraph, runs: [Run], provider: TextProvider, maxWidth: CGFloat?, usesFontLeading: Bool
    ) -> [Line] {
        let characters = paragraph.characters
        let style = runs[paragraph.runOf.first ?? paragraph.empty].style
        func groups(_ a: Int, _ b: Int) -> [(Int, Range<Int>)] {
            var out: [(Int, Range<Int>)] = []
            var start = a
            for index in a ..< b where index == b - 1 || paragraph.runOf[index + 1] != paragraph.runOf[index] {
                out.append((paragraph.runOf[index], start ..< index + 1))
                start = index + 1
            }
            return out
        }
        // Each character's advance, each run's stretch of the paragraph
        // shaped whole, as the text system shapes it before breaking.
        var advances: [CGFloat] = []
        for (run, range) in groups(0, characters.count) {
            let shaped = provider.characterAdvances(String(characters[range]), font: runs[run].font)
            for offset in 0 ..< range.count {
                advances.append((offset < shaped.count ? shaped[offset] : 0) + runs[run].kern)
            }
        }
        // The width of characters a..<b.
        func width(_ a: Int, _ b: Int) -> CGFloat {
            guard a < b else { return 0 }
            return advances[a ..< b].reduce(0, +)
        }
        func visibleEnd(_ a: Int, _ b: Int) -> Int {
            var end = b
            while end > a, characters[end - 1].isWhitespace { end -= 1 }
            return end
        }

        // Where a line may start: the text's break opportunities, by
        // character, or every character under character wrapping.
        let text = String(characters)
        var starts: [Int] = []
        if style.wrapping == .words {
            var utf16 = 0, index = 0
            let offsets = Set(provider.breakOffsets(in: text))
            for character in characters {
                if offsets.contains(utf16), index > 0 { starts.append(index) }
                utf16 += character.utf16.count
                index += 1
            }
        } else {
            starts = Array(1 ..< max(1, characters.count))
        }

        var ranges: [Range<Int>] = []
        var start = 0
        while start < characters.count {
            guard let maxWidth else {
                ranges.append(start ..< characters.count)
                break
            }
            if style.wrapping == .characters {
                // As many characters as fit, spaces included (they don't hang:
                // one that doesn't fit starts the next line), one at least.
                var end = start + 1
                while end < characters.count, width(start, end + 1) <= maxWidth { end += 1 }
                ranges.append(start ..< end)
                start = end
                continue
            }
            var end: Int?
            for candidate in starts.filter({ $0 > start }) + [characters.count] {
                if width(start, visibleEnd(start, candidate)) <= maxWidth { end = candidate } else { break }
            }
            if end == nil {
                // Wider than the line on its own: as many characters as fit, one at least.
                end = start + 1
                while end! < characters.count, width(start, visibleEnd(start, end! + 1)) <= maxWidth { end! += 1 }
            }
            ranges.append(start ..< end!)
            start = end!
        }
        if ranges.isEmpty { ranges = [0 ..< 0] }

        return ranges.enumerated().map { index, range in
            let visible = visibleEnd(range.lowerBound, range.upperBound)
            let pieces = groups(range.lowerBound, range.upperBound).map { run, piece in
                Piece(run: run, text: String(characters[piece]), x: width(range.lowerBound, piece.lowerBound),
                      width: width(piece.lowerBound, piece.upperBound))
            }
            let present = pieces.isEmpty ? [paragraph.empty] : Array(Set(pieces.map(\.run))).sorted()
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            for run in present {
                guard let metrics = provider.fontMetrics(runs[run].font) else { continue }
                let offset = runs[run].baselineOffset
                ascent = max(ascent, metrics.ascent.rounded() + max(0, offset))
                descent = max(descent, metrics.descent.rounded() - min(0, offset))
                if usesFontLeading { leading = max(leading, metrics.leading) }
            }
            return Line(
                pieces: pieces,
                width: width(range.lowerBound, range.upperBound),
                visibleWidth: width(range.lowerBound, visible),
                ascent: ascent, descent: descent, leading: leading,
                style: style,
                endsParagraph: index == ranges.count - 1,
                spaces: characters[range.lowerBound ..< visible].filter { $0 == " " }.count
            )
        }
    }

    // MARK: Drawing

    /// UIKit's glyph x step at a size in pixels: a fifth of a pixel for the
    /// smallest, whole pixels from about 33 (measured on Catalyst, the same
    /// for every face tried).
    public static func positionsPerPixel(forPixelSize size: CGFloat) -> Int {
        switch size {
        case ..<8.25: 5
        case ..<11.25: 4
        case ..<16.75: 3
        case ..<33.25: 2
        default: 1
        }
    }

    /// Draws the lines that fit wholly in `rect` into `context`, whose user
    /// space is UIKit's (y down, as a context UIKit hands over is), in its
    /// text drawing mode.
    public func draw(in rect: CGRect, context: BitmapContext) {
        guard let provider = TextMetrics.provider else { return }
        let mode = context.textDrawingMode
        guard mode.fills || mode.strokes else { return }
        let ctm = context.ctm
        // Axis-aligned only, as text is drawn here: no rotation or shear.
        guard ctm.b == 0, ctm.c == 0, ctm.a > 0, ctm.d != 0 else { return }
        let scale = ctm.a
        // Whether up on the page (toward the ascent, -y in UIKit's space) is
        // up in memory too (toward row 0). In a context that isn't flipped
        // for UIKit, text comes out upside down, as UIKit draws it there.
        let upright = ctm.d > 0
        var top = rect.minY
        for line in lines {
            guard top + line.height <= rect.maxY + 0.0001 else { break }
            defer { top += line.height + line.style.lineSpacing }
            let start = rect.minX + Self.offset(of: line, in: rect.width)
            let stretch = Self.justifies(line) ? (rect.width - line.visibleWidth) / CGFloat(line.spaces) : 0
            var spacesBefore = 0
            for piece in line.pieces {
                let run = runs[piece.run]
                // Justified text widens its spaces; letter spacing places each character.
                let parts: [(String, CGFloat)] = if stretch > 0 || run.kern != 0 {
                    Self.split(piece.text, run: run, byCharacter: run.kern != 0, provider: provider)
                } else {
                    [(piece.text, 0)]
                }
                for (text, offset) in parts {
                    let x = start + piece.x + offset + stretch * CGFloat(spacesBefore)
                    spacesBefore += text.filter { $0 == " " }.count
                    guard !text.allSatisfy(\.isWhitespace) else { continue }
                    let baseline = top + line.ascent - run.baselineOffset
                    draw(text, run: run, at: CGPoint(x: x, y: baseline), mode: mode, upright: upright,
                         scale: scale, ctm: ctm, provider: provider, context: context)
                }
            }
        }
    }

    /// A piece cut into words (spaces kept with the word before) or
    /// characters, each with its x from the piece's start.
    private static func split(_ text: String, run: Run, byCharacter: Bool, provider: TextProvider) -> [(String, CGFloat)] {
        var parts: [String] = []
        for character in text {
            if byCharacter || parts.isEmpty || parts[parts.count - 1].last == " " {
                parts.append(String(character))
            } else {
                parts[parts.count - 1].append(character)
            }
        }
        var x: CGFloat = 0
        return parts.map { part in
            defer { x += provider.measure(part, font: run.font).advance + run.kern * CGFloat(part.count) }
            return (part, x)
        }
    }

    private func draw(
        _ text: String, run: Run, at point: CGPoint, mode: BitmapContext.TextDrawingMode, upright: Bool,
        scale: CGFloat, ctm: CGAffineTransform, provider: TextProvider, context: BitmapContext
    ) {
        let device = point.applying(ctm)
        // The baseline down the page to the next whole pixel.
        let baseline = upright ? (device.y - 0.0001).rounded(.up) : (device.y + 0.0001).rounded(.down)
        if mode.fills {
            let column = device.x.rounded(.down)
            // The pen in glyph space (y up, in pixels).
            let row = upright ? -baseline : baseline
            let masks = provider.glyphMasks(
                text, font: run.font, scale: scale, offset: CGPoint(x: device.x - column, y: 0),
                positionsPerPixel: Self.positionsPerPixel(forPixelSize: run.font.size * scale)
            )
            for mask in masks {
                let left = Int(column) + Int(mask.origin.x)
                let top = Int(row) + Int(mask.origin.y)
                context.fillMask(
                    mask.coverage, width: mask.width, height: mask.height,
                    // Row 0 of the mask is its top: `top - 1` up in glyph space.
                    atDeviceX: left, y: upright ? -top : top - 1, rowsDown: upright,
                    colour: run.colour
                )
            }
        }
        if mode.strokes {
            let outline = provider.glyphOutline(text, font: run.font)
            guard !outline.isEmpty else { return }
            // Back into user space, on the snapped baseline.
            let origin = CGPoint(x: point.x, y: (baseline - ctm.ty) / ctm.d)
            func place(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x, y: origin.y - p.y) }
            context.saveGState()
            context.setStroke(run.colour)
            context.beginPath()
            for element in outline {
                switch element {
                case let .move(p): context.move(to: place(p))
                case let .line(p): context.addLine(to: place(p))
                case let .quadCurve(to, control): context.addQuadCurve(to: place(to), control: place(control))
                case let .curve(to, c1, c2): context.addCurve(to: place(to), control1: place(c1), control2: place(c2))
                case .close: context.closePath()
                case .arc: break
                }
            }
            context.strokePath()
            context.restoreGState()
        }
    }
}
#endif
