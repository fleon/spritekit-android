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
        for file in ["KoHo-Bold", "Montserrat"] {
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

    @Test("Advances match Core Text's", arguments: ["Montserrat-Black", "Montserrat-ExtraBold", "Montserrat-SemiBold"])
    func advancesMatch(font: String) {
        for text in ["Español (México)", "W1 / L1", "Français", "Bahasa Indonesia", "Level Select", "Lightning"] {
            let ours = Fonts.engine.measure(text, font: FontKey(name: font, size: 15)).advance
            let theirs = Self.coreText(text, font: font, size: 15)
            // A tenth of a percent: the instances' fractional advance deltas.
            #expect(abs(ours - theirs) < 0.001 * theirs, "\(font) \(text): \(ours) against \(theirs)")
        }
    }
    @Test("Glyph-path and image bounds match Core Text's", arguments: ["Montserrat-Black", "Montserrat-ExtraBold", "Montserrat-SemiBold"])
    func boundsMatch(font: String) {
        for text in ["Español (México)", "W1 / L1", "Collection", "gpqy", "Sunny Garden", "SOHO"] {
            // Registered before the first lookup: Core Text keeps a name it
            // couldn't find as its fallback for the rest of the process.
            _ = Self.registered
            let ours = Fonts.engine.measure(text, font: FontKey(name: font, size: 20))
            let ctFont = CTFontCreateWithName(font as CFString, 20, nil)
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

    @Test("Vertical metrics match Core Text's, unrounded", arguments: ["Montserrat-Regular", "Montserrat-SemiBold", "KoHo-Bold"])
    func verticalMetricsMatch(font: String) throws {
        _ = Self.registered
        // Small and fractional sizes, where whole-pixel rounding moves a
        // label's line a point or more.
        for size: CGFloat in [10, 12, 15.5, 32] {
            let ours = try #require(Fonts.engine.fontMetrics(FontKey(name: font, size: size)))
            let ctFont = CTFontCreateWithName(font as CFString, size, nil)
            let theirs = (ascent: CTFontGetAscent(ctFont), descent: CTFontGetDescent(ctFont), leading: CTFontGetLeading(ctFont))
            #expect(abs(ours.ascent - theirs.ascent) < 0.01, "\(font) \(size) ascent: \(ours.ascent) against \(theirs.ascent)")
            #expect(abs(ours.descent - theirs.descent) < 0.01, "\(font) \(size) descent: \(ours.descent) against \(theirs.descent)")
            #expect(abs(ours.leading - theirs.leading) < 0.01, "\(font) \(size) leading: \(ours.leading) against \(theirs.leading)")
        }
    }
}
#endif
