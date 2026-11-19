#if canImport(CoreText) && os(macOS)
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// Justified right-to-left and mixed paragraphs broken as UIKit's string
/// drawing breaks them (TextKit 2, as `JustifiedBreaksTests` breaks
/// left-to-right ones). `Fixtures/Justified/textkit2-justified-rtl.tsv`
/// holds TextKit 2's lines on Catalyst (macOS 27.2) for 1,800 layouts:
/// Arabic in Noto Naskh Arabic UI, Hebrew in Montserrat (falling back to
/// the system's Hebrew), Latin beside Hebrew or beside Arabic in its own
/// face, at four sizes and widths from 93 to 300 points, as
/// `Tools/JustifiedProbe` regenerates it.
@Suite("Justified right-to-left paragraphs broken as UIKit breaks them")
struct JustifiedRightToLeftTests {
    static let texts = [
        "ذهبنا إلى السوق في الصباح واشترينا الخبز والحليب والفاكهة الطازجة",
        "القطار يغادر المحطة كل ساعة ويصل إلى المدينة بعد الظهر",
        "تقع المكتبة بجانب الحديقة وتفتح أبوابها من التاسعة حتى المساء",
        "كان الطقس جميلا اليوم فجلسنا على الشاطئ نقرأ الكتب",
        "הרכבת יוצאת מהתחנה בכל שעה ומגיעה לעיר אחרי הצהריים",
        "הספרייה נמצאת ליד הגן ופתוחה מתשע בבוקר ועד הערב",
        "הלכנו לשוק בבוקר וקנינו לחם חלב ופירות טריים",
        "מזג האוויר היה נעים היום אז ישבנו על החוף וקראנו ספרים",
        "The museum מוזיאון opens at nine and closes בערב at six",
        "Our train |القطار| leaves at noon from |المحطة| seven",
    ]

    static func layouts() throws -> [(face: String, second: String, size: CGFloat, width: CGFloat, text: Int, lines: [String])] {
        let url = URL(fileURLWithPath: Fonts.directory).deletingLastPathComponent().appendingPathComponent("Justified/textkit2-justified-rtl.tsv")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { row in
            let fields = row.components(separatedBy: "\t")
            return (fields[0], fields[1], CGFloat(Double(fields[2])!), CGFloat(Double(fields[3])!), Int(fields[4])!,
                    fields[5].components(separatedBy: "|").filter { !$0.isEmpty })
        }
    }

    /// A line's words, whatever order they're drawn in.
    static func words(_ line: String) -> [String] {
        let marks = Set("\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}".unicodeScalars)
        let plain = String(String.UnicodeScalarView(line.unicodeScalars.filter { !marks.contains($0) }))
        return plain.split(separator: " ").map(String.init).sorted()
    }

    @Test("Lines break where TextKit 2 breaks them")
    func breaks() throws {
        _ = Fonts.engine
        var exact = [String: (Int, Int)](), counts = 0, total = 0
        var misses: [String] = []
        for layout in try Self.layouts() {
            let style = TextBlock.Style(alignment: .justified, wrapping: .words)
            let runs = Self.texts[layout.text].split(separator: "|", omittingEmptySubsequences: false).enumerated().compactMap { index, part in
                part.isEmpty ? nil : TextBlock.Run(String(part), font: FontKey(name: index % 2 == 1 ? layout.second : layout.face, size: layout.size), style: style)
            }
            let block = try #require(TextBlock(runs: runs, maxWidth: layout.width))
            let ours = block.lines.map { Self.words($0.pieces.map(\.text).joined()) }
            let theirs = layout.lines.map(Self.words)
            let kind = layout.text < 4 ? "arabic" : layout.text < 8 ? "hebrew" : "mixed"
            total += 1
            let same = ours == theirs
            exact[kind, default: (0, 0)].0 += same ? 1 : 0
            exact[kind, default: (0, 0)].1 += 1
            if ours.count == theirs.count { counts += 1 }
            if !same, misses.count < 5 { misses.append("\(layout.face) \(layout.size) \(layout.width) #\(layout.text): \(theirs)") }
        }
        print("RTL exact \(exact.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.0)/\($0.value.1)" }.joined(separator: ", ")); counts \(counts)/\(total)")
        // #96's costs as they are, fitted left to right: Arabic 98.3%,
        // Hebrew 99.0%, mixed 97.8% (line by line, 89.2%, 92.5%, 88.3%).
        // Neither counting a line's letters (or kashida) as stretch, nor a
        // dearer or cheaper one-word line for Arabic, came closer.
        for (kind, least) in [("arabic", 0.97), ("hebrew", 0.98), ("mixed", 0.97)] {
            let (matched, of) = exact[kind] ?? (0, 1)
            #expect(Double(matched) >= least * Double(of), "\(kind): \(matched) of \(of) break as TextKit 2's: \(misses)")
        }
        #expect(Double(counts) >= 0.995 * Double(total), "\(counts) of \(total) have TextKit 2's line count")
    }
}
#endif
