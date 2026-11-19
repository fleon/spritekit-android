#if canImport(CoreText) && os(macOS)
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// Justified left-to-right lines widened as UIKit's string drawing widens
/// them (`Justification`): spaces first, then letters too, then spaces
/// again. Each line's ink at 4x split where it leaves a gap of over three
/// points (a word, or once its letters widen, a letter), against UIKit's
/// on Catalyst (macOS 27.2) at 160 points wide; runs between "|" in the
/// second face.
@Suite("Justified left-to-right lines widen as UIKit widens them")
struct JustifiedLettersTests {
    static let paragraphs: [(String, String, CGFloat, String, CGFloat, [[(CGFloat, CGFloat)]])] = [
        ("Hello world again and extraordinarily long words", "Montserrat-Black", 15.0, "Montserrat-Black", 15.0, [
            [(0.75, 42.0), (54.25, 101.25), (114.25, 159.25)],
            [(0.25, 30.25), (39.0, 160.0)],
            [(0.75, 35.5), (40.75, 91.0)],
        ]),
        ("Hi there unbelievably kind folks", "Montserrat-Black", 15.0, "Montserrat-Black", 15.0, [
            [(0.75, 11.25), (16.5, 20.75), (98.5, 105.25), (110.5, 119.75), (125.0, 134.25), (139.75, 145.75), (150.25, 159.5)],
            [(0.75, 9.75), (16.0, 25.25), (31.75, 41.25), (46.75, 56.0), (62.0, 65.5), (71.5, 75.75), (81.25, 90.5), (95.5, 105.75), (110.5, 119.25), (125.5, 135.0), (141.0, 144.5), (150.0, 160.0)],
            [(0.75, 36.0), (41.0, 81.0)],
        ]),
        ("a b c extraordinarily", "Montserrat-Black", 15.0, "Montserrat-Black", 15.0, [
            [(0.25, 9.0), (75.5, 85.0), (151.0, 160.0)],
            [(0.25, 121.25)],
        ]),
        ("Unbelievably unbreakable", "Montserrat-Black", 15.0, "Montserrat-Black", 15.0, [
            [(0.75, 11.0), (17.25, 26.5), (32.75, 42.25), (47.75, 57.0), (62.75, 66.25), (72.25, 76.5), (82.0, 91.25), (96.0, 106.25), (110.75, 119.5), (125.75, 135.25), (141.25, 144.75), (150.0, 160.0)],
            [(0.75, 102.25)],
        ]),
        ("one two three fourfivesixseven eight", "KoHo-Bold", 20.0, "KoHo-Bold", 20.0, [
            [(0.75, 9.5), (13.0, 22.5), (26.75, 35.25), (53.0, 75.0), (78.25, 87.0), (105.25, 111.5), (114.75, 124.25), (128.25, 147.0), (150.75, 159.25)],
            [(1.25, 17.5), (21.0, 158.75)],
            [(0.75, 44.25)],
        ]),
        ("Hi there wonderfully kind people", "Montserrat-Regular", 15.0, "Montserrat-Regular", 15.0, [
            [(1.75, 14.75), (23.5, 63.0), (71.0, 159.75)],
            [(1.5, 31.75), (38.75, 88.5)],
        ]),
        ("Small |Big| and small again here", "Montserrat-Black", 11.0, "Montserrat-Black", 24.0, [
            [(0.25, 32.75), (43.75, 85.5), (95.75, 118.0), (127.5, 159.25)],
            [(0.25, 32.75), (37.0, 63.5)],
        ]),
        ("Quite a fine day for walking far", "Montserrat-Black", 15.0, "Montserrat-Black", 15.0, [
            [(0.5, 44.25), (50.0, 58.75), (64.5, 96.0), (101.75, 131.75), (136.5, 159.75)],
            [(0.0, 64.75), (70.0, 92.5)],
        ]),
    ]

    @Test("Spaces, then letters, then spaces take a justified line's slack")
    func widening() throws {
        _ = Fonts.engine
        for (text, firstFace, firstSize, secondFace, secondSize, expected) in Self.paragraphs {
            let style = TextBlock.Style(alignment: .justified, lineSpacing: 20)
            let runs = text.split(separator: "|", omittingEmptySubsequences: false).enumerated().compactMap { index, part in
                part.isEmpty ? nil : TextBlock.Run(String(part), font: index % 2 == 0 ? FontKey(name: firstFace, size: firstSize)
                                                       : FontKey(name: secondFace, size: secondSize), colour: .white, style: style)
            }
            let block = try #require(TextBlock(runs: runs, maxWidth: 160, usesFontLeading: false))
            let context = BitmapContext(width: 640, height: 1200, scale: 4)
            block.draw(in: CGRect(x: 0, y: 0, width: 160, height: 300), context: context)
            let data = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
            var lines: [[Bool]] = []
            var current: [Bool]?
            for y in 0 ..< 1200 {
                let row = (0 ..< 640).map { data[(y * 640 + $0) * 4 + 3] > 60 }
                if row.contains(true) {
                    current = current.map { zip($0, row).map { $0 || $1 } } ?? row
                } else if let line = current {
                    lines.append(line)
                    current = nil
                }
            }
            #expect(lines.count == expected.count, "'\(text)': \(lines.count) lines")
            for (number, (columns, line)) in zip(lines, expected).enumerated() {
                var spans: [(CGFloat, CGFloat)] = []
                var start = -1, gap = 0
                for x in 0 ..< 640 {
                    if columns[x] {
                        if start < 0 { start = x }
                        gap = 0
                    } else if start >= 0 {
                        gap += 1
                        if gap > 12 { spans.append((CGFloat(start) / 4, CGFloat(x - gap + 1) / 4)); start = -1; gap = 0 }
                    }
                }
                if start >= 0 { spans.append((CGFloat(start) / 4, CGFloat(640 - gap) / 4)) }
                #expect(spans.count == line.count, "'\(text)' line \(number): \(spans)")
                for (ours, theirs) in zip(spans, line) {
                    #expect(abs(ours.0 - theirs.0) <= 0.75 && abs(ours.1 - theirs.1) <= 0.75,
                            "'\(text)' line \(number): \(ours) against \(theirs)")
                }
            }
        }
    }
}
#endif
