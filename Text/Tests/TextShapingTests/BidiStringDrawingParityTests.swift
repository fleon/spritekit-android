#if canImport(SpriteKit) && os(macOS)
import CoreText
import Foundation
@testable import SpriteKitShim
import Testing
@testable import TextShaping

/// Paragraphs of right-to-left and mixed text laid out as UIKit lays them
/// out at a width of 160: the lines and where each starts across, as Core
/// Text's framesetter breaks and places them (but natural alignment, which
/// UIKit takes from the app's direction, left, where the framesetter takes
/// the paragraph's), the block's width as `boundingRect` reports it, and
/// the words drawn, natural and justified, against UIKit's own drawing.
@Suite("Right-to-left paragraphs as the text system lays them out")
struct BidiStringDrawingParityTests {
    static let paragraphs = [
        "سلام عليكم ورحمة الله وبركاته", "שלום עולם, זהו משפט ארוך מעט",
        "Hello עולם and مرحبا again friend", "مرحبا Hello world again and more",
    ]
    static let alignments: [(CTTextAlignment, TextBlock.Alignment)] = [
        (.natural, .natural), (.left, .left), (.right, .right), (.center, .center),
    ]

    /// Core Text's lines: their text and where each starts across.
    static func coreText(_ text: String, _ alignment: CTTextAlignment) -> [(String, CGFloat)] {
        _ = CoreTextFallback.registered
        var align = alignment
        let settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: &align)]
        let attributed = NSAttributedString(string: text, attributes: [
            .font: CTFontCreateWithName("Montserrat-Black" as CFString, 15, nil),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): CTParagraphStyleCreate(settings, settings.count),
        ])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: 160, height: 1000), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        return zip(lines, origins).map { line, origin in
            let range = CTLineGetStringRange(line)
            return ((text as NSString).substring(with: NSRange(location: range.location, length: range.length)), origin.x)
        }
    }

    @Test("Lines break and start across as Core Text's")
    func lines() throws {
        let font = Fonts.display(15)
        for text in Self.paragraphs {
            for (apple, ours) in Self.alignments {
                let block = try #require(TextBlock(runs: [TextBlock.Run(text, font: font, style: TextBlock.Style(alignment: ours))],
                                                   maxWidth: 160, usesFontLeading: false))
                // UIKit's natural is the app's direction: left (`words`).
                let expected = Self.coreText(text, apple == .natural ? .left : apple)
                #expect(block.lines.count == expected.count, "'\(text)' \(ours)")
                for (line, (string, x)) in zip(block.lines, expected) {
                    let drawn = line.pieces.map(\.text).joined().replacingOccurrences(of: "\u{200F}", with: "")
                        .replacingOccurrences(of: "\u{200E}", with: "")
                    // The pieces are in the order drawn: the same characters.
                    #expect(String(drawn.sorted()) == String(string.sorted()), "'\(text)' \(ours)")
                    #expect(abs(TextBlock.offset(of: line, in: 160) - x) < 1e-3, "'\(text)' \(ours) x \(TextBlock.offset(of: line, in: 160)) against \(x)")
                }
            }
        }
    }

    /// `boundingRect(with:options:attributes:context:)`'s width at 160 with
    /// `.usesLineFragmentOrigin`, on Mac Catalyst (macOS 27.2): a
    /// right-to-left line's trailing space hangs past its left edge (no
    /// further than the rect's) and counts, but naturally aligned it doesn't.
    static let widths: [(String, TextBlock.Alignment, CGFloat)] = [
        ("سلام عليكم ورحمة الله وبركاته", .natural, 130.292), ("سلام عليكم ورحمة الله وبركاته", .left, 130.292),
        ("سلام عليكم ورحمة الله وبركاته", .right, 134.792), ("سلام عليكم ورحمة الله وبركاته", .center, 134.792),
        ("שלום עולם, זהו משפט ארוך מעט", .natural, 150.211), ("שלום עולם, זהו משפט ארוך מעט", .left, 150.211),
        ("שלום עולם, זהו משפט ארוך מעט", .right, 154.711), ("שלום עולם, זהו משפט ארוך מעט", .center, 154.711),
        ("مرحبا Hello world again and more", .natural, 132.911), ("مرحبا Hello world again and more", .left, 132.911),
        ("مرحبا Hello world again and more", .right, 137.411), ("مرحبا Hello world again and more", .center, 137.411),
        ("Hello עולם and مرحبا again friend", .natural, 159.992), ("Hello עולם and مرحبا again friend", .right, 159.992),
        ("سلام عليكم", .natural, 67.192), ("!שלום", .natural, 40.247), ("!שלום", .center, 40.247),
    ]

    @Test("The block is as wide as UIKit's boundingRect")
    func width() throws {
        let font = Fonts.display(15)
        for (text, alignment, expected) in Self.widths {
            let block = try #require(TextBlock(runs: [TextBlock.Run(text, font: font, style: TextBlock.Style(alignment: alignment))],
                                               maxWidth: 160, usesFontLeading: false))
            #expect(abs(block.size(in: 160).width - expected) < 1e-3, "'\(text)' \(alignment) \(block.size(in: 160).width)")
        }
    }

    /// Each line's words, as ink spans across, from UIKit's
    /// `NSString.draw(in:withAttributes:)` on Catalyst at 4x (macOS 27.2;
    /// gaps over two points split words): natural alignment draws a
    /// right-to-left paragraph from the left, and justified Hebrew and mixed
    /// lines widen their spaces, the last line natural. (Justified Arabic
    /// lines stretch their words with kashida instead, which isn't done
    /// here: they widen their spaces, so they're left out.)
    static let drawn: [(String, TextBlock.Alignment, [[(CGFloat, CGFloat)]])] = [
        ("שלום עולם זה משפט ארוך מאוד שנשבר לשתי שורות לפחות", .justified, [
            [(0.5, 38.5), (50.75, 67.75), (79.25, 112.75), (124.5, 159.5)],
            [(0.25, 34.75), (40, 85), (90, 123), (128.25, 159.5)],
            [(0.25, 44), (49.25, 89.75)],
        ]),
        ("שלום עולם זה משפט ארוך מאוד שנשבר לשתי שורות לפחות", .natural, [
            [(0.5, 38.5), (44, 61.25), (66, 99.5), (104.75, 139.75)],
            [(0.25, 34.75), (40, 85), (89.75, 122.75), (128, 159.25)],
            [(0.25, 44), (49.25, 89.75)],
        ]),
        ("Hello עולם and שלום again friend", .justified, [
            [(0.75, 41.5), (47.75, 81.25), (87.75, 117.75), (124.5, 159.5)],
            [(0.25, 44.75), (49.5, 98.5)],
        ]),
        ("שלום world, זה משפט עם English words", .justified, [
            [(0.5, 38.5), (44.75, 62), (67.75, 118.5), (124.5, 159.5)],
            [(0.75, 59.5), (64.25, 114.75), (119.75, 139.25)],
        ]),
        ("שלום world, זה משפט עם English words", .natural, [
            [(0.5, 38.5), (44, 61.25), (66, 116.75), (122, 157)],
            [(0.75, 59.5), (64.25, 114.75), (119.75, 139.25)],
        ]),
    ]

    @Test("Words are drawn where UIKit draws them")
    func words() throws {
        let font = Fonts.display(15)
        for (text, alignment, expected) in Self.drawn {
            let block = try #require(TextBlock(runs: [TextBlock.Run(text, font: font, colour: .white, style: TextBlock.Style(alignment: alignment))],
                                               maxWidth: 160, usesFontLeading: false))
            let context = BitmapContext(width: 640, height: 240, scale: 4)
            block.draw(in: CGRect(x: 0, y: 0, width: 160, height: 60), context: context)
            let data = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
            for (number, line) in expected.enumerated() {
                var columns = [Bool](repeating: false, count: 640)
                for y in number * 76 ..< min(240, (number + 1) * 76) {
                    for x in 0 ..< 640 where data[(y * 640 + x) * 4 + 3] > 60 { columns[x] = true }
                }
                var spans: [(CGFloat, CGFloat)] = []
                var start = -1, gap = 0
                for x in 0 ..< 640 {
                    if columns[x] {
                        if start < 0 { start = x }
                        gap = 0
                    } else if start >= 0 {
                        gap += 1
                        if gap > 8 { spans.append((CGFloat(start) / 4, CGFloat(x - gap + 1) / 4)); start = -1; gap = 0 }
                    }
                }
                if start >= 0 { spans.append((CGFloat(start) / 4, CGFloat(640 - gap) / 4)) }
                #expect(spans.count == line.count, "'\(text)' \(alignment) line \(number): \(spans)")
                for (ours, theirs) in zip(spans, line) {
                    #expect(abs(ours.0 - theirs.0) <= 0.75 && abs(ours.1 - theirs.1) <= 0.75,
                            "'\(text)' \(alignment) line \(number): \(ours) against \(theirs)")
                }
            }
        }
    }

    /// Attributed text in two faces (Montserrat Black 15, SemiBold 20),
    /// each run its own colour, drawn by UIKit on Catalyst at 4x: each run's
    /// ink across. The runs are drawn in the bidirectional algorithm's
    /// order across them; natural alignment starts the lines at the left.
    static let styled: [(runs: [(String, Bool)], ink: [Int: (CGFloat, CGFloat)])] = [
        ([("שלום ", false), ("world", true), (" עולם", false)], [0: (102, 137), 1: (38.5, 95.75), 2: (0.25, 33.25)]),
        ([("Hello ", false), ("שלום", true), (" עולם", false), (" end", false)],
         [0: (0.75, 41.5), 1: (85.25, 131.5), 2: (46.5, 79.75), 3: (0.25, 30.25)]),
        ([("מילה ", false), ("ארוכה", true), (" ועוד מילים", false), (" כאן", true)], [0: (95.75, 129.75), 1: (33.75, 90.5)]),
    ]

    @Test("Runs in several styles are drawn in the bidirectional algorithm's order, as UIKit draws them")
    func styledRuns() throws {
        let colours: [SKColor] = [.red, .green, .blue, .white]
        for test in Self.styled {
            let runs = test.runs.enumerated().map { index, part in
                TextBlock.Run(part.0, font: part.1 ? FontKey(name: "Montserrat-SemiBold", size: 20) : Fonts.display(15), colour: colours[index])
            }
            let block = try #require(TextBlock(runs: runs, maxWidth: 160, usesFontLeading: false))
            let context = BitmapContext(width: 640, height: 320, scale: 4)
            block.draw(in: CGRect(x: 0, y: 0, width: 160, height: 80), context: context)
            let data = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
            var extents: [Int: (Int, Int)] = [:]
            for pixel in 0 ..< 640 * 320 {
                let (r, g, b) = (data[pixel * 4], data[pixel * 4 + 1], data[pixel * 4 + 2])
                let colour: Int? = r > 120 && g > 120 && b > 120 ? 3 : r > 120 && g < 80 && b < 80 ? 0
                    : g > 120 && r < 80 && b < 80 ? 1 : b > 120 && r < 80 && g < 80 ? 2 : nil
                guard let colour else { continue }
                let x = pixel % 640
                extents[colour] = extents[colour].map { (min($0.0, x), max($0.1, x)) } ?? (x, x)
            }
            let name = test.runs.map(\.0).joined()
            for (colour, span) in test.ink {
                let ours = try #require(extents[colour], Comment(rawValue: "'\(name)' run \(colour)"))
                let left = CGFloat(ours.0) / 4, right = CGFloat(ours.1 + 1) / 4
                #expect(abs(left - span.0) <= 0.75 && abs(right - span.1) <= 0.75, "'\(name)' run \(colour): \(left)…\(right) against \(span)")
            }
        }
    }
}
#endif
