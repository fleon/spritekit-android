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

    /// Justified Arabic, each line's words as ink spans across (gaps over
    /// three points split them), from UIKit's `NSAttributedString.draw(in:)`
    /// on Catalyst at 4x (macOS 27.2), the lines 20 points apart so no ink
    /// joins them: a line with initial letters widens by kashida after each,
    /// its spaces as they are; one without (only right-joining letters)
    /// widens its spaces (`Kashida`). In Montserrat, the Arabic falling back
    /// to Geeza Pro, whose kashida glyph is its own; and in Noto Naskh Arabic,
    /// Android's, a tatweel.
    static let kashida: [(String, noto: Bool, [[(CGFloat, CGFloat)]])] = [
        ("سلام عليكم ورحمة الله وبركاته يا أصدقائي الأعزاء", false, [
            [(0.5, 15), (19.75, 68.5), (73, 116), (120.5, 160)],
            [(0.25, 37), (42, 96.75), (103.25, 112.75), (117, 160)],
        ]),
        ("مرحبا بكم في هذه اللعبة الجميلة جدا اليوم وغدا", false, [
            [(0, 35.75), (41.25, 65.75), (70.25, 90.25), (94.75, 116.5), (122.5, 159.75)],
            [(2, 26.5), (31, 60.5), (67.75, 88.25), (92.25, 137.5)],
        ]),
        ("دار ورد زاد راد دار ورد زاد راد دار ورد", false, [
            [(1, 16.5), (23.5, 42.25), (47.5, 66), (72.75, 88), (95, 110.75), (117.75, 136.5), (141.75, 160)],
            [(1, 19.75), (23.25, 41.75), (47, 62)],
        ]),
        ("كتب الطالب الدرس في المدرسة الكبيرة", false, [
            [(0, 23.5), (27.75, 69.25), (74.5, 125), (130, 160)],
            [(0.25, 40), (44.75, 86)],
        ]),
        ("سلام عليكم ورحمة الله وبركاته يا أصدقائي الأعزاء", true, [
            [(1, 18), (23.5, 69.5), (74.5, 117.25), (121.5, 159.25)],
            [(1, 36.25), (41.25, 88.5), (93.5, 101.5), (106.5, 145)],
        ]),
        ("مرحبا بكم في هذه اللعبة الجميلة جدا اليوم وغدا", true, [
            [(1.5, 33.5), (38.75, 63), (68, 87.75), (92.75, 115.25), (120.25, 159.25)],
            [(1, 26), (30.75, 57), (62, 81.75), (87, 125)],
        ]),
        ("كتب الطالب الدرس في المدرسة الكبيرة", true, [
            [(1, 23), (28, 69.5), (74.5, 124.5), (129.75, 159.75)],
            [(1.5, 36.75), (42.25, 84.75)],
        ]),
    ]

    @Test("Justified Arabic widens with kashida where UIKit puts them")
    func kashida() throws {
        for (text, noto, expected) in Self.kashida {
            let font = noto ? FontKey(name: "NotoNaskhArabicUI-Bold", size: 15) : Fonts.display(15)
            let style = TextBlock.Style(alignment: .justified, lineSpacing: 20)
            let block = try #require(TextBlock(runs: [TextBlock.Run(text, font: font, colour: .white, style: style)],
                                               maxWidth: 160, usesFontLeading: false))
            let context = BitmapContext(width: 640, height: 1200, scale: 4)
            block.draw(in: CGRect(x: 0, y: 0, width: 160, height: 300), context: context)
            let data = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
            // Lines: rows with ink, between rows without.
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
            #expect(lines.count == expected.count, "'\(text)' \(font.name): \(lines.count) lines")
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
                #expect(spans.count == line.count, "'\(text)' \(font.name) line \(number): \(spans)")
                for (ours, theirs) in zip(spans, line) {
                    #expect(abs(ours.0 - theirs.0) <= 0.75 && abs(ours.1 - theirs.1) <= 0.75,
                            "'\(text)' \(font.name) line \(number): \(ours) against \(theirs)")
                }
            }
        }
    }

    /// Explicit overrides, embeddings and isolates opened in one attribute
    /// run and closed in a later one (Montserrat Black 15 and SemiBold 20,
    /// each run its own colour), against Core Text drawing the same runs on
    /// one line: what one opens governs the runs after it. Lopsided words
    /// (Wim, Wll, ממו) put a run's ink elsewhere when it reads the other way.
    static let spanning: [[(String, Bool)]] = [
        [("ab \u{202E}Wim", false), ("Wll", true), (" xy\u{202C} end", false)],
        [("שלום \u{202D}עולם ", false), ("ממו", true), ("\u{202C} סוף", false)],
        [("abc \u{2067}שלום ", false), ("Wim Wll", true), ("\u{2069} end", false)],
        [("abc \u{202B}Wim ", false), ("Wll", true), ("\u{202C} end", false)],
        [("שלום \u{2066}Wim ", false), ("Wll", true), (" mW\u{2069} סוף", false)],
    ]

    /// Each colour's words (ink apart by 3¾ points or more), left to
    /// right, in an RGBA bitmap 4 pixels a point: each one's extent across
    /// and its centre, each pixel weighted by its coverage.
    static func words(_ data: UnsafePointer<UInt8>, width: Int, height: Int) -> [Int: [(left: CGFloat, right: CGFloat, centre: CGFloat)]] {
        var mass: [Int: [CGFloat]] = [:]
        for y in 0 ..< height {
            for x in 0 ..< width {
                let pixel = (y * width + x) * 4
                let channels = [data[pixel], data[pixel + 1], data[pixel + 2]]
                // Its colour the channel well above the others.
                guard let colour = channels.indices.max(by: { channels[$0] < channels[$1] }), channels[colour] > 60,
                      channels.indices.allSatisfy({ $0 == colour || Int(channels[$0]) * 2 < Int(channels[colour]) }) else { continue }
                mass[colour, default: [CGFloat](repeating: 0, count: width)][x] += CGFloat(channels[colour])
            }
        }
        return mass.mapValues { columns in
            var words: [(left: CGFloat, right: CGFloat, centre: CGFloat)] = []
            var start = -1, end = -1, total: CGFloat = 0, moment: CGFloat = 0
            func close() {
                guard start >= 0 else { return }
                words.append((CGFloat(start) / 4, CGFloat(end + 1) / 4, moment / total / 4))
                start = -1
                total = 0
                moment = 0
            }
            for x in 0 ..< width where columns[x] > 0 {
                if start >= 0, x - end > 15 { close() }
                if start < 0 { start = x }
                end = x
                total += columns[x]
                moment += columns[x] * (CGFloat(x) + 0.5)
            }
            close()
            return words
        }
    }

    @Test("Explicit controls govern the runs after the one that opens them, as in Core Text")
    func spanningRuns() throws {
        _ = Fonts.engine
        _ = CoreTextFallback.registered
        // Device RGB, so Core Text draws them unconverted.
        let device = CGColorSpaceCreateDeviceRGB()
        let colours: [(SKColor, CGColor)] = try [(SKColor.red, [1, 0, 0, 1]), (.green, [0, 1, 0, 1]), (.blue, [0, 0, 1, 1])].map {
            ($0.0, try #require(CGColor(colorSpace: device, components: $0.1)))
        }
        for runs in Self.spanning {
            let name = runs.map(\.0).joined()
            // Core Text's line, drawn from the left at 4x.
            let attributed = NSMutableAttributedString()
            for (index, (text, large)) in runs.enumerated() {
                attributed.append(NSAttributedString(string: text, attributes: [
                    .font: CTFontCreateWithName((large ? "Montserrat-SemiBold" : "Montserrat-Black") as CFString, large ? 20 : 15, nil),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): colours[index].1,
                ]))
            }
            let line = CTLineCreateWithAttributedString(attributed)
            var pixels = [UInt8](repeating: 0, count: 1200 * 160 * 4)
            let theirs = try pixels.withUnsafeMutableBytes { buffer -> [Int: [(left: CGFloat, right: CGFloat, centre: CGFloat)]] in
                let context = try #require(CGContext(data: buffer.baseAddress, width: 1200, height: 160, bitsPerComponent: 8, bytesPerRow: 1200 * 4,
                                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.scaleBy(x: 4, y: 4)
                context.textPosition = CGPoint(x: 0, y: 12)
                CTLineDraw(line, context)
                return Self.words(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), width: 1200, height: 160)
            }
            // Ours: the same runs, one line from the left.
            let block = try #require(TextBlock(runs: runs.enumerated().map { index, run in
                TextBlock.Run(run.0, font: run.1 ? FontKey(name: "Montserrat-SemiBold", size: 20) : Fonts.display(15), colour: colours[index].0)
            }, maxWidth: 300, usesFontLeading: false))
            #expect(block.lines.count == 1, "'\(name)'")
            let context = BitmapContext(width: 1200, height: 160, scale: 4)
            block.draw(in: CGRect(x: 0, y: 0, width: 300, height: 40), context: context)
            let ours = Self.words(try #require(context.data?.assumingMemoryBound(to: UInt8.self)), width: 1200, height: 160)
            #expect(theirs.count == runs.count, "'\(name)'")
            for (colour, apple) in theirs {
                let mine = ours[colour] ?? []
                #expect(mine.count == apple.count, "'\(name)' run \(colour): \(mine) against \(apple)")
                for (word, theirs) in zip(mine, apple) {
                    #expect(abs(word.left - theirs.left) <= 0.75 && abs(word.right - theirs.right) <= 0.75 && abs(word.centre - theirs.centre) <= 0.5,
                            "'\(name)' run \(colour): \(word) against \(theirs)")
                }
            }
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

    /// Justified lines mixing Latin with Arabic: runs split at "|", the
    /// Latin in Montserrat Black 15, the Arabic in Noto Naskh Arabic 15
    /// (Android's), each line's words as ink spans across (gaps over three
    /// points split them), from UIKit's `NSAttributedString.draw(in:)` on
    /// Catalyst at 4x (macOS 27.2), the lines 20 points apart. The initial
    /// places fill to 0.8 em; then the medial places and the spaces left of
    /// the Arabic share the rest (`Kashida.Shares`). (Lines of Latin alone
    /// are left out: past half an em UIKit widens their letters too, which
    /// left-to-right text here doesn't.)
    static let mixed: [(String, [[(CGFloat, CGFloat)]])] = [
        ("Hello world |مرحبا بكم| again and more words here", [
            [(0.75, 41.5), (48.25, 94.75), (103.25, 159.25)],
            [(1, 27), (32.5, 77), (82.25, 112.25), (118, 159.5)],
            [(0, 50), (55.25, 91.5)],
        ]),
        ("Hello world |عليكم| and more", [
            [(0.75, 41.5), (49.5, 96.25), (105.75, 159.75)],
            [(0.25, 30.25), (35.75, 77.5)],
        ]),
        ("Big |مرحبا بكم| again and more", [
            [(0.75, 26.25), (32.5, 58.5), (63.5, 109.5), (114.75, 159.25)],
            [(0.25, 30.25), (35.75, 77.5)],
        ]),
        ("Hello world |مرحبا| again and more", [
            [(0.75, 41.5), (48.25, 94.75), (103.25, 159.25)],
            [(0.25, 44.75), (50, 80), (85.5, 127.25)],
        ]),
        ("Go |عليكم| and more words here", [
            [(0.25, 21.5), (29, 77.25), (82.25, 112.25), (118, 159.5)],
            [(0, 50), (55.25, 91.5)],
        ]),
        ("aa bb |عليكم| cc dd ee ff gg", [
            [(0.25, 18.5), (24, 44.25), (50, 87), (92, 110.25), (115, 135.25), (140.5, 159.5)],
            [(0, 13.5), (17.75, 38)],
        ]),
        ("|شكرا لك| Hello world and more here", [
            [(0.75, 41.5), (46, 92.5), (98.5, 119.75), (124.75, 159.25)],
            [(0.25, 30.25), (35.75, 77.5), (82.75, 119)],
        ]),
        ("|عليكم بكم| and more words", [
            [(0.25, 30.25), (35.75, 77.5), (83.25, 112.5), (117.5, 159.75)],
            [(0, 50)],
        ]),
    ]

    @Test("Justified lines mixing Latin with Arabic widen as UIKit widens them")
    func mixedKashida() throws {
        let latin = Fonts.display(15), arabic = FontKey(name: "NotoNaskhArabicUI-Bold", size: 15)
        for (text, expected) in Self.mixed {
            let style = TextBlock.Style(alignment: .justified, lineSpacing: 20)
            let runs = text.split(separator: "|", omittingEmptySubsequences: false).enumerated().compactMap { index, part in
                part.isEmpty ? nil : TextBlock.Run(String(part), font: index % 2 == 1 ? arabic : latin, colour: .white, style: style)
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
