#if canImport(SpriteKit) && os(macOS)
import CoreText
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// Lines with right-to-left text in them against Core Text's: the order the
/// characters are drawn in, left to right, and the line's advance and ink,
/// on the same faces (Core Text's fallback for Arabic and Hebrew).
@Suite("Right-to-left and mixed lines as Core Text lays them out")
struct BidiParityTests {
    static let texts = [
        "سلام عليكم", "שלום עולם", "Score 120 نقطة", "نقطة 120 Score", "Level 5: مرحبا", "مرحبا: Level 5",
        "(abc) שלום", "שלום (abc)", "123 שלום 456", "שלום 12.5% עולם", "!שלום", "שלום!", "؟مرحبا",
        "مرحبا 2026", "Hello עולם and مرحبا", "مرحبا Hello world", "سلام ٣٤٥ عليكم", "שלום עולם ",
        "\u{200F}Hello מרחב", "\u{200E}שלום world",
    ]

    static func coreTextLine(_ text: String, _ size: CGFloat) -> CTLine {
        _ = CoreTextFallback.registered
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: CTFontCreateWithName("Montserrat-Black" as CFString, size, nil),
        ]))
    }

    /// The UTF-16 offset of each character Core Text draws, left to right.
    static func appleOrder(_ line: CTLine) -> [Int] {
        (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run -> [Int] in
            let range = CTRunGetStringRange(run)
            let offsets = Array(range.location ..< range.location + range.length)
            return CTRunGetStatus(run).contains(.rightToLeft) ? offsets.reversed() : offsets
        }
    }

    /// The same from our runs: each glyph's character, in the order drawn.
    static func ourOrder(_ text: String, _ runs: [ShapedRun]) -> [Int] {
        // UTF-8 offset of each character's start to its UTF-16 offset.
        var utf16Of: [Int: Int] = [:]
        var utf8 = 0, utf16 = 0
        for character in text {
            utf16Of[utf8] = utf16
            utf8 += character.utf8.count
            utf16 += character.utf16.count
        }
        var order: [Int] = []
        for run in runs {
            for glyph in run.glyphs {
                guard let offset = utf16Of[glyph.cluster], order.last != offset else { continue }
                order.append(offset)
            }
        }
        return order
    }

    @Test("Characters are drawn in Core Text's order")
    func order() throws {
        let font = Fonts.display(15)
        for text in Self.texts {
            let runs = try #require(Fonts.engine.shape(text, font: font))
            // Every character Core Text draws a glyph for, in its order: our
            // glyphs' clusters, each character's first, must follow it.
            let apple = Self.appleOrder(Self.coreTextLine(text, 15))
            let ours = Self.ourOrder(text, runs)
            // A right-to-left line's trailing spaces: Core Text hangs them
            // left of the line's origin, we draw them at its right end, and
            // neither draws or moves anything visible (`shapeBidi`).
            let trailing = text.reversed().prefix(while: \.isWhitespace).count
            let trailingSpaces = Set(text.utf16.count - trailing ..< text.utf16.count)
            let drawn = Set(ours).subtracting(trailingSpaces)
            #expect(apple.filter(drawn.contains) == ours.filter(drawn.contains), "'\(text)'")
        }
    }

    @Test("Lines measure as Core Text's: advance and ink")
    func measures() throws {
        let font = Fonts.display(15)
        for text in Self.texts {
            let line = Self.coreTextLine(text, 15)
            let ours = Fonts.engine.measure(text, font: font)
            #expect(abs(ours.advance - CTLineGetTypographicBounds(line, nil, nil, nil)) < 1e-3, "'\(text)' advance")
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            #expect(abs(ours.inkBounds.minX - ink.minX) < 0.05 && abs(ours.inkBounds.maxX - ink.maxX) < 0.05,
                    "'\(text)' ink \(ours.inkBounds) against \(ink)")
        }
    }

    @Test("Text without right-to-left in it is laid out as before")
    func leftToRightUnchanged() {
        for text in ["Hello world", "Level 5: 120", "クロ1976", "ไทย", "(abc) 12.5%"] {
            #expect(!Bidi.needsReordering(text), "'\(text)'")
        }
    }
}
#endif
