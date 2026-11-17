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

    nonisolated(unsafe) private static var registeredCatalog: FontCatalog?

    /// Installed once, at start-up, by whatever owns the font files.
    public static var provider: TextProvider? {
        get { lock.lock(); defer { lock.unlock() }; return registered }
        set { lock.lock(); defer { lock.unlock() }; registered = newValue }
    }

    /// The font files behind the provider: what CoreText's font manager and
    /// `UIFont(name:size:)` ask. Nil where no text stack is installed (a host
    /// test of the scene graph), where every name is taken on trust, as
    /// before the stack could answer.
    public static var catalog: FontCatalog? {
        get { lock.lock(); defer { lock.unlock() }; return registeredCatalog }
        set { lock.lock(); defer { lock.unlock() }; registeredCatalog = newValue }
    }
}

/// What a font file holds and which faces are registered, in CoreText's
/// terms: a face is asked for by its PostScript name (or its family's), one
/// file can hold several (a variable font's named instances), and a face is
/// usable once its file has been registered.
public protocol FontCatalog: AnyObject, Sendable {
    /// The PostScript names of the faces in the file at `path`, as
    /// `CTFontManagerCreateFontDescriptorsFromURL` lists them — a variable
    /// font's named instances, else the one face — without registering it.
    /// Nil when the file can't be read as a font.
    func faceNames(inFontAt path: String) -> [String]?

    /// Registers the file at `path` for the game, as
    /// `CTFontManagerRegisterFontURLs` does.
    func registerFont(at path: String) -> FontRegistration

    /// Whether `name` (a PostScript, instance or family name) is a face the
    /// stack can draw now.
    func hasFace(named name: String) -> Bool

    /// The registered faces standing for the system font, by name. The
    /// device's own (Roboto on Android), the way the system font on Apple is
    /// SF.
    var systemFaceNames: [String] { get }
}

/// What registering a font file came to, as CoreText reports it: a second
/// registration of the same file is an error there (`kCTFontManagerErrorAlreadyRegistered`),
/// and so is a file that isn't a font.
public enum FontRegistration: Equatable, Sendable {
    case registered
    case alreadyRegistered
    case unreadable
}

/// The system font's faces by weight: which of the registered faces
/// `UIFont.systemFont(ofSize:weight:)` draws with.
public enum SystemFontFaces {
    /// A face's weight class (CSS and OpenType's 100–900) from the style its
    /// name ends in: "Roboto-SemiBold" is 600.
    static let styleWeights: [(style: String, weight: Int)] = [
        ("Thin", 100), ("ExtraLight", 200), ("UltraLight", 200), ("Light", 300),
        ("Regular", 400), ("Medium", 500), ("SemiBold", 600), ("DemiBold", 600),
        ("Bold", 700), ("ExtraBold", 800), ("Heavy", 800), ("Black", 900),
    ]

    /// UIKit's weights (`UIFont.Weight.rawValue`, -0.8 to 0.62) as weight
    /// classes, as SF's faces carry them: `.ultraLight` is SF Ultralight,
    /// 100, through `.black`, 900.
    static func weightClass(_ weight: CGFloat) -> Int {
        let classes: [(weight: CGFloat, weightClass: Int)] = [
            (-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500),
            (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900),
        ]
        return classes.min { abs($0.weight - weight) < abs($1.weight - weight) }?.weightClass ?? 400
    }

    /// The face among `names` for a UIKit weight: upright faces only, by the
    /// nearest weight class, and between two equally near the heavier above
    /// regular and the lighter below it, as CSS font matching picks. Nil
    /// when none of the names says its weight.
    public static func face(forWeight weight: CGFloat, among names: [String]) -> String? {
        let target = weightClass(weight)
        let weighted = names.compactMap { name -> (name: String, weight: Int)? in
            guard let dash = name.lastIndex(of: "-") else { return nil }
            let style = String(name[name.index(after: dash)...])
            guard let entry = styleWeights.first(where: { $0.style == style }) else { return nil }
            return (name, entry.weight)
        }
        return weighted.min { a, b in
            let da = abs(a.weight - target), db = abs(b.weight - target)
            if da != db { return da < db }
            return target >= 400 ? a.weight > b.weight : a.weight < b.weight
        }?.name
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
