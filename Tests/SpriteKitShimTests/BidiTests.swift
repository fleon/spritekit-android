import Foundation
import Testing
@testable import SpriteKitShim

/// The bidirectional algorithm (`Bidi`) on its own: each line's characters
/// in the order drawn, left to right, as Core Text drew them on a Mac
/// (macOS 27.2; `BidiParityTests` checks the same against Core Text live).
@Suite("Bidirectional text")
struct BidiTests {
    /// `text`'s characters in the order L2 draws them.
    static func visual(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let order = Bidi.visualOrder(Bidi.levels(scalars).levels)
        var out = String.UnicodeScalarView()
        out.append(contentsOf: order.map { scalars[$0] })
        return String(out)
    }

    @Test("Lines are drawn in Core Text's order")
    func order() {
        // Right-to-left letters reversed; numbers and Latin inside them kept
        // left to right; neutrals between two directions taking the line's.
        #expect(Self.visual("שלום עולם") == "םלוע םולש")
        #expect(Self.visual("נקודה 120 Score") == "Score 120 הדוקנ")
        #expect(Self.visual("Score 120 נקודה") == "Score 120 הדוקנ")
        #expect(Self.visual("123 שלום 456") == "456 םולש 123")
        #expect(Self.visual("שלום 12.5% עולם") == "םלוע 12.5% םולש")
        #expect(Self.visual("!שלום") == "םולש!")
        #expect(Self.visual("שלום!") == "!םולש")
        // Brackets at a right-to-left level are drawn mirrored: ")abc(" reads "(abc)".
        #expect(Self.visual("שלום (abc)") == ")abc( םולש")
        #expect(Self.visual("(abc) שלום") == "(abc) םולש")
        #expect(Self.visual("abc 123 def") == "abc 123 def")
    }

    @Test("Arabic digits after Arabic letters are Arabic numbers, drawn left to right")
    func arabicNumbers() {
        // W2: European digits after Arabic letters, Arabic-Indic ones always.
        #expect(Self.visual("مرحبا 2026") == "2026 ابحرم")
        #expect(Self.visual("سلام ٣٤٥ عليكم") == "مكيلع ٣٤٥ مالس")
    }

    @Test("A line's direction is its first strong character's, or the mark it's led by")
    func direction() {
        #expect(Bidi.direction(of: "!שלום world") == .rightToLeft)
        #expect(Bidi.direction(of: "123 Hello שלום") == .leftToRight)
        #expect(Bidi.direction(of: "123 !?") == .leftToRight)
        #expect(Bidi.marked("Hello שלום", in: .rightToLeft) == "\u{200F}Hello שלום")
        #expect(Bidi.marked("שלום Hello", in: .rightToLeft) == "שלום Hello")
        #expect(Bidi.marked("שלום Hello", in: .leftToRight) == "\u{200E}שלום Hello")
        #expect(Bidi.marked("Hello", in: .leftToRight) == "Hello")
        #expect(Self.visual("\u{200F}Hello שלום") == "םולש Hello\u{200F}")
    }

    @Test("A right-to-left line's trailing spaces are at its own level")
    func trailingSpaces() {
        let (levels, line) = Bidi.levels(Array("Hello שלום  ".unicodeScalars))
        #expect(line == 0)
        #expect(levels.suffix(2) == [0, 0])
    }

    @Test("Only text with right-to-left in it is reordered")
    func needsReordering() {
        for text in ["Hello", "クロ1976", "ไทย", "Привет", "12.5%", "€5"] { #expect(!Bidi.needsReordering(text), "\(text)") }
        for text in ["שלום", "مرحبا", "٣", "a\u{200F}"] { #expect(Bidi.needsReordering(text), "\(text)") }
    }

    /// `text`'s visible characters in the order drawn: explicit controls,
    /// which draw nothing and whose place UAX #9 leaves open, left out.
    static func visibleOrder(_ text: String) -> String {
        visual(text).filter { !$0.unicodeScalars.allSatisfy { (0x202A ... 0x202E).contains($0.value) || (0x2066 ... 0x2069).contains($0.value) } }
    }

    @Test("Embeddings, overrides and isolates set levels as Core Text's do")
    func explicit() {
        // Overrides: the letters inside take the override's direction.
        #expect(Self.visibleOrder("\u{202E}abc\u{202C} def") == "cba def")
        #expect(Self.visibleOrder("\u{202D}שלום\u{202C} עולם") == "םלוע שלום")
        // Embeddings: the text inside resolved at a higher level.
        #expect(Self.visibleOrder("שלום \u{202A}abc, def\u{202C}!") == "!abc, def םולש")
        // Isolates: neither direction leaks in or out, and P2 skips them.
        #expect(Self.visibleOrder("שלום \u{2066}abc 123\u{2069} עולם") == "םלוע abc 123 םולש")
        #expect(Self.visibleOrder("\u{2067}abc\u{2069} שלום") == "םולש abc")
        #expect(Self.visibleOrder("abc \u{2068}שלום\u{2069}!") == "abc םולש!")
        #expect(Bidi.direction(of: "\u{2066}abc\u{2069} שלום") == .rightToLeft)
    }

    @Test("A line's pieces are cut where the level changes and drawn in L2's order")
    func segments() {
        let segments = Bidi.segments(of: ["שלום ", "world", " עולם"], in: .rightToLeft)
        #expect(segments.map(\.piece) == [2, 1, 0])
        #expect(segments.map(\.level) == [1, 2, 1])
        let mixed = Bidi.segments(of: ["Hello ", "שלום", " עולם", " end"], in: .leftToRight)
        #expect(mixed.map(\.piece) == [0, 2, 1, 3])
        #expect(mixed.map(\.rightToLeft) == [false, true, true, false])
        // Nothing explicit: every stretch reads its own way alone.
        #expect(segments.filter(\.overridden).isEmpty && mixed.filter(\.overridden).isEmpty)
    }

    @Test("An override opened in one piece governs the next, which is drawn overridden")
    func overrideAcrossPieces() {
        // RLO in the first piece, PDF in the last: "def" reads right to left.
        let segments = Bidi.segments(of: ["abc \u{202E}x", "def", "\u{202C} end"], in: .leftToRight)
        let def = segments.first { $0.piece == 1 }
        #expect(def?.level == 1)
        #expect(def?.overridden == true)
        // In one piece too, the override's characters cut from the stretch
        // it forces (they take the level before them) are drawn forced.
        let own = Bidi.segments(of: ["abc \u{202E}def\u{202C} end"], in: .leftToRight)
        #expect(own.filter { $0.level == 1 }.map(\.overridden) == [true])
        // An LRO spanning Hebrew pieces in a right-to-left line.
        let hebrew = Bidi.segments(of: ["שלום \u{202D}עולם ", "טוב", "\u{202C} סוף"], in: .rightToLeft)
        let tov = hebrew.first { $0.piece == 1 }
        #expect(tov?.level == 2)
        #expect(tov?.overridden == true)
        // An isolate's content reads its own way alone: nothing to force.
        let isolate = Bidi.segments(of: ["abc \u{2067}שלום ", "Wim", "\u{2069} end"], in: .leftToRight)
        #expect(isolate.filter(\.overridden).isEmpty)
    }

    @Test("A stretch is forced its way: its controls out, an override of its direction round the rest, led by its mark")
    func overridden() {
        #expect(Bidi.overridden("de\u{202C}f", rightToLeft: true) == "\u{200F}\u{202E}def\u{202C}")
        #expect(Bidi.overridden("עולם ", rightToLeft: false) == "\u{200E}\u{202D}עולם \u{202C}")
    }

    @Test("Kashida go after initial and medial letters, never into a ligature")
    func kashidaPlaces() {
        let ones = { (text: String) in [CGFloat](repeating: 1, count: text.count) }
        // عليكم: ain initial, then lam, yeh and kaf medial.
        #expect(Kashida.opportunities(in: Array("عليكم"), advances: ones("عليكم")) == [0])
        #expect(Kashida.medials(in: Array("عليكم"), advances: ones("عليكم")) == [1, 2, 3])
        // سلام: the lam drawn in a ligature with the alef (no advance of its own).
        #expect(Kashida.medials(in: Array("سلام"), advances: [1, 1, 0, 1]).isEmpty)
    }

    @Test("A justified line's slack: initial places to 0.8 em, then medial places and spaces, as Core Text shares it")
    func kashidaShares() {
        // No medial place: the initial places take it all.
        let alone = Kashida.Shares(slack: 40, initials: [15, 15], medials: [], spaces: [15])
        #expect(alone.initials == [20, 20] && alone.spaces == [0])
        // "Go عليكم and more" at 160 (CTLineCreateJustifiedLine): 12 after
        // the ain, the other 7.32 four ways.
        let shared = Kashida.Shares(slack: 19.32, initials: [15], medials: [15, 15, 15], spaces: [15])
        #expect(shared.initials == [12])
        #expect(shared.medials.allSatisfy { abs($0 - 1.83) < 0.01 } && abs(shared.spaces[0] - 1.83) < 0.01)
        // Spaces full at half an em; the medial places take the rest.
        let full = Kashida.Shares(slack: 60, initials: [15], medials: [15, 15, 15], spaces: [15, 15])
        #expect(full.spaces == [7.5, 7.5] && full.medials.allSatisfy { abs($0 - 11) < 0.001 })
        // As few kashida as fill a place at the tatweel's advance, each narrower.
        #expect(Kashida.glyphs(filling: 12, tatweel: 3.149).count == 4)
    }
}
