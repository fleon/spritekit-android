#if canImport(SpriteKit) && os(macOS)
import CoreText
import Foundation
@testable import SpriteKitShim
import Testing
@testable import TextShaping

/// Paragraphs of right-to-left and mixed text laid out at a width of 160:
/// the lines and where each starts across, as Core Text's framesetter breaks
/// and places them, and the block's width as `boundingRect` reports it, a
/// right-to-left line's trailing spaces left out. Natural alignment is
/// UIKit's, the interface's direction (`natural`), where the framesetter's
/// is the paragraph's, so it's compared with UIKit's drawing.
@Suite("Right-to-left paragraphs as the text system lays them out")
struct BidiStringDrawingParityTests {
    static let paragraphs = [
        "سلام عليكم ورحمة الله وبركاته", "שלום עולם, זהו משפט ארוך מעט",
        "Hello עולם and مرحبا again friend", "مرحبا Hello world again and more",
    ]
    static let alignments: [(CTTextAlignment, TextBlock.Alignment)] = [
        (.left, .left), (.right, .right), (.center, .center),
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
                let expected = Self.coreText(text, apple)
                #expect(block.lines.count == expected.count, "'\(text)' \(ours)")
                for (line, (string, x)) in zip(block.lines, expected) {
                    let drawn = line.pieces.map(\.text).joined().replacingOccurrences(of: "\u{200F}", with: "")
                        .replacingOccurrences(of: "\u{200E}", with: "")
                    #expect(drawn == string, "'\(text)' \(ours)")
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

    /// Each line's ink across, from UIKit's `NSAttributedString.draw(in:)` on
    /// Catalyst at 4x (macOS 27.2), a left-to-right interface: naturally
    /// aligned, a right-to-left paragraph starts at the left, as it does
    /// aligned left, not at the right, where its own direction would put it.
    static let inked: [(String, TextBlock.Alignment, CGFloat, [(CGFloat, CGFloat)])] = [
        ("שלום עולם זה משפט ארוך", .natural, 200, [(0, 175.75)]),
        ("שלום עולם זה משפט ארוך", .left, 200, [(0, 175.75)]),
        ("שלום עולם זה משפט ארוך", .right, 200, [(23.75, 199.5)]),
        ("مرحبا بكم", .natural, 200, [(0, 59.25)]),
        ("مرحبا بكم", .right, 200, [(140.25, 199.75)]),
        ("Hello world, a sentence", .natural, 200, [(0.75, 190.75)]),
        ("שלום עולם זה משפט ארוך מאוד שנשבר לשתי שורות לפחות", .natural, 160, [(0.5, 139.75), (0.25, 159.25), (0.25, 89.75)]),
        ("שלום world, זה משפט עם English words", .natural, 160, [(0.5, 157), (0.75, 139.25)]),
    ]

    @Test("Natural alignment follows the interface's direction, not the paragraph's, as UIKit draws it")
    func natural() throws {
        let font = Fonts.display(15)
        for (text, alignment, width, expected) in Self.inked {
            let block = try #require(TextBlock(runs: [TextBlock.Run(text, font: font, colour: .white, style: TextBlock.Style(alignment: alignment))],
                                               maxWidth: width, usesFontLeading: false))
            if alignment == .natural, block.lines.first?.rightToLeft == true {
                let left = try #require(TextBlock(runs: [TextBlock.Run(text, font: font, style: TextBlock.Style(alignment: .left))],
                                                  maxWidth: width, usesFontLeading: false))
                #expect(block.lines.map { TextBlock.offset(of: $0, in: width) } == left.lines.map { TextBlock.offset(of: $0, in: width) },
                        "'\(text)' natural starts its lines where left does")
            }
            let columns = Int(width) * 4
            let context = BitmapContext(width: columns, height: 240, scale: 4)
            block.draw(in: CGRect(x: 0, y: 0, width: width, height: 60), context: context)
            let data = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
            for (number, line) in expected.enumerated() {
                var low = columns, high = -1
                for y in number * 76 ..< min(240, (number + 1) * 76) {
                    for x in 0 ..< columns where data[(y * columns + x) * 4 + 3] > 60 {
                        low = min(low, x)
                        high = max(high, x)
                    }
                }
                let left = CGFloat(low) / 4, right = CGFloat(high + 1) / 4
                #expect(abs(left - line.0) <= 0.75 && abs(right - line.1) <= 0.75,
                        "'\(text)' \(alignment) line \(number): \(left)…\(right) against \(line)")
            }
        }
    }
}
#endif
