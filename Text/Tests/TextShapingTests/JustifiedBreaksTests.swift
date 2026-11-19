#if canImport(CoreText) && os(macOS)
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// Justified paragraphs broken as UIKit's string drawing breaks them, which
/// is TextKit 2's layout (its line counts match UIKit's `boundingRect` in
/// all 3,420 of a sweep, where TextKit 1's and Core Text's framesetter's
/// match 2,984). `Fixtures/Justified/textkit2-justified.tsv` holds TextKit
/// 2's lines on Catalyst (macOS 27.2) for 7,020 layouts: four faces, five
/// sizes, nine sentences and widths from 90 to 300 points, as
/// `Tools/JustifiedProbe` regenerates it.
@Suite("Justified paragraphs broken as UIKit breaks them")
struct JustifiedBreaksTests {
    static let texts = [
        "Are you sure you want to quit? You will lose this game.", "Unbelievably unbreakable word here and there again",
        "The quick brown fox jumps over the lazy dog twice",
        "Gather all the shells along the shore to fill your basket before the tide returns.",
        "Press and hold a key to see what it does before you use it in a sentence.",
        "Your train has been delayed by twenty minutes. Thank you for your patience today!",
        "Carry the parcel across the bridge and leave it beside the library door.",
        "A little patience goes a long way when the kettle refuses to boil tonight.",
        "Museum tickets reset at midnight so come back tomorrow for more tours.",
    ]

    static func layouts() throws -> [(font: String, size: CGFloat, width: CGFloat, text: String, lines: [String])] {
        let url = URL(fileURLWithPath: Fonts.directory).deletingLastPathComponent().appendingPathComponent("Justified/textkit2-justified.tsv")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { row in
            let fields = row.components(separatedBy: "\t")
            return (fields[0], CGFloat(Double(fields[1])!), CGFloat(Double(fields[2])!), texts[Int(fields[3])!],
                    fields[4].components(separatedBy: "|").filter { !$0.isEmpty })
        }
    }

    @Test("Lines break where TextKit 2 breaks them")
    func breaks() throws {
        _ = Fonts.engine
        var exact = 0, counts = 0, total = 0, longTotal = 0, longExact = 0, sweepCounts = 0
        var misses: [String] = []
        for (index, layout) in try Self.layouts().enumerated() {
            let style = TextBlock.Style(alignment: .justified, wrapping: .words)
            let block = try #require(TextBlock(runs: [TextBlock.Run(layout.text, font: FontKey(name: layout.font, size: layout.size), style: style)],
                                               maxWidth: layout.width))
            let lines = block.lines.map { $0.pieces.map(\.text).joined() }
            total += 1
            let long = layout.text.split(separator: " ").contains { Fonts.engine.measure(String($0), font: FontKey(name: layout.font, size: layout.size)).advance > layout.width }
            longTotal += long ? 1 : 0
            if lines == layout.lines { longExact += long ? 1 : 0 }
            if lines == layout.lines { exact += 1 } else if misses.count < 5 { misses.append("\(layout.font) \(layout.size) \(layout.width): \(lines) against \(layout.lines)") }
            if lines.count == layout.lines.count { counts += 1; if index < 3420 { sweepCounts += 1 } }
        }
        print("JUSTIFIED exact \(exact) counts \(counts) of \(total); with a word wider than the line \(longExact) of \(longTotal); the 3,420 sweep's counts \(sweepCounts)")
        // Where every word fits a line, 98% break exactly as TextKit 2's
        // (breaking line by line, 78%); a word wider than the line is broken
        // by character as before, which matches TextKit 2 in 55% of those.
        let wordsFit = total - longTotal, wordsFitExact = exact - longExact
        #expect(Double(wordsFitExact) >= 0.97 * Double(wordsFit), "\(wordsFitExact) of \(wordsFit) break exactly as TextKit 2's: \(misses)")
        #expect(Double(exact) >= 0.945 * Double(total), "\(exact) of \(total) layouts break exactly as TextKit 2's")
        #expect(Double(counts) >= 0.97 * Double(total), "\(counts) of \(total) have TextKit 2's line count")
    }
}
#endif
