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
}
