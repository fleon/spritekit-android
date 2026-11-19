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
    /// A colour glyph's own pixels (emoji), premultiplied RGBA, drawn as
    /// they are rather than in the text's colour; nil for a plain glyph.
    public var colour: [UInt8]?

    public init(origin: CGPoint, width: Int, height: Int, coverage: [UInt8], colour: [UInt8]? = nil) {
        self.origin = origin
        self.width = width
        self.height = height
        self.coverage = coverage
        self.colour = colour
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
    func glyphOutlines(_ text: String, font: FontKey) -> [GlyphOutline] {
        [GlyphOutline(origin: .zero, elements: glyphOutline(text, font: font))]
    }
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
///     Justified, a line takes one more word if giving up a fifth of each
///     of its spaces makes it fit, and is drawn with its spaces squeezed.
///   - **Drawing**: only the lines that fit wholly in the rect; each
///     baseline down to the next whole device pixel, each glyph's x floored
///     to the sub-pixel step its size allows (`positionsPerPixel`), as
///     UIKit places them whatever `setShouldSubpixelQuantizeFonts` says.
public struct TextBlock {
    public enum Alignment: Sendable {
        /// `natural`: the app's direction's, which for these games is left,
        /// even for a right-to-left paragraph (measured on Catalyst).
        case left, center, right, justified, natural
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
        /// In a right-to-left paragraph: the spaces it ends on hang past its
        /// left edge (`Bidi`).
        public var rightToLeft = false

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
            if line.rightToLeft {
                // A right-to-left line's spaces hang past its left edge, no
                // further than the rect's (measured on Catalyst).
                minX = min(minX, max(0, x - (line.width - line.visibleWidth)))
                maxX = max(maxX, x + line.visibleWidth)
                continue
            }
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
    /// measured from its baseline (y its rounded descent, and the leading
    /// with `.usesFontLeading`, up) and no wider
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
            return CGRect(x: 0, y: -(line.descent + line.leading), width: min(size.width, line.width), height: line.height)
        }
        guard let block = TextBlock(runs: runs, maxWidth: size.width, usesFontLeading: usesFontLeading) else { return .zero }
        return CGRect(origin: .zero, size: block.size(in: size.width))
    }

    /// Where a line starts across `width`.
    static func offset(of line: Line, in width: CGFloat) -> CGFloat {
        switch line.style.alignment {
        case .left: 0
        case .justified: 0
        case .natural: 0
        case .center: (width - line.visibleWidth) / 2
        case .right: width - line.visibleWidth
        }
    }

    /// The share of each space a justified line may give up to fit.
    static let justifiedSqueeze: CGFloat = 0.2

    /// Whether a line's spaces are stretched (or squeezed) to the width: a
    /// justified line's but its paragraph's last, and any justified line
    /// that was squeezed to fit.
    static func justifies(_ line: Line, in width: CGFloat) -> Bool {
        line.style.alignment == .justified && line.spaces > 0 && (!line.endsParagraph || line.visibleWidth > width)
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
        // How much a justified line may tighten to take one more word: a
        // fifth of each space's width, under word wrapping only (measured
        // on Catalyst).
        func squeeze(_ a: Int, _ b: Int) -> CGFloat {
            guard style.alignment == .justified, style.wrapping == .words, a < b else { return 0 }
            return (a ..< b).reduce(CGFloat(0)) { $0 + (characters[$1] == " " ? advances[$1] * Self.justifiedSqueeze : 0) }
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
        if let maxWidth, style.alignment == .justified, style.wrapping == .words,
           let balanced = balancedBreaks(starts: starts, count: characters.count, maxWidth: maxWidth,
                                         width: width, squeeze: squeeze, visibleEnd: visibleEnd,
                                         isSpace: { characters[$0] == " " }) {
            ranges = balanced
            start = characters.count
        }
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
                let visible = visibleEnd(start, candidate)
                if width(start, visible) - squeeze(start, visible) <= maxWidth { end = candidate } else { break }
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

        // A paragraph with right-to-left text in it: each line's visible
        // characters in the order drawn (`Bidi.segments`), a piece per run
        // and level, each in its own direction; then the spaces it ends on,
        // at its right end, where they draw nothing.
        let direction: Bidi.Direction? = Bidi.needsReordering(text) ? Bidi.direction(of: text) : nil
        return ranges.enumerated().map { index, range in
            let visible = visibleEnd(range.lowerBound, range.upperBound)
            var pieces = groups(range.lowerBound, range.upperBound).map { run, piece in
                Piece(run: run, text: String(characters[piece]), x: width(range.lowerBound, piece.lowerBound),
                      width: width(piece.lowerBound, piece.upperBound))
            }
            if let direction {
                let shown = groups(range.lowerBound, visible)
                var x: CGFloat = 0
                pieces = []
                func place(_ run: Int, _ a: Int, _ b: Int, _ text: String) {
                    guard a < b else { return }
                    pieces.append(Piece(run: run, text: text, x: x, width: width(a, b)))
                    x += width(a, b)
                }
                for segment in Bidi.segments(of: shown.map { String(characters[$0.1]) }, in: direction) {
                    let (run, piece) = shown[segment.piece]
                    let a = piece.lowerBound + segment.characters.lowerBound, b = piece.lowerBound + segment.characters.upperBound
                    guard segment.rightToLeft else {
                        place(run, a, b, Bidi.marked(String(characters[a ..< b]), in: .leftToRight))
                        continue
                    }
                    // Right to left, the spaces a stretch ends on are on its left.
                    let body = visibleEnd(a, b)
                    place(run, body, b, String(characters[body ..< b]))
                    // Always led by its mark, which draws nothing, so drawing
                    // knows to place its words right to left.
                    place(run, a, body, "\u{200F}" + String(characters[a ..< body]))
                }
                for (run, piece) in groups(visible, range.upperBound) {
                    place(run, piece.lowerBound, piece.upperBound, String(characters[piece]))
                }
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
                spaces: characters[range.lowerBound ..< visible].filter { $0 == " " }.count,
                rightToLeft: direction == .rightToLeft
            )
        }
    }

    /// What breaking a word between two characters costs a justified
    /// paragraph where it isn't forced (fitted to TextKit 2's breaks: the
    /// same from 4,000 to 6,000).
    private static let voluntaryBreakCost: CGFloat = 5_000

    /// A justified paragraph's lines as UIKit's text system breaks them
    /// (TextKit 2, which UIKit's string drawing is), chosen for the whole
    /// paragraph rather than line by line: the breaks that make the
    /// paragraph cheapest, a justified line costing the cube of how far its
    /// spaces stretch (or squeeze, by up to a fifth) for its width, a line
    /// of one word costing more the emptier it is, steeply, and the last
    /// line nothing. Fitted to TextKit 2's breaks on Catalyst, and checked
    /// over 6,500 layouts where every word fits (four faces, five sizes,
    /// nine sentences, six of them not seen while fitting, widths from 90
    /// to 300 points), it matches 98% of them exactly, where breaking line
    /// by line matched 78%.
    ///
    /// Where a word is wider than the line, any word in the paragraph may
    /// also break between two characters, the line then taking as many as
    /// fit: free where the word is too wide and starts the line, otherwise
    /// at a cost (`voluntaryBreakCost`), which TextKit 2 pays to spare a line
    /// holding only the last letters of a broken word ("y unbreakab|le").
    /// Over 520 such layouts it matches 88% of TextKit 2's lines exactly,
    /// where breaking line by line matched 55%. Nil if a single character
    /// is wider than the line.
    private static func balancedBreaks(
        starts: [Int], count: Int, maxWidth: CGFloat,
        width: (Int, Int) -> CGFloat, squeeze: (Int, Int) -> CGFloat,
        visibleEnd: (Int, Int) -> Int, isSpace: (Int) -> Bool
    ) -> [Range<Int>]? {
        let words = [0] + starts.filter { $0 > 0 && $0 < count } + [count]
        let tooWide = Set(zip(words, words.dropFirst()).filter { width($0, visibleEnd($0, $1)) > maxWidth + 0.0001 }.map(\.0))
        // With a word too wide for the line, breaks inside words too, each
        // with the start of its word.
        var points = [0]
        var wordOf: [Int: Int] = [:]
        for (a, b) in zip(words, words.dropFirst()) {
            if !tooWide.isEmpty {
                for inside in a + 1 ..< max(a + 1, visibleEnd(a, b)) {
                    points.append(inside)
                    wordOf[inside] = a
                }
            }
            points.append(b)
        }
        var best = [CGFloat](repeating: .infinity, count: points.count)
        var previous = [Int](repeating: -1, count: points.count)
        best[0] = 0
        for j in 1 ..< points.count {
            for i in stride(from: j - 1, through: 0, by: -1) {
                let a = points[i], b = points[j], visible = visibleEnd(a, b)
                let natural = width(a, visible)
                let spaceWidth = squeeze(a, visible) / justifiedSqueeze
                // Further back only adds width: stop once a line can't fit.
                if natural - squeeze(a, visible) > maxWidth + 0.0001 { break }
                var breaking: CGFloat = 0
                if let word = wordOf[b] {
                    // Inside a word: no squeezing, and as many characters as fit.
                    if natural > maxWidth + 0.0001 || width(a, b + 1) <= maxWidth { continue }
                    if word > a || !tooWide.contains(word) { breaking = Self.voluntaryBreakCost }
                }
                let slack = abs(maxWidth - natural)
                let fit: CGFloat = if b == count {
                    0
                } else if spaceWidth > 0 {
                    pow(slack / spaceWidth, 3)
                } else {
                    30_000 * pow(slack / maxWidth, 7)
                }
                let cost = fit + breaking
                if best[i] + cost < best[j] {
                    best[j] = best[i] + cost
                    previous[j] = i
                }
            }
        }
        guard previous[points.count - 1] >= 0 else { return nil }
        var ranges: [Range<Int>] = []
        var j = points.count - 1
        while j > 0 {
            let i = previous[j]
            ranges.append(points[i] ..< points[j])
            j = i
        }
        return ranges.reversed()
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
        // Rotated, sheared or mirrored, glyphs are drawn as their outlines
        // through the transform; axis-aligned, as masks at the device's scale.
        let axisAligned = ctm.b == 0 && ctm.c == 0 && ctm.a > 0 && ctm.d != 0
        let scale = axisAligned ? ctm.a : sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        // Whether up on the page (toward the ascent, -y in UIKit's space) is
        // up in memory too (toward row 0). In a context that isn't flipped
        // for UIKit, text comes out upside down, as UIKit draws it there.
        let upright = ctm.d > 0
        var top = rect.minY
        for line in lines {
            guard top + line.height <= rect.maxY + 0.0001 else { break }
            defer { top += line.height + line.style.lineSpacing }
            let start = rect.minX + Self.offset(of: line, in: rect.width)
            let stretch = Self.justifies(line, in: rect.width) ? (rect.width - line.visibleWidth) / CGFloat(line.spaces) : 0
            var spacesBefore = 0
            for piece in line.pieces {
                let run = runs[piece.run]
                // Justified text widens its spaces; letter spacing places each character.
                let parts: [(String, CGFloat)] = if stretch != 0 || run.kern != 0 {
                    piece.text.first == "\u{200F}"
                        ? Self.splitRightToLeft(piece.text, run: run, byCharacter: run.kern != 0, provider: provider)
                        : Self.split(piece.text, run: run, byCharacter: run.kern != 0, provider: provider)
                } else {
                    [(piece.text, 0)]
                }
                for (text, offset) in parts {
                    // A right-to-left word's spaces are before it, to its left.
                    let leading = text.first == "\u{200F}" ? 0 : text.prefix(while: { $0 == " " }).count
                    spacesBefore += leading
                    let x = start + piece.x + offset + stretch * CGFloat(spacesBefore)
                    spacesBefore += text.filter { $0 == " " }.count - leading
                    guard !text.allSatisfy(\.isWhitespace) else { continue }
                    let baseline = top + line.ascent - run.baselineOffset
                    if axisAligned {
                        draw(text, run: run, at: CGPoint(x: x, y: baseline), mode: mode, upright: upright,
                             scale: scale, ctm: ctm, provider: provider, context: context)
                    } else {
                        if mode.fills {
                            snappedOutline(text, run: run, at: CGPoint(x: x, y: baseline), scale: scale, ctm: ctm,
                                           provider: provider, context: context)
                        }
                        if mode.strokes {
                            outline(text, run: run, at: CGPoint(x: x, y: baseline), fill: false, stroke: true,
                                    provider: provider, context: context)
                        }
                    }
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

    /// A right-to-left piece (led by its mark) split as `split` splits one,
    /// its words placed right to left: each word after the spaces that
    /// follow it in the text, which are on its left.
    private static func splitRightToLeft(_ text: String, run: Run, byCharacter: Bool, provider: TextProvider) -> [(String, CGFloat)] {
        var parts: [String] = []
        for character in text.dropFirst() {
            if byCharacter || parts.isEmpty || parts[parts.count - 1].last == " " {
                parts.append(String(character))
            } else {
                parts[parts.count - 1].append(character)
            }
        }
        func advance(_ text: String) -> CGFloat {
            text.isEmpty ? 0 : provider.measure(text, font: run.font).advance + run.kern * CGFloat(text.count)
        }
        var x: CGFloat = 0
        var placed: [(String, CGFloat)] = []
        for part in parts.reversed() {
            var word = Substring(part)
            while word.last == " " { word = word.dropLast() }
            let spaces = String(repeating: " ", count: part.count - word.count)
            if !spaces.isEmpty {
                placed.append((spaces, x))
                x += advance(spaces)
            }
            placed.append(("\u{200F}" + word, x))
            x += advance(String(word))
        }
        return placed
    }

    private func draw(
        _ text: String, run: Run, at point: CGPoint, mode: BitmapContext.TextDrawingMode, upright: Bool,
        scale: CGFloat, ctm: CGAffineTransform, provider: TextProvider, context: BitmapContext
    ) {
        let device = point.applying(ctm)
        // The baseline to the next whole device row, counting rows from the
        // top of memory, flipped context or not (measured on Catalyst).
        let baseline = (device.y - 0.0001).rounded(.up)
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
                if let colour = mask.colour {
                    context.fillImage(
                        colour, width: mask.width, height: mask.height,
                        // Emoji take none of the text colour, its alpha
                        // neither, unless it's clear (as UIKit draws them).
                        atDeviceX: left, y: upright ? -top : top - 1, rowsDown: upright, alpha: run.colour.alpha > 0 ? 1 : 0
                    )
                    continue
                }
                context.fillMask(
                    mask.coverage, width: mask.width, height: mask.height,
                    // Row 0 of the mask is its top: `top - 1` up in glyph space.
                    atDeviceX: left, y: upright ? -top : top - 1, rowsDown: upright,
                    colour: run.colour
                )
            }
        }
        if mode.strokes {
            // Outlines stroke where the pen is, unsnapped: UIKit snaps only
            // the glyphs it fills (measured on Catalyst).
            outline(text, run: run, at: point, fill: false, stroke: true, provider: provider, context: context)
        }
    }

    /// Filled glyphs through a rotation, shear or mirror: each glyph's
    /// outline with its own pen snapped in device space as UIKit snaps it
    /// there too (measured on Catalyst), x floored to the step its pixel
    /// size takes (`positionsPerPixel`), the baseline down to the next row.
    private func snappedOutline(
        _ text: String, run: Run, at point: CGPoint, scale: CGFloat, ctm: CGAffineTransform,
        provider: TextProvider, context: BitmapContext
    ) {
        let glyphs = provider.glyphOutlines(text, font: run.font)
        guard !glyphs.isEmpty else { return }
        let steps = CGFloat(Self.positionsPerPixel(forPixelSize: run.font.size * scale))
        let inverse = ctm.inverted()
        context.saveGState()
        context.setFill(run.colour)
        context.beginPath()
        for glyph in glyphs {
            let device = CGPoint(x: point.x + glyph.origin.x, y: point.y - glyph.origin.y).applying(ctm)
            // Within a ten-thousandth of a pixel counts as on it, both ways.
            let pen = CGPoint(x: (device.x * steps + 0.0001).rounded(.down) / steps, y: (device.y - 0.0001).rounded(.up)).applying(inverse)
            func place(_ p: CGPoint) -> CGPoint { CGPoint(x: pen.x + p.x, y: pen.y - p.y) }
            for element in glyph.elements {
                switch element {
                case let .move(p): context.move(to: place(p))
                case let .line(p): context.addLine(to: place(p))
                case let .quadCurve(to, control): context.addQuadCurve(to: place(to), control: place(control))
                case let .curve(to, c1, c2): context.addCurve(to: place(to), control1: place(c1), control2: place(c2))
                case .close: context.closePath()
                case .arc: break
                }
            }
        }
        context.fillPath()
        context.restoreGState()
    }

    /// The glyphs' outlines with the pen at `point` (user space), filled
    /// and or stroked in the run's colour, through the context's transform.
    private func outline(
        _ text: String, run: Run, at point: CGPoint, fill: Bool, stroke: Bool, provider: TextProvider, context: BitmapContext
    ) {
        guard fill || stroke else { return }
        let elements = provider.glyphOutline(text, font: run.font)
        guard !elements.isEmpty else { return }
        func place(_ p: CGPoint) -> CGPoint { CGPoint(x: point.x + p.x, y: point.y - p.y) }
        func trace() {
            context.beginPath()
            for element in elements {
                switch element {
                case let .move(p): context.move(to: place(p))
                case let .line(p): context.addLine(to: place(p))
                case let .quadCurve(to, control): context.addQuadCurve(to: place(to), control: place(control))
                case let .curve(to, c1, c2): context.addCurve(to: place(to), control1: place(c1), control2: place(c2))
                case .close: context.closePath()
                case .arc: break
                }
            }
        }
        context.saveGState()
        if fill {
            context.setFill(run.colour)
            trace()
            context.fillPath()
        }
        if stroke {
            context.setStroke(run.colour)
            trace()
            context.strokePath()
        }
        context.restoreGState()
    }
}
#endif
