#if canImport(CoreText) && os(macOS)
import CoreText
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// The engine against Core Text, what the game measures with on Apple, on
/// the same font files: a line's advance must come out the same width, to a
/// hair (the variable instances' advance deltas, which Core Text keeps
/// fractional, are all that's left).
@Suite("Lines as Core Text measures them") struct CoreTextParityTests {
    static let registered: Bool = {
        for file in ["ChironGoRoundTC-Variable", "KoHo-Bold", "Montserrat"] {
            let url = URL(fileURLWithPath: Fonts.directory + "/" + file + ".ttf") as CFURL
            CTFontManagerRegisterFontsForURL(url, .process, nil)
        }
        return true
    }()

    static func coreText(_ text: String, font: String, size: CGFloat) -> CGFloat {
        _ = registered
        let ctFont = CTFontCreateWithName(font as CFString, size, nil)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont])
        let line = CTLineCreateWithAttributedString(string)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    @Test("Advances match Core Text's", arguments: ["ChironGoRoundTC-Black", "ChironGoRoundTC-ExtraBold", "ChironGoRoundTC-SemiBold"])
    func advancesMatch(font: String) {
        for text in ["Español (México)", "W1 / L1", "Français", "Bahasa Indonesia", "Level Select", "Switchlings"] {
            let ours = Fonts.engine.measure(text, font: FontKey(name: font, size: 15)).advance
            let theirs = Self.coreText(text, font: font, size: 15)
            #expect(abs(ours - theirs) < 0.0005 * theirs, "\(font) \(text): \(ours) against \(theirs)")
        }
    }
    @Test("Glyph-path and image bounds match Core Text's", arguments: ["ChironGoRoundTC-Black", "ChironGoRoundTC-ExtraBold", "ChironGoRoundTC-SemiBold"])
    func boundsMatch(font: String) {
        for text in ["Español (México)", "W1 / L1", "Collection", "gpqy", "Sunny Garden", "SOHO"] {
            let ours = Fonts.engine.measure(text, font: FontKey(name: font, size: 20))
            let ctFont = CTFontCreateWithName(font as CFString, 20, nil)
            _ = Self.registered
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont]))
            let path = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let image = CTLineGetImageBounds(line, nil)
            // In a line, Core Text bounds glyphs by their points, curve and
            // control alike, with or without the glyph-path option.
            for (mine, theirs, kind) in [(ours.inkBounds, path, "path"), (ours.inkBounds, image, "image")] {
                let off = max(abs(mine.minX - theirs.minX), abs(mine.maxX - theirs.maxX), abs(mine.minY - theirs.minY), abs(mine.maxY - theirs.maxY))
                #expect(off < 0.05, "\(font) \(text) \(kind): \(mine) against \(theirs)")
            }
        }
    }
}
#endif
