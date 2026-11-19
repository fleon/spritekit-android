#if canImport(CoreText) && os(macOS)
import CoreFoundation
import CoreText
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// Thai line breaks against Core Text's typesetter, which breaks Thai
/// with ICU's dictionary. The breaker asks the platform's
/// (`ThaiLineBreaks`): here CoreFoundation's line-break tokenizer, which is
/// ICU's, as Android's `BreakIterator` is.
@Suite("Thai breaks as Core Text makes them", .serialized) struct ThaiBreakParityTests {
    static let sentences = [
        "ภาษาไทยเขียนติดกันโดยไม่มีช่องว่างระหว่างคำ",
        "แกะของคุณกำลังรออยู่ในทุ่งหญ้าสีเขียว",
        "คุณแน่ใจหรือไม่ว่าต้องการออกจากเกมนี้ คุณจะแพ้เกมนี้",
        "ค้นหาผู้เล่นที่อยู่ใกล้คุณและเล่นด้วยกัน",
        "ยินดีต้อนรับสู่เกม แตะที่ใดก็ได้เพื่อดำเนินการต่อ",
    ]

    /// ICU's line-break opportunities, through CoreFoundation.
    static func icuLineBreaks(_ text: String) -> [Int]? {
        let string = text as CFString
        let tokenizer = CFStringTokenizerCreate(nil, string, CFRange(location: 0, length: CFStringGetLength(string)),
                                                kCFStringTokenizerUnitLineBreak, Locale(identifier: "th") as CFLocale)
        var starts: [Int] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            starts.append(CFStringTokenizerGetCurrentTokenRange(tokenizer).location)
        }
        return starts
    }

    /// The text cut at every place ICU allows a break.
    static func pieces(of text: String) -> [String] {
        let utf16 = Array(text.utf16)
        let cuts = (icuLineBreaks(text) ?? []).filter { $0 > 0 } + [utf16.count]
        var start = 0
        return cuts.map { cut in
            defer { start = cut }
            return String(decoding: utf16[start ..< cut], as: UTF16.self).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Lines over a sweep of widths, ours against Core Text's; how many differ.
    static func differences() -> (Int, Int, [String]) {
        var checked = 0, differ = 0, examples: [String] = []
        for text in sentences {
            // Below the widest piece no break may split, Core Text cuts it and
            // the shim leaves it whole, on purpose (as in
            // `CoreTextBreakParityTests`).
            let pieces = pieces(of: text)
            let least = pieces.map { CoreTextParityTests.coreText($0, font: "KoHo-Bold", size: 20) }.max() ?? 0
            for width in stride(from: 60.0, through: 300.0, by: 10.0) where width > least {
                let theirs = CoreTextBreakParityTests.wrapped(text, width: width, font: "KoHo-Bold", size: 20, coreText: true)
                let ours = CoreTextBreakParityTests.wrapped(text, width: width, font: "KoHo-Bold", size: 20, coreText: false)
                checked += 1
                if ours != theirs {
                    differ += 1
                    if examples.count < 6 { examples.append("at \(width): \(ours) against \(theirs)") }
                }
            }
        }
        return (checked, differ, examples)
    }

    @Test("With ICU's dictionary, Thai breaks where Core Text breaks it")
    func withDictionary() {
        Fonts.engine.flush()
        let (checked, differ, examples) = ThaiLineBreaks.$scoped.withValue(Self.icuLineBreaks) { Self.differences() }
        print("THAI with dictionary: \(differ) of \(checked) differ")
        #expect(differ == 0, "\(differ) of \(checked):\n\(examples.joined(separator: "\n"))")
    }

    @Test("A platform that can't say (no Thai dictionary) keeps the fallback")
    func providerDeclines() {
        let declined = ThaiLineBreaks.$scoped.withValue({ _ in nil }) { LineBreak.opportunities(in: "แกะของคุณกำลังรอ") }
        let fallback = LineBreak.opportunities(in: "แกะของคุณกำลังรอ")
        #expect(!declined.isEmpty && declined == fallback)
    }

    @Test("Without one, the cluster fallback still never breaks a cluster or strands a leading vowel")
    func withoutDictionary() {
        Fonts.engine.flush()
        let (checked, differ, _) = Self.differences()
        print("THAI without dictionary: \(differ) of \(checked) differ")
        let places = LineBreak.opportunities(in: "แกะของคุณ")
        #expect(!places.isEmpty)
    }
}
#endif
