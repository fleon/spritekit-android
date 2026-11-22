import Foundation
#if canImport(Darwin)
import CoreText
#endif
import SpriteKitShim

/// Splits `text` into lines no wider than `maxWidth` set with `attributes`
/// (`.font` at least). CoreText picks the breaks, so scripts without spaces
/// between words (Chinese, Japanese, Thai) wrap where their rules allow;
/// on Android the shim's CoreText breaks them as Apple's does.
public func wrappedLines(_ text: String, maxWidth: CGFloat, attributes: [NSAttributedString.Key: Any]) -> [String] {
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let string = attributed.string as NSString
    var lines: [String] = []
    var start = 0
    while start < string.length {
        let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth)))
        let line = string.substring(with: NSRange(location: start, length: count))
        lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
        start += count
    }
    return lines.filter { !$0.isEmpty }
}

/// The band of a font's height that text is aligned by: read from the
/// font's metrics alone, so every string in one font and size sits on the
/// same baseline, whatever its letters. (SpriteKit's `.center`, `.top` and
/// `.bottom` align the ink of the glyphs in the string instead, so a
/// descender, a tall capital or a stacked mark moves the whole line.)
public nonisolated enum TextBand: Sendable, Equatable {
    /// Baseline to cap height: capitals sit centred, whatever hangs below
    /// or rises above them. For scripts with capitals (Latin, Greek,
    /// Cyrillic).
    case capitals
    /// Descender to ascender: the font's whole line. For scripts without
    /// capitals whose marks stack above and below (Thai, Lao, Khmer,
    /// Burmese), whose typical line's ink centres on it.
    case line

    /// The band's bottom and top, above the baseline, in a font with these
    /// metrics (`descender` negative, as UIKit has it).
    public func span(ascender: CGFloat, descender: CGFloat, capHeight: CGFloat) -> (bottom: CGFloat, top: CGFloat) {
        switch self {
        case .capitals: (0, capHeight)
        case .line: (descender, ascender)
        }
    }

    /// The baseline's y for text whose band is aligned `mode` at `y`:
    /// centred on it, its top or its bottom there, or (`.baseline`) the
    /// baseline itself.
    public func baseline(
        _ mode: SKLabelVerticalAlignmentMode,
        at y: CGFloat,
        ascender: CGFloat,
        descender: CGFloat,
        capHeight: CGFloat
    ) -> CGFloat {
        let span = span(ascender: ascender, descender: descender, capHeight: capHeight)
        return switch mode {
        case .center: y - (span.bottom + span.top) / 2
        case .top: y - span.top
        case .bottom: y - span.bottom
        default: y
        }
    }

    /// The band a language sets its text by: `.line` for the scripts that
    /// stack marks above and below and have no capitals (Thai, Lao, Khmer,
    /// Burmese), `.capitals` for the rest. `code` is a language code
    /// ("th", "pt-BR").
    public static func forLanguage(_ code: String) -> TextBand {
        let language = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        return ["th", "lo", "km", "my"].contains(language) ? .line : .capitals
    }
}

/// The fonts, line heights and text band text is set in: a game's own
/// faces, and the lines and band the language's script needs.
public nonisolated enum Typography {
    /// The band labels are aligned by when none is given (read as each
    /// label is placed, so it can follow the language).
    public nonisolated(unsafe) static var textBand: () -> TextBand = { .capitals }
}

/// A font's vertical metrics, by name and size: `UIFont`'s, or on the Mac
/// host the tests run on (which has no `UIFont`) CoreText's.
nonisolated struct FontBandMetrics: Equatable {
    var ascender: CGFloat
    var descender: CGFloat
    var capHeight: CGFloat

    init(ascender: CGFloat, descender: CGFloat, capHeight: CGFloat) {
        self.ascender = ascender
        self.descender = descender
        self.capHeight = capHeight
    }

    /// SpriteKit's own face when a label names none.
    static let defaultFontName = "HelveticaNeue-UltraLight"

    init(fontNamed name: String?, size: CGFloat) {
        #if canImport(UIKit) || !canImport(Darwin)
        let font = UIFont(name: name ?? Self.defaultFontName, size: size) ?? .systemFont(ofSize: size)
        self.init(ascender: font.ascender, descender: font.descender, capHeight: font.capHeight)
        #else
        let font = CTFontCreateWithName((name ?? Self.defaultFontName) as CFString, size, nil)
        self.init(ascender: CTFontGetAscent(font), descender: -CTFontGetDescent(font), capHeight: CTFontGetCapHeight(font))
        #endif
    }

    func baseline(_ mode: SKLabelVerticalAlignmentMode, at y: CGFloat, band: TextBand) -> CGFloat {
        band.baseline(mode, at: y, ascender: ascender, descender: descender, capHeight: capHeight)
    }
}

extension SKLabelNode {
    /// Sets the label on its baseline (`.baseline`) at `point`, moved so
    /// its font's `band` is aligned `mode` there: centred on it, its top or
    /// its bottom at it. Use it, never `.center`, `.top` or `.bottom`, which
    /// align the string's ink and so move with its letters.
    ///
    /// On a plain `SKLabelNode` it is one-shot: it bakes the offset into
    /// `position`, from the font, size and `yScale` as they are now, so call
    /// it after the label's last `position`, font or scale change (a later
    /// `position = …` puts the baseline there), and scaling pivots at the
    /// baseline. An `AlignedLabelNode` (what `label(... .vAlign(.center))`
    /// makes) keeps `mode` and `band` and moves to `point`, and stays
    /// aligned through every later change.
    public func align(_ mode: SKLabelVerticalAlignmentMode, at point: CGPoint, band: TextBand = Typography.textBand()) {
        if let aligned = self as? AlignedLabelNode {
            aligned.band = band
            aligned.verticalAlignmentMode = mode
            aligned.position = point
            return
        }
        verticalAlignmentMode = .baseline
        let metrics = FontBandMetrics(fontNamed: fontName, size: fontSize)
        let baseline = metrics.baseline(mode, at: 0, band: band)
        position = pt(point.x, point.y + baseline * yScale)
    }

    /// Centres the label's font `band` on `point`, its baseline where the
    /// font puts it whatever its letters (`align(.center, at:band:)`):
    /// one-shot on a plain `SKLabelNode`, kept by an `AlignedLabelNode`.
    public func centerVertically(on point: CGPoint, band: TextBand = Typography.textBand()) {
        align(.center, at: point, band: band)
    }
}

/// The baselines of `count` lines `advance` apart, top first. Hanging
/// from the top (`bandMiddle` given) the first line's height is centred
/// half an advance, less half the spacing, below the origin and each line's
/// baseline sits `bandMiddle` below its centre; else the first baseline is
/// at zero.
nonisolated func textBlockBaselines(count: Int, advance: CGFloat, lineSpacing: CGFloat, bandMiddle: CGFloat?) -> [CGFloat] {
    (0 ..< count).map { index in
        guard let bandMiddle else { return -advance * CGFloat(index) }
        return -advance * (CGFloat(index) + 0.5) + lineSpacing / 2 - bandMiddle
    }
}

// UIKit's fonts, labels and text blocks: everywhere but the Mac host the
// tests run on, which has CoreText but no `UIFont`.
#if canImport(UIKit) || !canImport(Darwin)

/// Splits `text` into lines no wider than `maxWidth` in `font`.
public func wrappedLines(_ text: String, maxWidth: CGFloat, font: UIFont) -> [String] {
    wrappedLines(text, maxWidth: maxWidth, attributes: [.font: font])
}

extension Typography {
    /// The font for a weight and size.
    public nonisolated(unsafe) static var font: (_ weight: UIFont.Weight, _ size: CGFloat) -> UIFont = { weight, size in
        .systemFont(ofSize: size, weight: weight)
    }

    /// Text blocks' line height, as a multiple of their font size (read as
    /// each block is built, so it can follow the language).
    public nonisolated(unsafe) static var lineHeightRatio: () -> CGFloat = { 1.2 }

    /// Sets text as `localizer`'s current language asks: in its script's
    /// own face where it has one, else `base`, with its line height and
    /// text band.
    public static func follow<Language: ScriptedLanguage>(
        _ localizer: Localizer<Language>,
        base: @escaping (_ weight: UIFont.Weight, _ size: CGFloat) -> UIFont
    ) {
        font = { weight, size in
            if let name = localizer.current.scriptFontName(weight), let font = UIFont(name: name, size: size) {
                return font
            }
            return base(weight, size)
        }
        lineHeightRatio = { localizer.current.lineHeightRatio }
        textBand = { localizer.current.textBand }
    }
}

/// A language whose script may need a face of its own (one the game's
/// main face lacks) and taller or shorter lines.
public protocol ScriptedLanguage: LocalizationLanguage {
    /// The face to set this language in at `weight`, registering it first
    /// (`FontRegistry`); nil for the game's main face.
    func scriptFontName(_ weight: UIFont.Weight) -> String?
    /// Text blocks' line height, as a multiple of their font size.
    var lineHeightRatio: CGFloat { get }
    /// The band labels in this language are aligned by.
    var textBand: TextBand { get }
}

extension ScriptedLanguage {
    /// By the language's script, from its raw value as a language code
    /// (`TextBand.forLanguage`).
    public var textBand: TextBand { TextBand.forLanguage(rawValue) }
}

extension UIFont {
    /// The baseline's y for a line in this font whose `band` is aligned
    /// `mode` at `y`: the same for every string.
    public func baseline(_ mode: SKLabelVerticalAlignmentMode, at y: CGFloat, band: TextBand = Typography.textBand()) -> CGFloat {
        band.baseline(mode, at: y, ascender: ascender, descender: descender, capHeight: capHeight)
    }

    /// How far a `.center` label of `text` in this font moves so its
    /// capitals, not its ink, sit centred.
    @available(*, deprecated, message: "Set the label on its baseline with centerVertically(on:band:), which reads the font's metrics, not the text's ink")
    public func capitalsOffset(_ text: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: self]))
        return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).midY - capHeight / 2
    }
}

extension SKLabelNode {
    /// Centres a `.center` label's capitals on `point` at its current scale.
    @available(*, deprecated, message: "Use centerVertically(on:band:), which sets the label on its baseline by the font's metrics")
    public func centerCapitals(on point: CGPoint) {
        let font = fontName.flatMap { UIFont(name: $0, size: fontSize) }
        let offset = text.flatMap { font?.capitalsOffset($0) } ?? 0
        position = pt(point.x, point.y + offset * yScale)
    }
}

/// A multi-line label block, in `Typography`'s font, line height and text
/// band unless given its own. Every line sits on its baseline, so lines
/// with and without descenders or stacked marks are evenly spaced. With
/// `anchor: .top` (the default) the node's origin is the top of the first
/// line, each line's `band` centred in its height; with `.firstBaseline`
/// it is the first line's baseline. `height` is the block's full height.
public final class TextBlockNode: SKNode {
    /// Where the block hangs from its origin.
    public enum Anchor {
        /// The top of the first line; each line's text band centred in its
        /// own height.
        case top
        /// The first line's baseline.
        case firstBaseline
    }

    /// How far apart lines are, before `lineSpacing`.
    public enum LineHeight {
        /// The font size times `Typography.lineHeightRatio`.
        case typography
        /// The font's own ascender to descender.
        case font
    }

    public let height: CGFloat
    public let width: CGFloat
    /// The font the lines are set in.
    public let font: UIFont
    /// From one line's baseline to the next: the line height and its
    /// spacing.
    public let lineAdvance: CGFloat
    /// The lines, top first.
    public let lines: [SKLabelNode]

    public convenience init(
        _ text: String,
        maxWidth: CGFloat,
        weight: UIFont.Weight,
        fontSize: CGFloat,
        color: UIColor,
        alignment: SKLabelHorizontalAlignmentMode = .center,
        lineSpacing: CGFloat = 0,
        anchor: Anchor = .top,
        lineHeight: LineHeight = .typography,
        band: TextBand = Typography.textBand()
    ) {
        self.init(
            text, maxWidth: maxWidth, font: Typography.font(weight, fontSize), color: color,
            alignment: alignment, lineSpacing: lineSpacing, anchor: anchor, lineHeight: lineHeight, band: band
        )
    }

    public init(
        _ text: String,
        maxWidth: CGFloat,
        font: UIFont,
        color: UIColor,
        alignment: SKLabelHorizontalAlignmentMode = .center,
        lineSpacing: CGFloat = 0,
        anchor: Anchor = .top,
        lineHeight: LineHeight = .typography,
        band: TextBand = Typography.textBand()
    ) {
        let fontSize = font.pointSize
        let texts = wrappedLines(text, maxWidth: maxWidth, font: font)
        let ownHeight = switch lineHeight {
        case .typography: fontSize * Typography.lineHeightRatio()
        case .font: font.ascender - font.descender
        }
        let advance = ownHeight + lineSpacing
        lineAdvance = advance
        height = CGFloat(texts.count) * advance - lineSpacing
        width = texts.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        self.font = font
        let bandMiddle: CGFloat? = switch anchor {
        case .top: -font.baseline(.center, at: 0, band: band)
        case .firstBaseline: nil
        }
        let baselines = textBlockBaselines(count: texts.count, advance: advance, lineSpacing: lineSpacing, bandMiddle: bandMiddle)
        lines = zip(texts, baselines).map { line, baseline in
            let label = SKLabelNode()
            label.fontName = font.fontName
            label.fontSize = fontSize
            label.text = line
            label.fontColor = color
            label.horizontalAlignmentMode = alignment
            label.verticalAlignmentMode = .baseline
            label.position = pt(0, baseline)
            return label
        }
        super.init()
        lines.forEach(addChild)
    }

    /// The last line's baseline, below the origin.
    public var lastBaselineY: CGFloat { lines.last?.position.y ?? 0 }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#endif
