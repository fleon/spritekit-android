#if SPRITEKIT_SHIM
import Foundation

/// The seam between the layer and the text stack.
///
/// The shim deliberately does not link FreeType or HarfBuzz itself: it would
/// put two C libraries in the way of `swift build` for everyone working on the
/// scene graph, the actions or the renderer, none of whom need them. Instead
/// `SKLabelNode` and `UIFont` ask whatever provider has been registered, and
/// the `TextShaping` module in `Android/Text` registers one backed by
/// HarfBuzz and FreeType.
///
/// With no provider registered, labels report an empty frame exactly as they
/// did before any of this — an honest nothing rather than a plausible wrong
/// number, which is the same rule the rest of the layer follows.
public enum TextMetrics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered: TextProvider?

    /// Installed once, at start-up, by whatever owns the font files.
    public static var provider: TextProvider? {
        get { lock.lock(); defer { lock.unlock() }; return registered }
        set { lock.lock(); defer { lock.unlock() }; registered = newValue }
    }
}

/// UIKit's string measuring (`NSAttributedString.size()`), apart from UIKit
/// so it tests on the Mac against AppKit's.
public enum StringDrawing {
    /// One line's width: its advance, plus the letter spacing after every
    /// character — the last one's included, as UIKit and AppKit count it.
    public static func width(of text: String, font: FontKey, kern: CGFloat) -> CGFloat {
        guard let provider = TextMetrics.provider else { return 0 }
        return provider.measure(text, font: font).advance + kern * CGFloat(text.count)
    }
}

/// A font as an attributed string's `.font` carries it: what
/// `SKLabelNode.attributedText` takes the face and size from. `UIFont` is
/// one.
public protocol LabelFont {
    var fontName: String { get }
    var pointSize: CGFloat { get }
}

/// A font as a label names it: the family or named-instance name the game
/// passes to `SKLabelNode.fontName`, and a point size.
public struct FontKey: Hashable, Sendable {
    public var name: String
    public var size: CGFloat

    public init(name: String, size: CGFloat) {
        self.name = name
        self.size = size
    }
}

/// A face's vertical metrics at one size, in points.
///
/// `lineHeight` is `ascent + descent + leading`, as UIKit reports it, so the
/// game's `DesignSystem` line-height ratios keep their meaning.
public struct FontMetrics: Equatable, Sendable {
    public var ascent: CGFloat
    public var descent: CGFloat
    public var leading: CGFloat
    public var capHeight: CGFloat
    public var xHeight: CGFloat

    public init(
        ascent: CGFloat,
        descent: CGFloat,
        leading: CGFloat,
        capHeight: CGFloat,
        xHeight: CGFloat
    ) {
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.capHeight = capHeight
        self.xHeight = xHeight
    }

    public var lineHeight: CGFloat { ascent + descent + leading }
}

/// One laid-out line: the text, how far the pen travels across it, and the
/// box the ink actually covers measured from the pen's origin on the baseline
/// (so `minY` is negative under the baseline and `maxY` positive above it).
public struct TextLine: Equatable, Sendable {
    public var text: String
    public var advance: CGFloat
    public var inkBounds: CGRect

    public init(text: String, advance: CGFloat, inkBounds: CGRect) {
        self.text = text
        self.advance = advance
        self.inkBounds = inkBounds
    }
}

/// A whole label, broken and placed: each line with the pen origin the
/// renderer should start it at, in the label node's own coordinates.
///
/// The shim works this out once, so the renderer draws from it rather than
/// measuring again, and so `contentFrame` and what is drawn can never drift
/// apart.
public struct TextLayout: Equatable, Sendable {
    public struct Placed: Equatable, Sendable {
        public var line: TextLine
        /// Where the first glyph's pen starts, on the baseline.
        public var origin: CGPoint

        public init(line: TextLine, origin: CGPoint) {
            self.line = line
            self.origin = origin
        }
    }

    public var lines: [Placed]
    public var bounds: CGRect

    public init(lines: [Placed], bounds: CGRect) {
        self.lines = lines
        self.bounds = bounds
    }
}

/// What the layer needs from a text engine. Everything here is measurement:
/// rasterising and the glyph atlas sit behind the renderer's side of the
/// `DrawList`, not here.
public protocol TextProvider: AnyObject, Sendable {
    /// Nil when the face cannot be found, which keeps labels at `.zero`
    /// rather than guessing at a fallback the game never asked for.
    func fontMetrics(_ font: FontKey) -> FontMetrics?

    /// Shapes `text` as one line and reports its advance and ink box.
    func measure(_ text: String, font: FontKey) -> TextLine

    /// Breaks `text` into lines no wider than `maxWidth`, at the places the
    /// script allows — which for Thai, Chinese and Japanese is not at spaces.
    func breakLines(_ text: String, font: FontKey, maxWidth: CGFloat) -> [String]

    /// Every place a line may start, as **UTF-16 offsets** into `text`,
    /// ascending. `Typesetting` works in those because CoreText does, and
    /// because the game slices the result with `NSString.substring(with:)`.
    func breakOffsets(in text: String) -> [Int]
}

#endif
