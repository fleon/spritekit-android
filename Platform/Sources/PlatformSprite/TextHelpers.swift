import Foundation
#if canImport(Darwin)
import CoreText
#endif
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
import UIKit
#endif

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

// UIKit's fonts, labels and text blocks: everywhere but the Mac host the
// tests run on, which has CoreText but no `UIFont`.
#if canImport(UIKit) || !canImport(Darwin)

/// Splits `text` into lines no wider than `maxWidth` in `font`.
public func wrappedLines(_ text: String, maxWidth: CGFloat, font: UIFont) -> [String] {
    wrappedLines(text, maxWidth: maxWidth, attributes: [.font: font])
}

/// The fonts and line heights text blocks are set in: a game's own faces,
/// and taller lines for the scripts that need them.
public nonisolated enum Typography {
    /// The font for a weight and size.
    public nonisolated(unsafe) static var font: (_ weight: UIFont.Weight, _ size: CGFloat) -> UIFont = { weight, size in
        .systemFont(ofSize: size, weight: weight)
    }

    /// Text blocks' line height, as a multiple of their font size (read as
    /// each block is built, so it can follow the language).
    public nonisolated(unsafe) static var lineHeightRatio: () -> CGFloat = { 1.2 }

    /// Sets text as `localizer`'s current language asks: in its script's
    /// own face where it has one, else `base`, with its line height.
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
}

extension UIFont {
    /// How far a `.center` label of `text` in this font moves so its
    /// capitals, not its ink, sit centred: `.center` centres the glyphs
    /// drawn, so descenders would lift the capitals and tall letters lower them.
    public func capitalsOffset(_ text: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: self]))
        return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).midY - capHeight / 2
    }
}

extension SKLabelNode {
    /// Centres a `.center` label's capitals on `point` at its current scale,
    /// as buttons centre their labels, so it lines up with what stands
    /// beside it whatever its letters.
    public func centerCapitals(on point: CGPoint) {
        let font = fontName.flatMap { UIFont(name: $0, size: fontSize) }
        let offset = text.flatMap { font?.capitalsOffset($0) } ?? 0
        position = pt(point.x, point.y + offset * yScale)
    }
}

/// A multi-line label block, in `Typography`'s font and line height. The
/// node's origin is the top of the first line; `height` is the block's full
/// height.
public final class TextBlockNode: SKNode {
    public let height: CGFloat
    public let width: CGFloat

    public init(
        _ text: String,
        maxWidth: CGFloat,
        weight: UIFont.Weight,
        fontSize: CGFloat,
        color: UIColor,
        alignment: SKLabelHorizontalAlignmentMode = .center,
        lineSpacing: CGFloat = 0
    ) {
        let font = Typography.font(weight, fontSize)
        let lines = wrappedLines(text, maxWidth: maxWidth, font: font)
        let lineHeight = fontSize * Typography.lineHeightRatio() + lineSpacing
        height = CGFloat(lines.count) * lineHeight - lineSpacing
        width = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        super.init()
        for (index, line) in lines.enumerated() {
            let label = SKLabelNode()
            label.fontName = font.fontName
            label.fontSize = fontSize
            label.text = line
            label.fontColor = color
            label.horizontalAlignmentMode = alignment
            label.verticalAlignmentMode = .center
            label.position = pt(0, -lineHeight * (CGFloat(index) + 0.5) + lineSpacing / 2)
            addChild(label)
        }
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#endif
