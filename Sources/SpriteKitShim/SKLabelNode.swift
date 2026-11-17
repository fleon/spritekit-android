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
/// which a game's pills and buttons are sized by. Several lines keep the
/// simpler layout below.
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
    open var lineBreakMode: Int = 0
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
            return
        }
        text = attributedText.string
        guard attributedText.length > 0 else {
            kern = 0
            return
        }
        let attributes = attributedText.attributes(at: 0, effectiveRange: nil)
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
            maxWidth: preferredMaxLayoutWidth
        )
    }

    private func makeLayout() -> TextLayout? {
        guard let text, !text.isEmpty, let provider = TextMetrics.provider else { return nil }
        if let runs, numberOfLines == 1 {
            let laidOut = runLayout(runs, provider: provider)
            laidOutRuns = laidOut == nil ? nil : runs
            return laidOut
        }
        let font = FontKey(name: fontName ?? "", size: fontSize)
        guard let metrics = provider.fontMetrics(font) else { return nil }

        let broken = brokenLines(text, font: font, provider: provider)
        guard !broken.isEmpty else { return nil }

        let lineHeight = metrics.lineHeight
        var placed: [TextLayout.Placed] = []
        var box: CGRect?

        for (index, text) in broken.enumerated() {
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
            let x: CGFloat
            switch horizontalAlignmentMode {
            case .left: x = 0
            case .right: x = -line.advance
            case .center: x = -line.advance / 2
            }
            // The first line's baseline sits on the node's origin; the rest
            // hang below it, as SpriteKit stacks them.
            let origin = CGPoint(x: x, y: -CGFloat(index) * lineHeight)
            placed.append(TextLayout.Placed(line: line, origin: origin))
            let ink = line.inkBounds.offsetBy(dx: origin.x, dy: origin.y)
            box = box.map { $0.union(ink) } ?? ink
        }

        guard var bounds = box else { return nil }
        if numberOfLines == 1, placed.count == 1, !bounds.isEmpty {
            return Self.spriteKitLine(placed[0].line, horizontal: horizontalAlignmentMode, vertical: verticalAlignmentMode)
        }

        let shift: CGFloat
        switch verticalAlignmentMode {
        case .baseline: shift = 0
        case .center: shift = -bounds.midY
        case .top: shift = -bounds.maxY
        case .bottom: shift = -bounds.minY
        }

        if shift != 0 {
            bounds = bounds.offsetBy(dx: 0, dy: shift)
            placed = placed.map {
                TextLayout.Placed(
                    line: $0.line,
                    origin: CGPoint(x: $0.origin.x, y: $0.origin.y + shift)
                )
            }
        }

        return TextLayout(lines: placed, bounds: bounds)
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
    /// Both follow SpriteKit.
    private func brokenLines(
        _ text: String,
        font: FontKey,
        provider: TextProvider
    ) -> [String] {
        if numberOfLines == 1 {
            return [text.replacingOccurrences(of: "\n", with: " ")]
        }

        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
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

        if numberOfLines > 1, lines.count > numberOfLines {
            lines = Array(lines.prefix(numberOfLines))
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
    /// Carried, not drawn yet: the stroke draws in `strokeColor` alone.
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
