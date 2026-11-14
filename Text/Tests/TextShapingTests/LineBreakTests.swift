import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

@Suite("Line breaking")
struct LineBreakTests {
    @Test("Latin breaks at spaces")
    func latin() {
        let lines = Fonts.engine.breakLines(
            "Unlock the full game and keep it forever",
            font: Fonts.chiron(20),
            maxWidth: 140
        )
        #expect(lines.count > 2)
        #expect(lines.joined(separator: " ") == "Unlock the full game and keep it forever")
        #expect(lines.allSatisfy { !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
    }

    @Test("A no-break space holds its words together")
    func noBreakSpace() {
        // The collection's "First appears in: Sunny Garden · Level 1", the
        // place joined with no-break spaces so it moves to a line of its own.
        let text = "First appears in: Sunny\u{00A0}Garden\u{00A0}·\u{00A0}Level\u{00A0}1"
        #expect(LineBreak.opportunities(in: text).map { $0.utf16Offset(in: text) } == [6, 14, 18])
    }

    @Test("Spaces a line ends on hang past its edge")
    func hangingSpaces() {
        let font = Fonts.chiron(20)
        let word = Fonts.engine.measure("Unlock", font: font).advance
        let lines = Fonts.engine.breakLines("Unlock     everything", font: font, maxWidth: word + 0.01)
        #expect(lines == ["Unlock", "everything"])
    }

    @Test("A word wider than the line is left over-wide rather than cut")
    func longWord() {
        let lines = Fonts.engine.breakLines("Switchlings", font: Fonts.chiron(40), maxWidth: 20)
        #expect(lines == ["Switchlings"])
    }

    @Test("Chinese breaks between characters, with no spaces to break at")
    func chinese() {
        let text = "点击一个斯威奇灵让它走一步"
        let lines = Fonts.engine.breakLines(text, font: Fonts.chiron(20), maxWidth: 100)
        #expect(lines.count > 1)
        #expect(lines.joined() == text)
    }

    @Test("Chinese never starts a line with closing punctuation")
    func kinsoku() {
        let places = LineBreak.opportunities(in: "中文。中文")
        let text = "中文。中文"
        let characters = Array(text.indices)
        // There is no break between 文 and 。
        #expect(!places.contains(characters[2]))
    }

    @Test("Thai breaks without spaces")
    func thai() {
        // "สวัสดีครับยินดีต้อนรับ" — a greeting, written with no spaces.
        let text = "\u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}\u{0E04}\u{0E23}\u{0E31}\u{0E1A}\u{0E22}\u{0E34}\u{0E19}\u{0E14}\u{0E35}"
        let lines = Fonts.engine.breakLines(text, font: Fonts.koHo(24), maxWidth: 70)
        #expect(!text.contains(" "))
        #expect(lines.count > 1)
        #expect(lines.joined() == text)
    }

    @Test("Thai never strands a leading vowel at the end of a line")
    func thaiLeadingVowel() {
        // เก่ง — SARA E is written before the consonant it sounds after, so a
        // break between them would leave a vowel alone at a line end.
        let text = "\u{0E40}\u{0E01}\u{0E48}\u{0E07}\u{0E40}\u{0E01}\u{0E48}\u{0E07}"
        let places = LineBreak.opportunities(in: text)
        let characters = Array(text.indices)
        for (offset, index) in characters.enumerated() where offset > 0 {
            let before = text[characters[offset - 1]]
            if before.unicodeScalars.first.map({ (0x0E40...0x0E44).contains(Int($0.value)) }) == true {
                #expect(!places.contains(index), "broke after a leading vowel at \(offset)")
            }
        }
    }

    @Test("Thai never splits a consonant from its marks")
    func thaiClusters() {
        let text = "\u{0E01}\u{0E38}\u{0E49}\u{0E07}\u{0E01}\u{0E38}\u{0E49}\u{0E07}"
        let places = LineBreak.opportunities(in: text)
        for place in places {
            let start = text[place]
            #expect(start.unicodeScalars.first.map {
                $0.properties.generalCategory != .nonspacingMark
            } == true)
        }
    }

    @Test("Breaking is stable: the same text and width give the same lines")
    func stability() {
        let text = "Tap a Switchling to send it one step"
        let font = Fonts.chiron(18)
        let first = Fonts.engine.breakLines(text, font: font, maxWidth: 120)
        let second = Fonts.engine.breakLines(text, font: font, maxWidth: 120)
        #expect(first == second)
    }
}
