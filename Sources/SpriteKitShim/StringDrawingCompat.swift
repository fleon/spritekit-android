#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

// UIKit's string drawing and its context stack, over `TextBlock`. These
// names exist on Apple already, which is why this file is Android-only.

// MARK: - The context stack

/// UIKit's current context: the innermost pushed, or the renderer's.
public func UIGraphicsGetCurrentContext() -> BitmapContext? {
    UIImage.contexts.last
}

/// Makes `context` the one UIKit draws into (strings, `setFill()`), as a
/// game does around drawing into a bitmap of its own.
public func UIGraphicsPushContext(_ context: BitmapContext) {
    UIImage.contexts.append(context)
}

public func UIGraphicsPopContext() {
    _ = UIImage.contexts.popLast()
}

// MARK: - Drawing options

public struct NSStringDrawingOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let usesLineFragmentOrigin = NSStringDrawingOptions(rawValue: 1 << 0)
    public static let usesFontLeading = NSStringDrawingOptions(rawValue: 1 << 1)
    public static let usesDeviceMetrics = NSStringDrawingOptions(rawValue: 1 << 3)
    public static let truncatesLastVisibleLine = NSStringDrawingOptions(rawValue: 1 << 5)
}

/// Taken and carried: nothing here scales text down to fit.
open class NSStringDrawingContext: NSObject, @unchecked Sendable {
    open var minimumScaleFactor: CGFloat = 0
    open private(set) var actualScaleFactor: CGFloat = 1
    open private(set) var totalBounds: CGRect = .zero

    public override init() {}
}

// MARK: - Measuring and drawing

extension NSAttributedString {
    /// The string's runs of attributes as UIKit draws them: each run's font
    /// (Helvetica 12 where none is given, UIKit's default), colour (black),
    /// letter spacing, baseline offset and paragraph style.
    var textRuns: [TextBlock.Run] {
        guard length > 0 else { return [] }
        var runs: [TextBlock.Run] = []
        let string = self.string as NSString
        enumerateAttributes(in: NSRange(location: 0, length: length), options: []) { attributes, range, _ in
            func number(_ value: Any?) -> CGFloat {
                switch value {
                case let number as NSNumber: CGFloat(number.doubleValue)
                case let value as CGFloat: value
                case let value as Double: CGFloat(value)
                default: 0
                }
            }
            let font = attributes[.font] as? UIFont
            let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle ?? .default
            runs.append(TextBlock.Run(
                string.substring(with: range),
                font: FontKey(name: font?.fontName ?? "Helvetica", size: font?.pointSize ?? 12),
                colour: attributes[.foregroundColor] as? SKColor ?? .black,
                kern: number(attributes[.kern]),
                baselineOffset: number(attributes[NSAttributedString.Key("NSBaselineOffset")]),
                style: Self.style(paragraph)
            ))
        }
        return runs
    }

    private static func style(_ paragraph: NSParagraphStyle) -> TextBlock.Style {
        let alignment: TextBlock.Alignment = switch paragraph.alignment {
        case .center: .center
        case .right: .right
        case .justified: .justified
        case .left: .left
        case .natural: .natural
        }
        return TextBlock.Style(
            alignment: alignment,
            wrapping: paragraph.lineBreakMode == .byCharWrapping ? .characters : .words,
            lineSpacing: paragraph.lineSpacing
        )
    }

    /// With `.usesLineFragmentOrigin`, the text wrapped to `size.width` and
    /// measured as lines, its lines placed by their alignment; without, its
    /// first line alone, measured from its baseline (y the rounded descent
    /// up) and no wider than `size.width`, as UIKit measures it.
    public func boundingRect(with size: CGSize, options: NSStringDrawingOptions, context: NSStringDrawingContext?) -> CGRect {
        TextBlock.boundingRect(of: textRuns, size: size, usesLineFragmentOrigin: options.contains(.usesLineFragmentOrigin),
                               usesFontLeading: options.contains(.usesFontLeading))
    }

    /// Draws the string in the current context (`UIGraphicsPushContext`),
    /// wrapped to `rect`'s width and aligned across it by its paragraph
    /// style: the lines that fit wholly in the rect.
    public func draw(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              let block = TextBlock(runs: textRuns, maxWidth: rect.width) else { return }
        block.draw(in: rect, context: context)
    }

    /// Draws the string on one line per paragraph, its top-left at `point`.
    public func draw(at point: CGPoint) {
        guard let context = UIGraphicsGetCurrentContext(),
              let block = TextBlock(runs: textRuns, maxWidth: nil) else { return }
        block.draw(in: CGRect(origin: point, size: block.size(in: nil)), context: context)
    }
}
#endif
