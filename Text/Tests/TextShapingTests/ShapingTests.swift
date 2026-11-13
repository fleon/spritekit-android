import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// Thai is the acceptance test for this whole module, because it is where
/// "rasterise each codepoint with FreeType" is not merely imprecise but
/// wrong — and wrong in four separate ways, one per test here.
@Suite("Thai")
struct ThaiShapingTests {
    @Test("SARA AM becomes two glyphs, one of them reordered in front of the other")
    func saraAm() {
        // ลำ — LO LING + SARA AM. SARA AM is written as a circle above and a
        // tail after, so the shaper splits it into NIKHAHIT and SARA AA and
        // puts the NIKHAHIT first. Two characters in, three glyphs out, and
        // neither of the two new glyphs is the one the codepoint maps to.
        let text = "\u{0E25}\u{0E33}"
        let font = Fonts.koHo()
        let glyphs = (Fonts.engine.shape(text, font: font) ?? []).flatMap(\.glyphs)
        let naive = Fonts.naive(text, font: font)

        #expect(text.unicodeScalars.count == 2)
        #expect(glyphs.count == 3)
        #expect(naive.glyphs.count == 2)
        #expect(glyphs.map(\.glyph) != naive.glyphs)

        // Both of the new glyphs come from the second character, so the
        // cluster run is 0, 3, 3 — one character, two glyphs.
        #expect(glyphs.map(\.cluster) == [0, 3, 3])
        // The reordered NIKHAHIT sits above and takes no width.
        #expect(glyphs[1].xAdvance == 0)
        #expect(glyphs[2].xAdvance > 0)
    }

    @Test("A tone mark takes a different form over a tall consonant")
    func toneMarkForms() {
        // ที่ — the MAI EK over THO THAHAN, whose ascender the plain mark
        // would collide with, so the shaper swaps in the shifted form.
        let text = "\u{0E17}\u{0E35}\u{0E48}"
        let font = Fonts.koHo()
        let glyphs = (Fonts.engine.shape(text, font: font) ?? []).flatMap(\.glyphs)
        let naive = Fonts.naive(text, font: font)

        #expect(glyphs.count == naive.glyphs.count)
        #expect(glyphs.map(\.glyph) != naive.glyphs)
        #expect(glyphs.last?.glyph != naive.glyphs.last)
    }

    @Test("A consonant loses its descender under a below-vowel")
    func descenderRemoval() {
        // ญุ — YO YING keeps a tail that SARA U needs the room of, so the
        // shaper swaps the consonant itself for its tail-less form.
        let text = "\u{0E0D}\u{0E38}"
        let font = Fonts.koHo()
        let glyphs = (Fonts.engine.shape(text, font: font) ?? []).flatMap(\.glyphs)
        let naive = Fonts.naive(text, font: font)

        #expect(glyphs.first?.glyph != naive.glyphs.first)
        #expect(glyphs.count == 2)
    }

    @Test("Marks take no width, and are nudged off the pen rather than stacked on it")
    func markPlacement() {
        // สวิตช์ลิง — the game's own word, Switchling, with three marks in it.
        let text = "\u{0E2A}\u{0E27}\u{0E34}\u{0E15}\u{0E0A}\u{0E4C}\u{0E25}\u{0E34}\u{0E07}"
        let font = Fonts.koHo()
        let glyphs = (Fonts.engine.shape(text, font: font) ?? []).flatMap(\.glyphs)
        let marks = glyphs.filter { $0.xAdvance == 0 }

        #expect(marks.count == 3)
        // Each one is placed by the font's GPOS over the consonant it
        // belongs to. Loading the codepoints in order and drawing each at
        // the pen — which is all FreeType on its own offers — would put
        // every one of these in the wrong place.
        #expect(marks.allSatisfy { $0.xOffset != 0 })
        // And the line is only as wide as the consonants that carry them.
        #expect(Fonts.engine.measure(text, font: font).advance
                == glyphs.reduce(0) { $0 + $1.xAdvance })
    }

    @Test("Marks reach above the consonants, so the ink is taller than the line")
    func markInk() {
        let font = Fonts.koHo(28)
        let plain = Fonts.engine.measure("\u{0E2A}\u{0E27}\u{0E15}", font: font)
        let marked = Fonts.engine.measure("\u{0E2A}\u{0E27}\u{0E34}\u{0E15}\u{0E49}", font: font)

        #expect(marked.inkBounds.maxY > plain.inkBounds.maxY)
        #expect(marked.inkBounds.height > plain.inkBounds.height)
    }
}

@Suite("Shaping")
struct ShapingTests {
    @Test("A Latin line's advances sum to its measured width")
    func latinAdvances() {
        let font = Fonts.chiron()
        for text in ["Switchlings", "Play", "Level 12", "Tap to bump and trade arrows"] {
            let glyphs = (Fonts.engine.shape(text, font: font) ?? []).flatMap(\.glyphs)
            let sum = glyphs.reduce(0) { $0 + $1.xAdvance }
            let measured = Fonts.engine.measure(text, font: font)
            #expect(sum > 0)
            #expect(abs(measured.advance - sum) < 0.001, "\(text)")
            // One glyph per character, nothing dropped: Latin in Chiron has
            // no ligatures the game would hit.
            #expect(glyphs.count == text.count)
        }
    }

    @Test("Clusters run in order and cover the whole string")
    func latinClusters() {
        let text = "Level 12"
        let glyphs = (Fonts.engine.shape(text, font: Fonts.chiron()) ?? []).flatMap(\.glyphs)
        #expect(glyphs.map(\.cluster) == Array(0..<text.utf8.count))
    }

    @Test("CJK shapes one glyph per ideograph, each with real width")
    func cjk() {
        let font = Fonts.chiron()
        for text in ["简体中文", "日本語", "한국어"] {
            let glyphs = (Fonts.engine.shape(text, font: font) ?? []).flatMap(\.glyphs)
            #expect(glyphs.count == text.count, "\(text)")
            #expect(glyphs.allSatisfy { $0.glyph != 0 }, "\(text) has a missing glyph")
            #expect(glyphs.allSatisfy { $0.xAdvance > 0 }, "\(text)")
        }
    }

    @Test("A mixed string is itemised into one run per script")
    func itemisation() {
        let runs = Fonts.engine.shape("Level 1 \u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}", font: Fonts.chiron()) ?? []
        #expect(runs.count == 2)
        #expect(runs.first?.script == .latin)
        #expect(runs.last?.script == .thai)
        // The second run's clusters are offsets into the whole string, not
        // into the run, so they read straight against the source.
        #expect((runs.last?.glyphs.first?.cluster ?? 0) == 8)
    }

    @Test("Script detection covers every script the game ships")
    func scripts() {
        #expect(script("A") == .latin)
        #expect(script("ä") == .latin)
        #expect(script("Я") == .cyrillic)
        #expect(script("ก") == .thai)
        #expect(script("中") == .han)
        #expect(script("あ") == .hiragana)
        #expect(script("カ") == .katakana)
        #expect(script("한") == .hangul)
        #expect(script(" ") == .common)
        #expect(script("1") == .common)
    }

    @Test("An unregistered face shapes nothing rather than guessing")
    func unknownFace() {
        #expect(Fonts.engine.shape("Hello", font: FontKey(name: "NoSuchFont", size: 20)) == nil)
        #expect(Fonts.engine.fontMetrics(FontKey(name: "NoSuchFont", size: 20)) == nil)
    }
}

private func script(_ character: Character) -> TextScript {
    character.unicodeScalars.first.map(TextScript.of) ?? .common
}
