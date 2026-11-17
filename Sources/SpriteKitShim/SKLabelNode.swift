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

    private struct LayoutInput: Equatable {
        var text: String?
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
            text: text,
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
        let font = FontKey(name: fontName ?? "", size: fontSize)
        guard let metrics = provider.fontMetrics(font) else { return nil }

        let broken = brokenLines(text, font: font, provider: provider)
        guard !broken.isEmpty else { return nil }
        let lines = broken.map { provider.measure($0, font: font) }

        if numberOfLines == 1, let line = lines.first {
            guard !line.inkBounds.isEmpty else {
                // Only spaces: nothing to frame, the pen where the alignment puts it.
                let x: CGFloat = horizontalAlignmentMode == .left ? 0 : horizontalAlignmentMode == .right ? -line.advance : -line.advance / 2
                return TextLayout(lines: [TextLayout.Placed(line: line, origin: CGPoint(x: x, y: 0))], bounds: line.inkBounds.offsetBy(dx: x, dy: 0))
            }
            return Self.spriteKitLine(line, horizontal: horizontalAlignmentMode, vertical: verticalAlignmentMode)
        }
        return Self.spriteKitParagraph(lines, metrics: metrics, horizontal: horizontalAlignmentMode, vertical: verticalAlignmentMode)
    }

    /// Lines as SpriteKit lays out a label of more than one line (any
    /// `numberOfLines` but 1, measured against `SpriteKit.SKLabelNode`):
    /// the frame is the typographic block, not the ink, the widest line's
    /// advance rounded up and padded by 1 a side, and from 1 above the first
    /// line's ascent to the last line's descent, rounded out, and 1 below. Each line advances by the font's ascent, descent
    /// and leading rounded to whole points, and starts at the block's left
    /// edge whatever the alignment, which places the block alone. In
    /// `.baseline`, as in `.bottom`, the whole block stands above the origin.
    static func spriteKitParagraph(
        _ lines: [TextLine],
        metrics: FontMetrics,
        horizontal: SKLabelHorizontalAlignmentMode,
        vertical: SKLabelVerticalAlignmentMode
    ) -> TextLayout {
        let ascent = metrics.ascent.rounded()
        let advance = ascent + metrics.descent.rounded() + metrics.leading.rounded()
        let width = (lines.map(\.advance).max() ?? 0).rounded(.up) + 2
        // 1 above the first ascent, the last line down to its descent, then
        // rounded out and 1 more below.
        let height = (1 + ascent + CGFloat(lines.count - 1) * advance + metrics.descent).rounded(.up) + 1
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
        let firstBaseline = y + height - 1 - ascent
        let placed = lines.enumerated().map { index, line in
            TextLayout.Placed(line: line, origin: CGPoint(x: x + 1, y: firstBaseline - CGFloat(index) * advance))
        }
        return TextLayout(lines: placed, bounds: CGRect(x: x, y: y, width: width, height: height))
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
