#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

// The slice of CoreText and UIKit that `Source/Utils/TextHelpers.swift`
// uses, so that file compiles on Android **unchanged** — imports and all.
//
// It is a small slice, and deliberately not more: `wrappedLines` runs a
// typesetter, `capitalsOffset` reads a line's glyph-path bounds, and
// `TextBlockNode` measures a string. Nothing else in the game reaches for
// CoreText, so nothing else is here.
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

extension NSString {
    /// UIKit's `NSString.size(withAttributes:)`, which `TextBlockNode` uses
    /// to find its widest line. The height is the font's line height, as
    /// UIKit reports it for a single line.
    public func size(withAttributes attributes: [NSAttributedString.Key: Any]?) -> CGSize {
        guard let font = attributes?[.font] as? UIFont else { return .zero }
        return font.size(of: self as String)
    }
}

// MARK: - Typesetter

/// Enough of a `CTTypesetter` for `wrappedLines`: the string and the font it
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
/// of the string — `wrappedLines` guards with `max(1, …)`, so a label in a
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

/// Enough of a `CTLine` for `capitalsOffset`.
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
    /// This is the only one the game asks for, and the one that makes
    /// `capitalsOffset` mean anything.
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

/// Switchlings' `FontRegistry` registers the bundled faces through this. On
/// Android the shell has registered every file in the APK's `fonts/` before
/// the first scene (`AssetBundle.installFonts`, as an iOS app's `UIAppFonts`
/// are), so there is nothing left to do; the call answers yes.
public typealias CFURL = URL
public typealias CFString = String

public final class CFError: Error {
    /// What went wrong, as CoreText's font manager names it.
    public let registration: FontRegistration

    init(_ registration: FontRegistration) {
        self.registration = registration
    }
}

public enum CTFontManagerScope: UInt32, Sendable {
    case none = 0, process, persistent, session, user
}

@discardableResult
public func CTFontManagerRegisterFontsForURL(
    _ fontURL: CFURL, _ scope: CTFontManagerScope, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> Bool {
    true
}

/// Registers each font file in `fontURLs` (`URL`s) with the text stack, then
/// calls `registrationHandler` once, with an error for each file that didn't
/// register and `true` for done, as CoreText does when it is through. A file
/// registered before is an error, as on Apple; one the shell registered at
/// launch is not, the first time the game registers it, since on Apple the
/// game's call is what registers it. The scope and `enabled` are Apple's
/// alone: here a registration lasts the process.
public func CTFontManagerRegisterFontURLs(
    _ fontURLs: CFArray,
    _ scope: CTFontManagerScope,
    _ enabled: Bool,
    _ registrationHandler: ((CFArray, Bool) -> Bool)?
) {
    var errors: [CFError] = []
    for case let url as URL in fontURLs {
        let result = TextMetrics.catalog?.registerFont(at: url.path) ?? .unreadable
        if result != .registered { errors.append(CFError(result)) }
    }
    _ = registrationHandler?(errors, true)
}

// MARK: Font descriptors

/// One face of a font file, as CoreText describes it before making a font
/// of it: here, its PostScript name.
public final class CTFontDescriptor {
    let postScriptName: String

    init(postScriptName: String) {
        self.postScriptName = postScriptName
    }
}

/// A face at a size, enough of a `CTFont` to name it.
public final class CTFont {
    let postScriptName: String
    let size: CGFloat

    init(postScriptName: String, size: CGFloat) {
        self.postScriptName = postScriptName
        self.size = size
    }
}

/// A descriptor for each face in the font file at `fileURL`, without
/// registering it: one for a plain file, one per named instance for a
/// variable font, as CoreText lists them. Nil for a file that isn't a font.
public func CTFontManagerCreateFontDescriptorsFromURL(_ fileURL: CFURL) -> CFArray? {
    guard let names = TextMetrics.catalog?.faceNames(inFontAt: fileURL.path) else { return nil }
    return names.map(CTFontDescriptor.init(postScriptName:))
}

/// The descriptor's face at `size`; 0 is CoreText's default, 12 points. The
/// matrix is not kept: the games pass none.
public func CTFontCreateWithFontDescriptor(
    _ descriptor: CTFontDescriptor,
    _ size: CGFloat,
    _ matrix: UnsafePointer<CGAffineTransform>?
) -> CTFont {
    CTFont(postScriptName: descriptor.postScriptName, size: size == 0 ? 12 : size)
}

public func CTFontCopyPostScriptName(_ font: CTFont) -> CFString {
    font.postScriptName
}

public func CTFontGetSize(_ font: CTFont) -> CGFloat {
    font.size
}

#endif
