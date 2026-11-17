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
    /// UIKit's `NSFontAttributeName`: a `UIFont`, for the typesetter and for
    /// `SKLabelNode.attributedText`.
    public static let font = NSAttributedString.Key("NSFont")
    /// UIKit's `NSForegroundColorAttributeName`: the text's colour.
    public static let foregroundColor = NSAttributedString.Key("NSColor")
    /// UIKit's `NSKernAttributeName`: extra space after each character, in
    /// points, as an `NSNumber`.
    public static let kern = NSAttributedString.Key("NSKern")
}

private extension NSAttributedString {
    /// The font the game attached, and the key it is measured with.
    var fontKey: FontKey? {
        guard length > 0 else { return nil }
        guard let font = attribute(.font, at: 0, effectiveRange: nil) as? UIFont else { return nil }
        return FontKey(name: font.fontName, size: font.pointSize)
    }
}

extension NSAttributedString {
    /// UIKit's `size()`, for one run of attributes as the games build them:
    /// the string in its first character's font, wide by its advance and
    /// letter spacing (`StringDrawing`, pinned against AppKit), high by the
    /// font's line height. Zero without a font.
    public func size() -> CGSize {
        guard length > 0, let font = attribute(.font, at: 0, effectiveRange: nil) as? UIFont else { return .zero }
        let kern = (attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        let width = StringDrawing.width(of: string, font: FontKey(name: font.fontName, size: font.pointSize), kern: kern)
        return CGSize(width: width, height: font.lineHeight)
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
//
// The shell registers every file in the APK's `fonts/` before the first
// scene (`AssetBundle.installFonts`, as an iOS app's `UIAppFonts` are); a
// game that registers a file itself goes through the font manager below, as
// on Apple.
public typealias CFURL = URL
public typealias CFString = String

public final class CFError: Error {
    /// What went wrong, as CoreText's font manager names it.
    public let registration: FontRegistration
    /// CoreText's code for it (`CTFontManagerError`): 101 for a file that
    /// isn't there, 103 for one that isn't a font, 105 for one registered
    /// before.
    public let code: Int

    init(_ registration: FontRegistration, url: URL) {
        self.registration = registration
        switch registration {
        case .alreadyRegistered: code = 105
        case .unreadable: code = FileManager.default.fileExists(atPath: url.path) ? 103 : 101
        case .registered: code = 0
        }
    }
}

/// CoreText's `CFErrorGetCode`, for a font manager error.
public func CFErrorGetCode(_ error: CFError) -> Int { error.code }

public enum CTFontManagerScope: UInt32, Sendable {
    case none = 0, process, persistent, session, user
}

/// Registers the font file at `fontURL` with the text stack. False, with the
/// error, for a file registered before or one that isn't a font, as on Apple.
/// A file the shell registered at launch registers once for the game without
/// being read again. With no text stack installed, yes.
@discardableResult
public func CTFontManagerRegisterFontsForURL(
    _ fontURL: CFURL, _ scope: CTFontManagerScope, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> Bool {
    let result = TextMetrics.catalog?.registerFont(at: fontURL.path) ?? .registered
    guard result == .registered else {
        error?.pointee = Unmanaged.passRetained(CFError(result, url: fontURL))
        return false
    }
    return true
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
        let result = TextMetrics.catalog?.registerFont(at: url.path) ?? .registered
        if result != .registered { errors.append(CFError(result, url: url)) }
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

/// The descriptor attribute naming a face: its PostScript name.
public let kCTFontNameAttribute: CFString = "NSFontNameAttribute"

/// A descriptor's attribute; only the name is kept, so others are nil.
public func CTFontDescriptorCopyAttribute(_ descriptor: CTFontDescriptor, _ attribute: CFString) -> Any? {
    attribute == kCTFontNameAttribute ? descriptor.postScriptName : nil
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
