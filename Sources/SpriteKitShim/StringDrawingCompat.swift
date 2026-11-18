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
    /// The font, colour and alignment UIKit draws the string with, from its
    /// first character: one run of attributes, as a game builds a label's.
    /// Helvetica 12 in black where none is given, UIKit's defaults.
    private var drawingAttributes: (font: FontKey, colour: SKColor, style: NSParagraphStyle) {
        let attributes = length > 0 ? self.attributes(at: 0, effectiveRange: nil) : [:]
        let font = attributes[.font] as? UIFont
        return (
            FontKey(name: font?.fontName ?? "Helvetica", size: font?.pointSize ?? 12),
            attributes[.foregroundColor] as? SKColor ?? .black,
            attributes[.paragraphStyle] as? NSParagraphStyle ?? .default
        )
    }

    /// With `.usesLineFragmentOrigin`, the text wrapped to `size.width` and
    /// measured as lines; without, one line from the baseline, as UIKit
    /// measures it. The origin is zero.
    public func boundingRect(with size: CGSize, options: NSStringDrawingOptions, context: NSStringDrawingContext?) -> CGRect {
        let (font, _, _) = drawingAttributes
        let wraps = options.contains(.usesLineFragmentOrigin)
        guard let block = TextBlock(string, font: font, maxWidth: wraps ? size.width : nil,
                                    usesFontLeading: options.contains(.usesFontLeading)) else { return .zero }
        guard wraps else {
            // One line, its height from the baseline's ascent down.
            let line = block.lines.map(\.width).max() ?? 0
            return CGRect(x: 0, y: -block.ascent, width: line, height: block.lineHeight)
        }
        return CGRect(origin: .zero, size: block.size)
    }

    /// Draws the string in the current context (`UIGraphicsPushContext`),
    /// wrapped to `rect`'s width and aligned across it by its paragraph
    /// style.
    public func draw(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let (font, colour, style) = drawingAttributes
        guard let block = TextBlock(string, font: font, maxWidth: rect.width) else { return }
        block.draw(in: rect, alignment: Self.alignment(style.alignment), colour: colour, context: context)
    }

    /// Draws the string on one line per paragraph, its top-left at `point`.
    public func draw(at point: CGPoint) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let (font, colour, _) = drawingAttributes
        guard let block = TextBlock(string, font: font, maxWidth: nil) else { return }
        block.draw(in: CGRect(origin: point, size: block.size), alignment: .left, colour: colour, context: context)
    }

    private static func alignment(_ alignment: NSTextAlignment) -> TextBlock.Alignment {
        switch alignment {
        case .center: .center
        case .right: .right
        case .left, .justified, .natural: .left
        }
    }
}
#endif
