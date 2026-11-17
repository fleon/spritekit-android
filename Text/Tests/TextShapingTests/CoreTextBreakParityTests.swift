#if canImport(CoreText) && os(macOS)
import CoreText
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// `wrappedLines` on both platforms: the shim's `Typesetting` against Core
/// Text's typesetter, on the same font files, line by line across a sweep of
/// widths, so a line of a game's text breaks where it breaks on iOS.
@Suite("Line breaks as Core Text makes them") struct CoreTextBreakParityTests {
    /// A game's line wrapping, with Core Text's typesetter or the shim's.
    static func wrapped(_ text: String, width: CGFloat, font: String, size: CGFloat, coreText: Bool) -> [String] {
        _ = CoreTextParityTests.registered
        _ = Fonts.engine
        let ctFont = CTFontCreateWithName(font as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let string = text as NSString
        var lines: [String] = []
        var start = 0
        while start < string.length {
            let suggested = coreText
                ? CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                : Typesetting.suggestLineBreak(text, font: FontKey(name: font, size: size), startingAt: start, maxWidth: width)
            let count = max(1, suggested)
            lines.append(string.substring(with: NSRange(location: start, length: count)).trimmingCharacters(in: .whitespacesAndNewlines))
            start += count
        }
        return lines.filter { !$0.isEmpty }
    }

    /// The widest piece no break may split, as Core Text measures it: below
    /// that Core Text cuts words and the shim leaves them whole, on purpose.
    static func widestPiece(_ text: String, font: String, size: CGFloat) -> CGFloat {
        text.split(separator: " ").map { CoreTextParityTests.coreText(String($0), font: font, size: size) }.max() ?? 0
    }

    static let nbsp = "\u{00A0}"
    /// Lines a list's rows wrap, "Quiet Harbour · Level 1" held together
    /// with no-break spaces, and hints and help lines.
    /// (French's space before a colon is left out: Core Text breaks before
    /// it at some widths and not at others, which this doesn't copy.)
    static let texts: [String] = [
        "First appears in: " + "Quiet Harbour · Level 1".replacingOccurrences(of: " ", with: nbsp),
        "First appears in: " + "Old Lighthouse · Level 12".replacingOccurrences(of: " ", with: nbsp),
        "Zuerst in: " + "Stiller Hafen · Level 1".replacingOccurrences(of: " ", with: nbsp),
        "Appears in: 37 levels",
        "Tap a salamander to send it one step, and bump another to trade arrows!",
        "You’re not signed in to Game\u{00A0}Center. To sign in, go to Settings > Game\u{00A0}Center.",
        "Rain keeps falling (until something stops it).",
        "A well-placed shot wins the round.",
    ]

    @Test("Lines break where Core Text breaks them", arguments: ["ChironGoRoundTC-ExtraBold", "ChironGoRoundTC-SemiBold", "ChironGoRoundTC-Black"])
    func breaksMatch(font: String) {
        let size: CGFloat = 14
        for text in Self.texts {
            let least = Self.widestPiece(text.replacingOccurrences(of: Self.nbsp, with: "~"), font: font, size: size)
            var width = (least + 1).rounded(.up)
            let whole = CoreTextParityTests.coreText(text, font: font, size: size) + 4
            while width < whole {
                let theirs = Self.wrapped(text, width: width, font: font, size: size, coreText: true)
                let ours = Self.wrapped(text, width: width, font: font, size: size, coreText: false)
                // Advances differ by a hair (the variable font's fractional
                // deltas), so a line that fits to within 0.1 pt may go either way.
                let near = [width - 0.1, width + 0.1].map { Self.wrapped(text, width: $0, font: font, size: size, coreText: true) }
                #expect(ours == theirs || near.contains(ours), "\(font) at \(width): \(ours) against \(theirs)")
                width += 0.5
            }
        }
    }
}
#endif
