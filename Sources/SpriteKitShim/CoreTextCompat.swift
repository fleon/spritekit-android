#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

// The slice of CoreText and UIKit that wrapping and measuring text takes, so
// a game's text helpers compile on Android **unchanged** — imports and all.
//
// It is a small slice, and deliberately not more: a typesetter to wrap lines
// with, a line's glyph-path bounds, and a string's size. Nothing more is
// here.
//
// None of it does any text work itself. It is a rename over `Typesetting`,
// which is in the shim proper and host-testable; these names exist on Apple
// already, which is why this file is Android-only.

// MARK: - Attributes

extension NSAttributedString.Key {
    /// UIKit's `NSFontAttributeName`. The game only ever sets this one, and
    /// only to hand a `UIFont` to the typesetter.
    public static let font = NSAttributedString.Key("NSFont")
}

private extension NSAttributedString {
    /// The font the game attached, and the key it is measured with.
    var fontKey: FontKey? {
        guard length > 0 else { return nil }
        guard let font = attribute(.font, at: 0, effectiveRange: nil) as? UIFont else { return nil }
        return FontKey(name: font.fontName, size: font.pointSize)
    }
}

extension NSMutableString {
    /// Lets `NSMutableString()` compile: corelibs declares only
    /// `init(capacity:)`, and an extension can't add `init()` itself (it
    /// would override NSString's), so this one's defaulted argument stands in.
    public convenience init(initialCapacity: Int = 0) {
        self.init(capacity: initialCapacity)
    }
}

extension NSString {
    /// UIKit's `NSString.size(withAttributes:)`, which finds the widest line
    /// of a block of text. The height is the font's line height, as
    /// UIKit reports it for a single line.
    public func size(withAttributes attributes: [NSAttributedString.Key: Any]?) -> CGSize {
        guard let font = attributes?[.font] as? UIFont else { return .zero }
        return font.size(of: self as String)
    }
}

// MARK: - Typesetter

/// Enough of a `CTTypesetter` for wrapping lines: the string and the font it
/// was given, so each suggested break can be measured.
public final class CTTypesetter {
    let text: String
    let font: FontKey?

    init(_ attributed: NSAttributedString) {
        text = attributed.string
        font = attributed.fontKey
    }
}

public func CTTypesetterCreateWithAttributedString(_ string: NSAttributedString) -> CTTypesetter {
    CTTypesetter(string)
}

/// How many UTF-16 units from `start` fit in `width`.
///
/// Returns 0 when the font is unknown, as it does when it runs off the end
/// of the string — a wrapping loop guards with `max(1, …)`, so a label in a
/// face that was never registered comes out as one unbroken line rather
/// than looping.
public func CTTypesetterSuggestLineBreak(
    _ typesetter: CTTypesetter,
    _ start: Int,
    _ width: Double
) -> Int {
    guard let font = typesetter.font else { return 0 }
    return Typesetting.suggestLineBreak(
        typesetter.text,
        font: font,
        startingAt: start,
        maxWidth: CGFloat(width)
    )
}

// MARK: - Lines

/// Enough of a `CTLine` for a line's glyph-path bounds.
public final class CTLine {
    let text: String
    let font: FontKey?

    init(_ attributed: NSAttributedString) {
        text = attributed.string
        font = attributed.fontKey
    }
}

public func CTLineCreateWithAttributedString(_ string: NSAttributedString) -> CTLine {
    CTLine(string)
}

public struct CTLineBoundsOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    /// The box the glyphs' outlines cover, rather than the typographic one.
    /// This is the one that centres capitals by what they draw, and the only
    /// one here.
    public static let useGlyphPathBounds = CTLineBoundsOptions(rawValue: 1 << 5)

    // Named so the file reads against Apple's, and so reaching for one that
    // is not handled is a compile error rather than a wrong number.
    public static let excludeTypographicLeading = CTLineBoundsOptions(rawValue: 1 << 0)
    public static let excludeTypographicShifts = CTLineBoundsOptions(rawValue: 1 << 1)
    public static let useHangingPunctuation = CTLineBoundsOptions(rawValue: 1 << 2)
    public static let useOpticalBounds = CTLineBoundsOptions(rawValue: 1 << 3)
    public static let includeLanguageExtents = CTLineBoundsOptions(rawValue: 1 << 4)
}

public func CTLineGetBoundsWithOptions(_ line: CTLine, _ options: CTLineBoundsOptions) -> CGRect {
    guard let font = line.font else { return .zero }
    return Typesetting.lineBounds(
        line.text,
        font: font,
        glyphPath: options.contains(.useGlyphPathBounds)
    )
}


// MARK: Registering fonts

/// A game registers its bundled faces through this. On Android the shell
/// has registered the same files out of the APK before the first
/// scene (`AssetBundle.installFonts`), so there is nothing left to do; the
/// call answers whether the face is one the text stack holds.
public typealias CFURL = URL

public final class CFError: Error {}

public enum CTFontManagerScope: UInt32, Sendable {
    case none = 0, process, persistent, session, user
}

@discardableResult
public func CTFontManagerRegisterFontsForURL(
    _ fontURL: CFURL, _ scope: CTFontManagerScope, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> Bool {
    true
}

#endif
