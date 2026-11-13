import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// What stands behind `Source/Utils/TextHelpers.swift` on Android. That file
/// now compiles there unchanged, so these are the numbers its `wrappedLines`
/// and `capitalsOffset` will actually get.
@Suite("Typesetting")
struct TypesettingTests {
    /// `wrappedLines` itself, since the real one is three lines of
    /// `CTTypesetter` over this and is not compiled on the host.
    private func wrapped(_ text: String, maxWidth: CGFloat, font: FontKey) -> [String] {
        _ = Fonts.engine
        var lines: [String] = []
        var start = 0
        let utf16 = Array(text.utf16)
        while start < utf16.count {
            let count = max(1, Typesetting.suggestLineBreak(
                text, font: font, startingAt: start, maxWidth: maxWidth
            ))
            let piece = String(decoding: utf16[start..<min(start + count, utf16.count)], as: UTF16.self)
            lines.append(piece.trimmingCharacters(in: .whitespacesAndNewlines))
            start += count
        }
        return lines.filter { !$0.isEmpty }
    }

    @Test("Breaking a line walks the whole string and stops")
    func walksToTheEnd() {
        let text = "Tap a Switchling to send it one step, and bump another to trade arrows"
        let lines = wrapped(text, maxWidth: 160, font: Fonts.chiron(18))

        #expect(lines.count > 3)
        #expect(lines.joined(separator: " ") == text)
        for line in lines {
            #expect(Fonts.engine.measure(line, font: Fonts.chiron(18)).advance <= 160.001, "\(line)")
        }
    }

    @Test("A suggested break never returns zero, so the loop above terminates")
    func neverZero() {
        let text = "Switchlings"
        let font = Fonts.chiron(40)
        for width in [CGFloat(1), 5, 20, 1000] {
            #expect(Typesetting.suggestLineBreak(text, font: font, startingAt: 0, maxWidth: width) > 0)
        }
    }

    @Test("Offsets are UTF-16, which is what NSString.substring(with:) wants")
    func utf16Offsets() {
        // Thai is three UTF-8 bytes but one UTF-16 unit per character, so a
        // byte offset here would slice the string in the wrong place.
        let text = "\u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}\u{0E04}\u{0E23}\u{0E31}\u{0E1A}"
        let font = Fonts.koHo(24)
        #expect(text.utf16.count == 10)
        #expect(text.utf8.count == 30)

        let count = Typesetting.suggestLineBreak(text, font: font, startingAt: 0, maxWidth: 60)
        #expect(count > 0)
        #expect(count <= text.utf16.count)

        // The slice the game would take is valid text, not a cut codepoint.
        let utf16 = Array(text.utf16)
        let piece = String(decoding: utf16[0..<count], as: UTF16.self)
        #expect(piece.unicodeScalars.allSatisfy { $0.value >= 0x0E00 && $0.value <= 0x0E7F })
    }

    @Test("Starting part-way through continues from there")
    func resumes() {
        let text = "Unlock the full game and keep it forever"
        let font = Fonts.chiron(18)
        let first = Typesetting.suggestLineBreak(text, font: font, startingAt: 0, maxWidth: 100)
        let second = Typesetting.suggestLineBreak(text, font: font, startingAt: first, maxWidth: 100)

        #expect(first > 0)
        #expect(second > 0)
        #expect(first + second <= text.utf16.count)
    }

    @Test("A hard line break ends the line there whatever the width")
    func hardBreak() {
        let text = "Bump\nand trade"
        let font = Fonts.chiron(18)
        let count = Typesetting.suggestLineBreak(text, font: font, startingAt: 0, maxWidth: 10_000)
        #expect(count == 5)                       // "Bump\n"
        #expect(wrapped(text, maxWidth: 10_000, font: font) == ["Bump", "and trade"])
    }

    @Test("Running off the end gives nothing back")
    func pastTheEnd() {
        let font = Fonts.chiron(18)
        #expect(Typesetting.suggestLineBreak("Play", font: font, startingAt: 4, maxWidth: 100) == 0)
        #expect(Typesetting.suggestLineBreak("", font: font, startingAt: 0, maxWidth: 100) == 0)
    }

    @Test("Thai wraps without spaces, as CoreText does for it")
    func thai() {
        let text = String(repeating: "\u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}", count: 4)
        let lines = wrapped(text, maxWidth: 80, font: Fonts.koHo(24))
        #expect(lines.count > 1)
        #expect(lines.joined() == text)
    }

    @Test("Glyph-path bounds are the ink, and the plain bounds are the line")
    func lineBounds() throws {
        let font = Fonts.chiron(40)
        let ink = Typesetting.lineBounds("HELLO", font: font, glyphPath: true)
        let typographic = Typesetting.lineBounds("HELLO", font: font, glyphPath: false)
        let metrics = try #require(Fonts.engine.fontMetrics(font))

        #expect(ink.height > 0)
        #expect(ink.height < typographic.height)
        #expect(abs(typographic.height - (metrics.ascent + metrics.descent)) < 0.001)
        #expect(abs(typographic.minY + metrics.descent) < 0.001)
    }

    @Test("capitalsOffset comes out of this, and is what buttons lean on")
    func capitalsOffset() throws {
        // The real one is `CTLineGetBoundsWithOptions(.useGlyphPathBounds).midY
        // - capHeight / 2`. A line of capitals needs almost no correction; one
        // with a descender needs a real one, downwards.
        let font = Fonts.chiron(32)
        let metrics = try #require(Fonts.engine.fontMetrics(font))
        func offset(_ text: String) -> CGFloat {
            Typesetting.lineBounds(text, font: font, glyphPath: true).midY - metrics.capHeight / 2
        }

        #expect(abs(offset("HELLO")) < 0.6)
        #expect(offset("HELLOg") < -1)
    }

    @Test("Break offsets are ascending and land inside the string")
    func breakOffsets() {
        let text = "Tap a Switchling to send it one step"
        let offsets = Fonts.engine.breakOffsets(in: text)
        #expect(!offsets.isEmpty)
        #expect(offsets == offsets.sorted())
        #expect(Set(offsets).count == offsets.count)
        #expect(offsets.allSatisfy { $0 > 0 && $0 < text.utf16.count })
    }

    @Test("An unknown face gives one unbroken line, not a loop")
    func unknownFace() {
        // Measured as nothing, so everything fits and the whole string comes
        // back in one go. That matters more than it looks: `wrappedLines`
        // walks forward by whatever this returns, so anything that could
        // return 0 for a string it has not reached the end of would spin.
        // The engine must be registered, or the shim reports no provider
        // (0) whatever the face; suites run in any order.
        _ = Fonts.engine
        let font = FontKey(name: "NoSuchFont", size: 20)
        #expect(Typesetting.suggestLineBreak("Play", font: font, startingAt: 0, maxWidth: 50) == 4)
        #expect(wrapped("Play and trade", maxWidth: 50, font: font) == ["Play and trade"])
        #expect(Typesetting.lineBounds("Play", font: font, glyphPath: true) == .zero)
        #expect(Typesetting.lineBounds("Play", font: font, glyphPath: false) == .zero)
    }
}
