#if SPRITEKIT_SHIM
import Foundation

public enum SKLabelHorizontalAlignmentMode: Int, Sendable {
    case center, left, right
}

public enum SKLabelVerticalAlignmentMode: Int, Sendable {
    case baseline, center, top, bottom
}

/// Text.
///
/// Layout here is real: the node breaks its text, places each line and
/// reports the box the ink covers. The measuring behind it — shaping with
/// HarfBuzz, metrics from FreeType — comes from whatever `TextProvider` has
/// been registered with `TextMetrics`, which keeps those two C libraries out
/// of this package. See `Text/`.
///
/// With no provider registered the frame is `.zero`, as it was before any of
/// this landed. That is deliberate: a label that measures nothing is obvious,
/// where one measuring with made-up metrics is subtly wrong everywhere.
///
/// A single line (`numberOfLines` of 1, all the game uses) is laid out as
/// SpriteKit lays it out, measured against Apple's own `SKLabelNode` on the
/// same font files: SpriteKit draws the line into a box of whole points, the
/// ink rounded out and padded by a point on every side, and that box is the
/// label's frame and what the alignment modes place. `.left` puts its left
/// edge on the origin, `.center` its middle (rounded down), `.right` its
/// right edge; `.baseline` puts its bottom where the ink's rounded-down
/// bottom is, `.center` its middle, `.top` and `.bottom` its edges. So both
/// axes work on the **ink**, not the advance: a descender moves a centred
/// label, which a game undoes for buttons (from a `CTLine`'s glyph-path
/// bounds), and every frame is a little wider and taller than the ink,
/// which a game's pills and buttons are sized by. A label of more than one
/// line (`numberOfLines` other than 1) is framed by its typographic block
/// instead (`spriteKitParagraph`).
open class SKLabelNode: SKNode {
    open var text: String? { didSet { invalidateLayout() } }
    open var fontName: String? { didSet { invalidateLayout() } }
    open var fontSize: CGFloat = 32 { didSet { invalidateLayout() } }
    open var fontColor: SKColor? = .white
    open var horizontalAlignmentMode: SKLabelHorizontalAlignmentMode = .center {
        didSet { invalidateLayout() }
    }
    open var verticalAlignmentMode: SKLabelVerticalAlignmentMode = .baseline {
        didSet { invalidateLayout() }
    }
    open var numberOfLines: Int = 1 { didSet { invalidateLayout() } }
    open var preferredMaxLayoutWidth: CGFloat = 0 { didSet { invalidateLayout() } }
    #if canImport(Darwin)
    open var lineBreakMode: Int = 0
    #else
    /// Carried, as SpriteKit's starts it (measured); the layout wraps at
    /// words whenever it wraps.
    open var lineBreakMode: NSLineBreakMode = .byTruncatingTail
    #endif
    open var blendMode: SKBlendMode = .alpha

    /// The text with its attributes, as SpriteKit takes it. What the games
    /// set is one run over the whole string — a font, a colour and letter
    /// spacing (`.font`, `.foregroundColor`, `.kern`) — and that is what
    /// draws: the string, in the font and colour of its first character,
    /// spaced by its kern. Nil clears it, leaving `text` and the font as
    /// they were made.
    open var attributedText: NSAttributedString? {
        didSet { adoptAttributes() }
    }

    /// Extra space after each character, in points: the attributed text's
    /// `.kern` (`NSKern`), 0 without one.
    public private(set) var kern: CGFloat = 0 { didSet { invalidateLayout() } }

    /// Whether the attributed text's paragraph style (`.paragraphStyle`, its
    /// first character's) right-aligns its lines. In a label of several
    /// lines SpriteKit then lines each one up on the block's right edge;
    /// otherwise each starts at its left, wherever the alignment mode puts
    /// the block (measured on a Mac).
    public private(set) var alignsLinesRight = false { didSet { invalidateLayout() } }

    /// One stretch of attributed text in a style of its own: its font,
    /// colour, letter spacing and how far it sits above the baseline
    /// (`.baselineOffset`).
    public struct Run: Equatable {
        public var text: String
        public var fontName: String?
        public var fontSize: CGFloat
        public var color: SKColor?
        public var kern: CGFloat
        public var baselineOffset: CGFloat

        public static func == (a: Run, b: Run) -> Bool {
            a.text == b.text && a.hasSameStyle(as: b)
        }

        func hasSameStyle(as other: Run) -> Bool {
            func components(_ color: SKColor?) -> [CGFloat]? {
                color.map { [$0.red, $0.green, $0.blue, $0.alpha] }
            }
            return fontName == other.fontName && fontSize == other.fontSize && kern == other.kern
                && baselineOffset == other.baselineOffset && components(color) == components(other.color)
        }
    }

    /// The attributed text's runs when they differ in style, each drawn in
    /// its own on one line, as SpriteKit draws them; nil when one style
    /// covers the text, which then draws as `text` in the label's font.
    public private(set) var runs: [Run]? { didSet { invalidateLayout() } }

    /// The runs `layout` placed, one line each, when it laid them out as
    /// one line (`runLayout`); nil when the layout is the label's own text.
    /// Read after `layout`, which sets it.
    public private(set) var laidOutRuns: [Run]?

    private func adoptAttributes() {
        defer { runs = Self.styledRuns(of: attributedText, fontName: fontName, fontSize: fontSize, color: fontColor) }
        guard let attributedText else {
            kern = 0
            alignsLinesRight = false
            return
        }
        text = attributedText.string
        guard attributedText.length > 0 else {
            kern = 0
            alignsLinesRight = false
            return
        }
        let attributes = attributedText.attributes(at: 0, effectiveRange: nil)
        alignsLinesRight = Self.alignment(of: attributes[NSAttributedString.Key("NSParagraphStyle")]) == Self.rightAlignment
        if let font = attributes[NSAttributedString.Key("NSFont")] as? LabelFont {
            fontName = font.fontName
            fontSize = font.pointSize
        }
        if let colour = attributes[NSAttributedString.Key("NSColor")] as? SKColor {
            fontColor = colour
        }
        switch attributes[NSAttributedString.Key("NSKern")] {
        case let number as NSNumber: kern = CGFloat(number.doubleValue)
        case let value as CGFloat: kern = value
        case let value as Double: kern = CGFloat(value)
        default: kern = 0
        }
    }

    /// NSTextAlignment.right's raw value, on Apple's platforms and the shim's.
    static let rightAlignment = 2

    /// A paragraph style's alignment, as its raw value.
    static func alignment(of style: Any?) -> Int? {
        #if canImport(Darwin)
        (style as? NSObject)?.value(forKey: "alignment") as? Int
        #else
        (style as? NSParagraphStyle)?.alignment.rawValue
        #endif
    }

    /// The text's attribute runs, merged where neighbours share a style;
    /// nil when there are fewer than two styles.
    static func styledRuns(of text: NSAttributedString?, fontName: String?, fontSize: CGFloat, color: SKColor?) -> [Run]? {
        guard let text, text.length > 0 else { return nil }
        var runs: [Run] = []
        let string = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { attributes, range, _ in
            let font = attributes[NSAttributedString.Key("NSFont")] as? LabelFont
            func number(_ value: Any?) -> CGFloat {
                switch value {
                case let number as NSNumber: return CGFloat(number.doubleValue)
                case let value as CGFloat: return value
                case let value as Double: return CGFloat(value)
                default: return 0
                }
            }
            let run = Run(
                text: string.substring(with: range),
                fontName: font?.fontName ?? fontName,
                fontSize: font?.pointSize ?? fontSize,
                color: attributes[NSAttributedString.Key("NSColor")] as? SKColor ?? color,
                kern: number(attributes[NSAttributedString.Key("NSKern")]),
                baselineOffset: number(attributes[NSAttributedString.Key("NSBaselineOffset")])
            )
            if let last = runs.last, last.hasSameStyle(as: run) {
                runs[runs.count - 1].text += run.text
            } else {
                runs.append(run)
            }
        }
        // One style still draws as a run when it sits off the baseline.
        return runs.count > 1 || runs.first?.baselineOffset != 0 ? runs : nil
    }

    private struct LayoutInput: Equatable {
        var runs: [Run]?
        var text: String?
        var kern: CGFloat
        var fontName: String?
        var fontSize: CGFloat
        var horizontal: SKLabelHorizontalAlignmentMode
        var vertical: SKLabelVerticalAlignmentMode
        var numberOfLines: Int
        var maxWidth: CGFloat
        var alignsLinesRight: Bool
    }

    private var cachedLayout: TextLayout?
    private var cachedFor: LayoutInput?

    public override init() {
        super.init()
    }

    public init(fontNamed name: String?) {
        fontName = name
        super.init()
    }

    public convenience init(text: String?) {
        self.init()
        self.text = text
    }

    /// The box the ink covers, in the node's own coordinates.
    open override var contentFrame: CGRect { layout?.bounds ?? .zero }

    /// The laid-out lines, so the renderer draws what was measured rather
    /// than measuring a second time and drifting from `contentFrame`.
    open var layout: TextLayout? {
        let key = layoutKey
        if cachedFor == key, let cachedLayout { return cachedLayout }
        laidOutRuns = nil
        let made = makeLayout()
        cachedLayout = made
        cachedFor = made == nil ? nil : key
        return made
    }

    private func invalidateLayout() {
        cachedLayout = nil
        cachedFor = nil
    }

    private var layoutKey: LayoutInput {
        LayoutInput(
            runs: runs,
            text: text,
            kern: kern,
            fontName: fontName,
            fontSize: fontSize,
            horizontal: horizontalAlignmentMode,
            vertical: verticalAlignmentMode,
            numberOfLines: numberOfLines,
            maxWidth: preferredMaxLayoutWidth,
            alignsLinesRight: alignsLinesRight
        )
    }

    private func makeLayout() -> TextLayout? {
        guard let text, let provider = TextMetrics.provider else { return nil }
        // An empty label frames 2 × 2, its padding alone, as SpriteKit's does.
        guard !text.isEmpty else { return Self.emptyFrame(horizontal: horizontalAlignmentMode, vertical: verticalAlignmentMode) }
        if let runs {
            if numberOfLines == 1 {
                let laidOut = runLayout(runs, provider: provider)
                laidOutRuns = laidOut == nil ? nil : runs
                return laidOut
            }
        }
        // Lines the text breaks itself, each in its runs' styles; wrapped
        // text in several styles draws as the label's own.
        if let runs, preferredMaxLayoutWidth == 0 {
            guard let (lines, pieces) = paragraphLines(runs, provider: provider) else { return nil }
            laidOutRuns = pieces
            return Self.spriteKitParagraph(lines, horizontal: horizontalAlignmentMode, vertical: verticalAlignmentMode, alignsLinesRight: alignsLinesRight)
        }
        let font = FontKey(name: fontName ?? "", size: fontSize)
        guard let metrics = provider.fontMetrics(font) else { return nil }

        let broken = brokenLines(text, font: font, metrics: metrics, provider: provider)
        guard !broken.isEmpty else { return nil }

        if numberOfLines == 1 {
            let line = measure(broken[0], font: font, provider: provider)
            guard !line.inkBounds.isEmpty else {
                // Only whitespace: no ink to frame, so the padding alone,
                // a point wider for two characters or more besides newlines.
                return Self.emptyFrame(
                    horizontal: horizontalAlignmentMode, vertical: verticalAlignmentMode,
                    width: text.filter { $0 != "\n" }.count >= 2 ? 3 : 2
                )
            }
            return Self.spriteKitLine(line, horizontal: horizontalAlignmentMode, vertical: verticalAlignmentMode)
        }
        let lines = broken.map { text in
            ParagraphLine(
                pieces: [(measure(text, font: font, provider: provider), 0, 0)],
                width: measure(Self.trimmingTrailingWhitespace(text), font: font, provider: provider).advance,
                metrics: metrics
            )
        }
        return Self.spriteKitParagraph(lines, horizontal: horizontalAlignmentMode, vertical: verticalAlignmentMode, alignsLinesRight: alignsLinesRight)
    }

    /// A frame with nothing in it: SpriteKit's 2 × 2 of padding, placed by
    /// the alignment.
    static func emptyFrame(
        horizontal: SKLabelHorizontalAlignmentMode, vertical: SKLabelVerticalAlignmentMode, width: CGFloat = 2
    ) -> TextLayout {
        let x: CGFloat = horizontal == .left ? 0 : horizontal == .right ? -width : -(width / 2).rounded(.down)
        let y: CGFloat
        switch vertical {
        case .baseline, .bottom: y = 0
        case .center: y = -1
        case .top: y = -2
        }
        return TextLayout(lines: [], bounds: CGRect(x: x, y: y, width: width, height: 2))
    }

    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    /// One line of a paragraph: its pieces, each measured with the pen's
    /// offset along the line and its rise above the baseline; its width
    /// without the whitespace it ends on; and its metrics, the largest of
    /// its styles'.
    struct ParagraphLine {
        var pieces: [(line: TextLine, x: CGFloat, rise: CGFloat)]
        var width: CGFloat
        var metrics: FontMetrics
    }

    /// Styled runs as paragraph lines, broken at their newlines (wrapping is
    /// for one style), and the run each placed piece is drawn in.
    private func paragraphLines(_ runs: [Run], provider: TextProvider) -> ([ParagraphLine], [Run])? {
        var lines: [ParagraphLine] = []
        var placedRuns: [Run] = []
        var current = ParagraphLine(pieces: [], width: 0, metrics: FontMetrics(ascent: 0, descent: 0, leading: 0, capHeight: 0, xHeight: 0))
        var currentText: [(run: Run, text: String)] = []
        var pen: CGFloat = 0
        var hasMetrics = false

        func measured(_ run: Run, _ text: String) -> TextLine {
            var line = provider.measure(text, font: FontKey(name: run.fontName ?? "", size: run.fontSize))
            if run.kern != 0 {
                let count = CGFloat(text.count)
                line.advance += run.kern * count
                if !line.inkBounds.isEmpty { line.inkBounds.size.width += run.kern * max(count - 1, 0) }
            }
            return line
        }
        func adopt(_ run: Run) -> Bool {
            guard let metrics = provider.fontMetrics(FontKey(name: run.fontName ?? "", size: run.fontSize)) else { return false }
            if hasMetrics {
                current.metrics.ascent = max(current.metrics.ascent, metrics.ascent)
                current.metrics.descent = max(current.metrics.descent, metrics.descent)
                current.metrics.leading = max(current.metrics.leading, metrics.leading)
            } else {
                current.metrics = metrics
                hasMetrics = true
            }
            return true
        }
        func finishLine() {
            // The width is the line's run of text without its trailing
            // whitespace: pieces after the last ink-bearing one count for
            // nothing, and that one is measured trimmed.
            var width: CGFloat = 0
            var x: CGFloat = 0
            var lastInked = -1
            for (index, piece) in currentText.enumerated() where !Self.trimmingTrailingWhitespace(piece.text).isEmpty { lastInked = index }
            for (index, piece) in currentText.enumerated() where index <= lastInked {
                let text = index == lastInked ? Self.trimmingTrailingWhitespace(piece.text) : piece.text
                let advance = measured(piece.run, text).advance
                width = x + advance
                x += measured(piece.run, piece.text).advance
            }
            current.width = width
            lines.append(current)
            current = ParagraphLine(pieces: [], width: 0, metrics: current.metrics)
            currentText = []
            pen = 0
            hasMetrics = false
        }

        for run in runs {
            let parts = run.text.components(separatedBy: "\n")
            for (index, part) in parts.enumerated() {
                if index > 0 { finishLine() }
                // A run counts toward a line it puts text on, or ends with
                // its newline; not the line its newline only starts.
                if !part.isEmpty || index < parts.count - 1 {
                    guard adopt(run) else { return nil }
                }
                guard !part.isEmpty else { continue }
                let line = measured(run, part)
                current.pieces.append((line, pen, run.baselineOffset))
                currentText.append((run, part))
                var piece = run
                piece.text = part
                placedRuns.append(piece)
                pen += line.advance
            }
        }
        // A newline the text ends on starts no line.
        if !(runs.last?.text.hasSuffix("\n") ?? false) || lines.isEmpty { finishLine() }
        return (lines, placedRuns)
    }

    /// One line measured, with the label's letter spacing.
    private func measure(_ text: String, font: FontKey, provider: TextProvider) -> TextLine {
        var line = provider.measure(text, font: font)
        if kern != 0 {
            // Each character's spacing comes after it, as CoreText puts
            // it: the pen travels `kern` further a character, and the
            // last character's ink sits that much further on for every
            // one before it.
            let count = CGFloat(text.count)
            line.advance += kern * count
            if !line.inkBounds.isEmpty {
                line.inkBounds.size.width += kern * max(count - 1, 0)
            }
        }
        return line
    }

    /// Lines as SpriteKit lays out a label of more than one line (any
    /// `numberOfLines` but 1, measured against `SpriteKit.SKLabelNode`):
    /// the frame is the typographic block, not the ink, the widest line's
    /// advance (`widths`, without the whitespace it ends on) rounded up and
    /// padded by 1 a side, and from 1 above the first
    /// line's ascent to the last line's descent, rounded out, and 1 below.
    /// Each line advances by its descent and leading and the next line's
    /// ascent, each rounded to whole points (a line's metrics the largest of
    /// its styles', for an attributed label), and starts at the block's left
    /// edge whatever the alignment, which places the block alone. In
    /// `.baseline`, as in `.bottom`, the whole block stands above the origin.
    static func spriteKitParagraph(
        _ lines: [ParagraphLine],
        horizontal: SKLabelHorizontalAlignmentMode,
        vertical: SKLabelVerticalAlignmentMode,
        alignsLinesRight: Bool = false
    ) -> TextLayout {
        // Each baseline below the block's top: the first line's ascent, then
        // a line's descent and leading and the next one's ascent, each
        // rounded, a line's metrics being the largest of its styles'.
        var baselines: [CGFloat] = []
        for (index, line) in lines.enumerated() {
            let ascent = line.metrics.ascent.rounded()
            if index == 0 {
                baselines.append(ascent)
            } else {
                let above = lines[index - 1].metrics
                baselines.append(baselines[index - 1] + above.descent.rounded() + above.leading.rounded() + ascent)
            }
        }
        let widest = lines.map(\.width).max() ?? 0
        let width = widest.rounded(.up) + 2
        // 1 above the first ascent, the last line down to its descent, then
        // rounded out and 1 more below.
        let height = (1 + (baselines.last ?? 0) + (lines.last?.metrics.descent ?? 0)).rounded(.up) + 1
        let x: CGFloat
        switch horizontal {
        case .left: x = 0
        case .center: x = -(width / 2).rounded(.down)
        case .right: x = -width
        }
        let y: CGFloat
        switch vertical {
        case .baseline, .bottom: y = 0
        case .center: y = -(height / 2).rounded(.down)
        case .top: y = -height
        }
        let top = y + height - 1
        var placed: [TextLayout.Placed] = []
        for (index, line) in lines.enumerated() {
            let indent = alignsLinesRight ? widest - line.width : 0
            for piece in line.pieces {
                placed.append(TextLayout.Placed(line: piece.line, origin: CGPoint(x: x + 1 + indent + piece.x, y: top - baselines[index] + piece.rise)))
            }
        }
        return TextLayout(lines: placed, bounds: CGRect(x: x, y: y, width: width, height: height))
    }

    /// Styled runs on one line, as SpriteKit lays an attributed label out
    /// (measured on a Mac: `AttributedLabelRunTests`): end to end on a shared
    /// baseline, each raised by its `baselineOffset`, the whole line placed
    /// by its combined ink as a one-style line is. One placed line per run,
    /// in `runs`' order.
    private func runLayout(_ runs: [Run], provider: TextProvider) -> TextLayout? {
        var pen: CGFloat = 0
        var measured: [(line: TextLine, offset: CGPoint)] = []
        var ink: CGRect?
        for run in runs {
            var line = provider.measure(run.text, font: FontKey(name: run.fontName ?? "", size: run.fontSize))
            if run.kern != 0 {
                let count = CGFloat(run.text.count)
                line.advance += run.kern * count
                if !line.inkBounds.isEmpty { line.inkBounds.size.width += run.kern * max(count - 1, 0) }
            }
            let offset = CGPoint(x: pen, y: run.baselineOffset)
            measured.append((line, offset))
            if !line.inkBounds.isEmpty {
                let placed = line.inkBounds.offsetBy(dx: offset.x, dy: offset.y)
                ink = ink.map { $0.union(placed) } ?? placed
            }
            pen += line.advance
        }
        guard let ink else { return nil }
        let whole = TextLine(text: runs.map(\.text).joined(), advance: pen, inkBounds: ink)
        let placed = Self.spriteKitLine(whole, horizontal: horizontalAlignmentMode, vertical: verticalAlignmentMode)
        guard let origin = placed.lines.first?.origin else { return nil }
        return TextLayout(
            lines: measured.map {
                TextLayout.Placed(line: $0.line, origin: CGPoint(x: origin.x + $0.offset.x, y: origin.y + $0.offset.y))
            },
            bounds: placed.bounds
        )
    }

    /// One line as SpriteKit lays it out (see the type's comment): its frame
    /// the ink's box rounded out to whole points and padded by one, placed by
    /// the alignment modes, and the pen where that puts the ink.
    static func spriteKitLine(
        _ line: TextLine,
        horizontal: SKLabelHorizontalAlignmentMode,
        vertical: SKLabelVerticalAlignmentMode
    ) -> TextLayout {
        let ink = line.inkBounds
        let left = ink.minX.rounded(.down), bottom = ink.minY.rounded(.down)
        let width = ink.maxX.rounded(.up) - left + 2
        let height = ink.maxY.rounded(.up) - bottom + 2
        let x: CGFloat
        switch horizontal {
        case .left: x = 0
        case .center: x = -(width / 2).rounded(.down)
        case .right: x = -width
        }
        let y: CGFloat
        switch vertical {
        case .baseline: y = bottom
        case .center: y = -(height / 2).rounded(.down)
        case .top: y = -height
        case .bottom: y = 0
        }
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let origin = CGPoint(x: x + 1 - left, y: y + 1 - bottom)
        return TextLayout(lines: [TextLayout.Placed(line: line, origin: origin)], bounds: frame)
    }

    /// `numberOfLines` of 1 means one line whatever the text holds, 0 means
    /// as many as it takes; `preferredMaxLayoutWidth` of 0 means no wrapping.
    /// A larger `numberOfLines` n is SpriteKit's frame fitting (measured on
    /// 16,848 frames): the text is laid into a frame (n + 1)·S tall, S being
    /// the height of the text's own lines (P of them, a trailing newline not
    /// counted), ⌈round(a) + (P − 1)·adv + d⌉, and line j is kept while
    /// round(a) + (j − 1)·adv + d ≤ (n + 1)·S, with adv = round(a) + round(d)
    /// + round(l). So the text's own lines are never cut unless it also
    /// wraps, and a single paragraph keeps n + 1 lines when
    /// round(d) + round(l) ≤ ⌈d⌉ (any face without a line gap), else n.
    private func brokenLines(
        _ text: String,
        font: FontKey,
        metrics: FontMetrics,
        provider: TextProvider
    ) -> [String] {
        if numberOfLines == 1 {
            return [text.replacingOccurrences(of: "\n", with: " ")]
        }

        var paragraphs = text.components(separatedBy: "\n")
        // A newline the text ends on ends its last line; it starts no other.
        if paragraphs.count > 1, paragraphs.last == "" { paragraphs.removeLast() }
        var lines: [String] = []
        for paragraph in paragraphs {
            if preferredMaxLayoutWidth > 0 {
                lines.append(contentsOf: provider.breakLines(
                    paragraph,
                    font: font,
                    maxWidth: preferredMaxLayoutWidth
                ))
            } else {
                lines.append(paragraph)
            }
        }

        if numberOfLines > 1 {
            let ascent = metrics.ascent.rounded()
            let advance = ascent + metrics.descent.rounded() + metrics.leading.rounded()
            let own = (ascent + CGFloat(paragraphs.count - 1) * advance + metrics.descent).rounded(.up)
            let frame = CGFloat(numberOfLines + 1) * own
            var kept = 0
            while kept < lines.count, ascent + CGFloat(kept) * advance + metrics.descent <= frame { kept += 1 }
            lines = Array(lines.prefix(max(1, kept)))
        }
        return lines
    }
}

/// Vector shapes — buttons, panels, meters and the focus rings.
///
/// A game may also draw such surfaces through a `CGContext`, so the
/// renderer needs a 2D path rasteriser either way.
/// The shim records the path; filling and stroking it is the renderer's job.
open class SKShapeNode: SKNode {
    open var path: CGPath?
    open var lineCap: CGLineCap = .butt
    open var lineJoin: CGLineJoin = .miter
    open var fillColor: SKColor = .clear
    open var strokeColor: SKColor = .white
    open var lineWidth: CGFloat = 1
    open var glowWidth: CGFloat = 0
    open var isAntialiased: Bool = true
    open var blendMode: SKBlendMode = .alpha
    open var fillTexture: SKTexture?
    /// Stretched over the path's bounds and tinted by `strokeColor`, as
    /// `fillTexture` is for the fill.
    open var strokeTexture: SKTexture?
    open var fillShader: SKShader?
    /// Carried, not drawn.
    open var strokeShader: SKShader?

    public override init() {
        super.init()
    }

    // The game builds shapes through its own `shape(_:)` helper and assigns
    // `path`, so no convenience initialisers are needed here.

    open override var contentFrame: CGRect {
        guard let path else { return .zero }
        return path.boundingBox.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
    }
}

#endif
