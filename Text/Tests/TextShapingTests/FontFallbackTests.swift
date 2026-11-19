#if canImport(SpriteKit) && os(macOS)
import CoreText
import Foundation
import SpriteKit
import SpriteKitShim
import Testing
@testable import TextShaping

/// Characters a line's face has no glyph for, drawn from the face the
/// platform falls back to. On the Mac the provider is Core Text's own
/// fallback (`CoreTextFallback`, Japanese for Han: FreeType can't read the
/// Mac's PingFang), so lines, labels and string drawing are checked against
/// Apple's on the same faces.
@Suite("Characters a face lacks fall back as Core Text's do")
struct FontFallbackTests {
    static let fonts: [(String, CGFloat)] = [("Montserrat-Black", 20), ("Montserrat-SemiBold", 15), ("KoHo-Bold", 20)]
    static let texts = ["クロ1976", "クロ ロ", "漢字テスト", "한국어", "ไทย", "سلام", "Aé", "Привет", "日本語 and English",
                        "مرحبا بك", "Ωμέγα", "Level ไทย", "x 한 y"]

    static func coreTextLine(_ text: String, _ font: String, _ size: CGFloat) -> CTLine {
        _ = CoreTextFallback.registered
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: CTFontCreateWithName(font as CFString, size, nil),
            NSAttributedString.Key(kCTLanguageAttributeName as String): "ja",
        ]))
    }

    /// Consecutive runs in one face, as one.
    static func merged(_ faces: [String]) -> [String] {
        faces.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
    }

    @Test("Lines fall back to Core Text's faces, at Core Text's widths")
    func lines() {
        for (name, size) in Self.fonts {
            let font = FontKey(name: name, size: size)
            for text in Self.texts {
                let line = Self.coreTextLine(text, name, size)
                let apple = Self.merged((CTLineGetGlyphRuns(line) as! [CTRun]).map {
                    CTFontCopyPostScriptName((CTRunGetAttributes($0) as NSDictionary)[kCTFontAttributeName] as! CTFont) as String
                })
                let ours = Self.merged((Fonts.engine.shape(text, font: font) ?? []).map { $0.font ?? name })
                #expect(ours == apple, "\(name) '\(text)'")
                // A variable instance within a hundredth: HarfBuzz rounds its kerning deltas.
                let tolerance = name == "Montserrat-SemiBold" ? 0.01 : 1e-4
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                #expect(abs(Fonts.engine.measure(text, font: font).advance - width) <= tolerance, "\(name) '\(text)'")
            }
        }
    }

    @Test("Label frames match SpriteKit's with fallback text in them")
    @MainActor
    func labels() {
        _ = CoreTextFallback.registered
        for (name, size) in Self.fonts {
            for text in Self.texts {
                let apple = SpriteKit.SKLabelNode(attributedText: NSAttributedString(string: text, attributes: [
                    .font: NSFont(name: name, size: size)!, NSAttributedString.Key(kCTLanguageAttributeName as String): "ja",
                ]))
                let ours = SpriteKitShim.SKLabelNode(fontNamed: name)
                ours.fontSize = size
                ours.text = text
                #expect(apple.frame == ours.contentFrame, "\(name) \(size) '\(text)'")
            }
        }
    }

    @Test("Right-to-left words a space apart are drawn last word first")
    func rightToLeft() throws {
        let runs = try #require(Fonts.engine.shape("مرحبا بك", font: Fonts.display(20)))
        #expect(runs.map(\.script) == [.arabic, .common, .arabic])
        // بك starts at byte 11, after مرحبا and the space.
        #expect(runs.first?.byteOffset == 11 && runs.last?.byteOffset == 0)
        let latin = try #require(Fonts.engine.shape("ab سلام cd", font: Fonts.display(20)))
        #expect(latin.map(\.byteOffset) == latin.map(\.byteOffset).sorted(), "a lone right-to-left run stays where it is")
    }

    @Test("Where the face has every glyph nothing changes")
    func coveredText() throws {
        let library = FontLibrary()
        let plain = TextEngine(library: library, atlas: GlyphAtlas(library: library))
        for file in ["Montserrat", "KoHo-Bold"] {
            _ = try library.register(path: Fonts.directory + "/" + file + ".ttf")
        }
        for (font, text) in [(Fonts.display(20), "Level Select"), (Fonts.display(13), "Español (México) 1976"),
                             (Fonts.koHo(20), "ภาษาไทย Thai"), (Fonts.display(20), "Привет, мир")] {
            let runs = try #require(Fonts.engine.shape(text, font: font))
            #expect(runs.allSatisfy { $0.font == nil })
            #expect(runs == plain.shape(text, font: font))
            #expect(Fonts.engine.measure(text, font: font) == plain.measure(text, font: font))
            #expect(Fonts.engine.characterAdvances(text, font: font) == plain.characterAdvances(text, font: font))
        }
    }

    /// Core Text widens Apple Color Emoji at text sizes (23 points at 20,
    /// 13 at 10) beyond its own advances; Android's emoji face has no such
    /// quirk, so the emoji's own advance is what's laid out. Colour glyphs
    /// aren't drawn yet (the atlas is coverage only).
    @Test("Emoji fall back to the emoji face, at its own advances")
    func emoji() throws {
        let runs = try #require(Fonts.engine.shape("a😀b👍🏽", font: Fonts.display(20)))
        #expect(Self.merged(runs.map { $0.font ?? "-" }) == ["-", "AppleColorEmoji", "-", "AppleColorEmoji"])
        let emoji = runs.filter { $0.font == "AppleColorEmoji" }
        #expect(emoji.map(\.advance) == [20, 20], "one em each, the face's own advance")
    }

    @Test("The fallback decision is cached, and fallback text measures the same on many threads")
    func threads() async {
        let font = Fonts.display(17)
        let texts = ["クロ1976", "한국어", "ไทย", "سلام", "x 한 y"]
        let expected = texts.map { Fonts.engine.measure($0, font: font).advance }
        let results = await withTaskGroup(of: [CGFloat].self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    (0 ..< 20).flatMap { _ in texts.map { text in
                        Fonts.engine.characterAdvances(text + " ", font: font).reduce(0, +) - Fonts.engine.characterAdvances(" ", font: font).reduce(0, +)
                    } }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        for result in results {
            for (index, advance) in result.enumerated() {
                #expect(abs(advance - expected[index % texts.count]) < 1e-9)
            }
        }
    }
}

/// UIKit's string drawing with fallback text, measured on Mac Catalyst
/// (macOS 27.2) with the same fonts: a line stays as tall as its own
/// face's line (UIKit doesn't grow it for a fallback face) and is as wide
/// as the faces it falls back to make it.
@Suite("Fallback text drawn into bitmaps as UIKit draws it")
struct FallbackStringDrawingTests {
    struct Rect: CustomTestStringConvertible {
        var font: String, size: CGFloat, text: String, alignment: TextBlock.Alignment, expected: CGRect
        init(_ font: String, _ size: CGFloat, _ text: String, _ alignment: TextBlock.Alignment, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
            self.font = font; self.size = size; self.text = text; self.alignment = alignment
            expected = CGRect(x: x, y: y, width: w, height: h)
        }
        var testDescription: String { "\(font) \(size) '\(text)' \(alignment)" }
    }

    /// At width 160, with `.usesLineFragmentOrigin`. Wrapped Thai, Hangul
    /// and left-aligned Arabic paragraphs are left out: they turn on where
    /// lines break (ICU's Thai dictionary, breaks between Hangul syllables)
    /// and on a paragraph that starts right to left, not on fallback.
    static let rects: [Rect] = [
        Rect("Montserrat-Black", 15.0, "クロ1976", .left, x: 0.0, y: 0.0, w: 65.475, h: 19.0),
        Rect("Montserrat-Black", 15.0, "クロ1976", .center, x: 0.0, y: 0.0, w: 65.475, h: 19.0),
        Rect("Montserrat-Black", 15.0, "한국어 텍스트", .left, x: 0.0, y: 0.0, w: 82.35, h: 19.0),
        Rect("Montserrat-Black", 15.0, "한국어 텍스트", .center, x: 0.0, y: 0.0, w: 82.35, h: 19.0),
        Rect("Montserrat-Black", 15.0, "Level ไทย", .left, x: 0.0, y: 0.0, w: 72.46921875, h: 19.0),
        Rect("Montserrat-Black", 15.0, "Level ไทย", .center, x: 0.0, y: 0.0, w: 72.46921875, h: 19.0),
        Rect("Montserrat-Black", 15.0, "سلام عليكم", .left, x: 0.0, y: 0.0, w: 67.19213381555154, h: 19.0),
        Rect("Montserrat-Black", 15.0, "سلام عليكم", .center, x: 0.0, y: 0.0, w: 67.19213381555154, h: 19.0),
        Rect("Montserrat-Black", 15.0, "クロ1976 さんが ゲームを かちました", .left, x: 0.0, y: 0.0, w: 149.475, h: 38.0),
        Rect("Montserrat-Black", 15.0, "クロ1976 さんが ゲームを かちました", .center, x: 0.0, y: 0.0, w: 149.47500000000002, h: 38.0),
        Rect("Montserrat-Black", 15.0, "سلام عليكم ورحمة الله وبركاته", .center, x: 0.0, y: 0.0, w: 134.79249547920438, h: 38.0),
        Rect("KoHo-Bold", 20.0, "クロ1976", .left, x: 0.0, y: 0.0, w: 82.47999999999999, h: 26.0),
        Rect("KoHo-Bold", 20.0, "クロ1976", .center, x: 0.0, y: 0.0, w: 82.47999999999999, h: 26.0),
        Rect("KoHo-Bold", 20.0, "한국어 텍스트", .left, x: 0.0, y: 0.0, w: 109.4, h: 26.0),
        Rect("KoHo-Bold", 20.0, "한국어 텍스트", .center, x: 0.0, y: 0.0, w: 109.4, h: 26.0),
        Rect("KoHo-Bold", 20.0, "Level ไทย", .left, x: 0.0, y: 0.0, w: 85.6, h: 26.0),
        Rect("KoHo-Bold", 20.0, "Level ไทย", .center, x: 0.0, y: 0.0, w: 85.6, h: 26.0),
        Rect("KoHo-Bold", 20.0, "سلام عليكم", .left, x: 0.0, y: 0.0, w: 89.18951175406872, h: 26.0),
        Rect("KoHo-Bold", 20.0, "سلام عليكم", .center, x: 0.0, y: 0.0, w: 89.18951175406872, h: 26.0),
        Rect("KoHo-Bold", 20.0, "クロ1976 さんが ゲームを かちました", .left, x: 0.0, y: 0.0, w: 153.67999999999998, h: 78.0),
        Rect("KoHo-Bold", 20.0, "クロ1976 さんが ゲームを かちました", .center, x: 0.0, y: 0.0, w: 153.67999999999998, h: 78.0),
        Rect("KoHo-Bold", 20.0, "سلام عليكم ورحمة الله وبركاته", .center, x: 0.0, y: 0.0, w: 151.61916817359855, h: 52.0),
        Rect("Montserrat-SemiBold", 13.0, "クロ1976", .left, x: 0.0, y: 0.0, w: 54.83213486004814, h: 16.0),
        Rect("Montserrat-SemiBold", 13.0, "クロ1976", .center, x: 0.0, y: 0.0, w: 54.83213486303478, h: 16.0),
        Rect("Montserrat-SemiBold", 13.0, "한국어 텍스트", .left, x: 0.0, y: 0.0, w: 71.05306828528073, h: 16.0),
        Rect("Montserrat-SemiBold", 13.0, "한국어 텍스트", .center, x: 0.0, y: 0.0, w: 71.05306828528073, h: 16.0),
        Rect("Montserrat-SemiBold", 13.0, "Level ไทย", .left, x: 0.0, y: 0.0, w: 60.03354788438155, h: 16.0),
        Rect("Montserrat-SemiBold", 13.0, "Level ไทย", .center, x: 0.0, y: 0.0, w: 60.03354788438155, h: 16.0),
        Rect("Montserrat-SemiBold", 13.0, "سلام عليكم", .left, x: 0.0, y: 0.0, w: 57.91625092542539, h: 16.0),
        Rect("Montserrat-SemiBold", 13.0, "سلام عليكم", .center, x: 0.0, y: 0.0, w: 57.91625092542539, h: 16.0),
        Rect("Montserrat-SemiBold", 13.0, "クロ1976 さんが ゲームを かちました", .left, x: 0.0, y: 0.0, w: 155.54133971887697, h: 32.0),
        Rect("Montserrat-SemiBold", 13.0, "クロ1976 さんが ゲームを かちました", .center, x: 0.0, y: 0.0, w: 155.54133971887694, h: 32.0),
        Rect("Montserrat-SemiBold", 13.0, "سلام عليكم ورحمة الله وبركاته", .center, x: 0.0, y: 0.0, w: 152.81283371978475, h: 16.0),
    ]

    @Test("Bounding rects match UIKit's", arguments: rects)
    func boundingRect(_ item: Rect) {
        _ = Fonts.engine
        let runs = [TextBlock.Run(item.text, font: FontKey(name: item.font, size: item.size), style: TextBlock.Style(alignment: item.alignment))]
        let rect = TextBlock.boundingRect(of: runs, size: CGSize(width: 160, height: 10_000), usesLineFragmentOrigin: true, usesFontLeading: false)
        let tolerance = item.font == "Montserrat-SemiBold" ? 0.01 : 1e-4
        #expect(abs(rect.minX - item.expected.minX) <= tolerance && rect.minY == item.expected.minY)
        #expect(rect.height == item.expected.height, "height \(rect.height) against \(item.expected.height)")
        #expect(abs(rect.width - item.expected.width) <= tolerance, "width \(rect.width) against \(item.expected.width)")
    }

    /// The ink UIKit draws (`StringDrawingParityTests.Ink`): box in pixels and total coverage.
    static let inks: [StringDrawingParityTests.Ink] = [
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "クロ1976", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, .left, box: [4, 6, 69, 20], ink: 105913),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "クロ1976", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 1.0, .center, box: [90, 8, 154, 22], ink: 105936),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "한국어 텍스트", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, .left, box: [4, 6, 86, 20], ink: 102868),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "한국어 텍스트", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 1.0, .center, box: [81, 8, 162, 22], ink: 102853),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "Level ไทย", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, .left, box: [4, 4, 75, 19], ink: 96212),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "Level ไทย", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 1.0, .center, box: [86, 6, 156, 21], ink: 96185),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "سلام عليكم", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, .left, box: [4, 8, 71, 24], ink: 56063),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "سلام عليكم", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 1.0, .center, box: [88, 10, 155, 26], ink: 55722),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "クロ1976", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, .left, box: [5, 8, 85, 26], ink: 114636),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "クロ1976", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 1.0, .center, box: [82, 10, 162, 28], ink: 114634),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "한국어 텍스트", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, .left, box: [4, 8, 112, 26], ink: 163796),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "한국어 텍스트", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 1.0, .center, box: [67, 10, 176, 28], ink: 163783),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "Level ไทย", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, .left, box: [5, 5, 88, 25], ink: 118106),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "Level ไทย", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 1.0, .center, box: [80, 7, 163, 27], ink: 118104),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "سلام عليكم", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, .left, box: [4, 10, 93, 32], ink: 99834),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "سلام عليكم", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 1.0, .center, box: [77, 12, 166, 34], ink: 99841),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "クロ1976", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, .left, box: [14, 17, 208, 59], ink: 940055),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "クロ1976", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 3.0, .center, box: [270, 22, 464, 64], ink: 940055),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "한국어 텍스트", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, .left, box: [13, 19, 258, 59], ink: 923563),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "한국어 텍스트", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 3.0, .center, box: [244, 24, 488, 64], ink: 923563),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "Level ไทย", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, .left, box: [14, 14, 225, 56], ink: 828804),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "Level ไทย", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 3.0, .center, box: [260, 19, 470, 61], ink: 828804),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "سلام عليكم", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, .left, box: [12, 23, 213, 73], ink: 507529),
        StringDrawingParityTests.Ink("Montserrat-Black", 15.0, "سلام عليكم", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 3.0, .center, box: [265, 28, 466, 78], ink: 507529),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "クロ1976", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, .left, box: [17, 24, 257, 77], ink: 1036335),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "クロ1976", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 3.0, .center, box: [248, 29, 487, 82], ink: 1036335),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "한국어 텍스트", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, .left, box: [13, 25, 339, 78], ink: 1474480),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "한국어 텍스트", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 3.0, .center, box: [203, 30, 528, 83], ink: 1474480),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "Level ไทย", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, .left, box: [15, 14, 264, 74], ink: 1070669),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "Level ไทย", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 3.0, .center, box: [241, 19, 490, 79], ink: 1070669),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "سلام عليكم", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, .left, box: [12, 30, 280, 96], ink: 901935),
        StringDrawingParityTests.Ink("KoHo-Bold", 20.0, "سلام عليكم", CGRect(x: 2.25, y: 5.1, width: 240.0, height: 60.0), scale: 3.0, .center, box: [232, 35, 500, 101], ink: 901935),
    ]

    @Test("Drawn fallback text lands where UIKit draws it", arguments: inks)
    func pixels(_ item: StringDrawingParityTests.Ink) throws {
        _ = Fonts.engine
        let context = BitmapContext(width: Int(250 * item.scale), height: Int(70 * item.scale), scale: item.scale)
        let block = try #require(TextBlock(runs: [TextBlock.Run(item.text, font: FontKey(name: item.font, size: item.size), colour: .white,
                                                                style: TextBlock.Style(alignment: item.alignment))],
                                           maxWidth: item.rect.width))
        block.draw(in: item.rect, context: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var box = [context.width, context.height, -1, -1], total = 0
        for y in 0 ..< context.height {
            for x in 0 ..< context.width where data[(y * context.width + x) * 4 + 3] > 0 {
                box = [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)]
                total += Int(data[(y * context.width + x) * 4 + 3])
            }
        }
        // The baseline's row is UIKit's exactly. The top row may be one
        // off at 1x, where a tall fallback glyph (Thonburi's ไ) reaches
        // a row by a sliver that CoreGraphics covers faintly and FreeType
        // doesn't; a column of faint coverage either side, likewise.
        #expect(box[3] == item.box[3] && abs(box[1] - item.box[1]) <= (item.scale == 1 ? 1 : 0), "rows \(box) against \(item.box)")
        #expect(abs(box[0] - item.box[0]) <= 1 && abs(box[2] - item.box[2]) <= 1, "columns \(box) against \(item.box)")
        #expect(abs(Double(total) / Double(item.ink) - 1) < 0.06, "ink \(total) against \(item.ink)")
    }
}
#endif
