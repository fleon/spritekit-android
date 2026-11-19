#if canImport(SpriteKit) && os(macOS)
import CoreText
import Foundation
import SpriteKit
import CTextShaping
import SpriteKitShim
import Testing
@testable import TextShaping

/// Colour glyphs (emoji): laid out and drawn where Core Text puts Apple
/// Color Emoji (`EmojiMetrics`), their pixels from the face's own colour
/// data. The Mac's emoji face is Apple Color Emoji (sbix strikes), so the
/// lines, labels and drawn text here are checked against Apple's own.
@Suite("Colour glyphs as Core Text lays out and draws emoji")
struct ColourGlyphTests {
    static func appleEmoji(_ size: CGFloat) -> (advance: CGFloat, box: CGRect) {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, size, nil)
        var characters = Array("😀".utf16), glyphs = [CGGlyph](repeating: 0, count: 2)
        CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 2)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advance, 1)
        return (advance.width, CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, nil, 1))
    }

    @Test("The emoji box and advance are Core Text's at every size")
    func metrics() {
        var misses: [CGFloat] = []
        for size in stride(from: 6.0, through: 40.0, by: 0.01) as StrideThrough<CGFloat> {
            let apple = Self.appleEmoji(size)
            if EmojiMetrics.advance(size) != apple.advance { misses.append(size) }
            let box = EmojiMetrics.box(size)
            #expect(abs(box.width - apple.box.width) < 1e-5 && abs(box.height - apple.box.height) < 1e-5, "side at \(size)")
            #expect(abs(box.minY - apple.box.minY) < 1e-5, "bottom at \(size)")
            // The inset, or a tracking unit off it where the interpolated
            // tracking lands on a whole unit and the floor tips either way.
            let unit = 0.4 * EmojiMetrics.imageSize(size) / 800
            let dx = abs(box.minX - apple.box.minX)
            #expect(dx < 1e-5 || abs(dx - unit) < 1e-5, "left at \(size): \(box.minX) against \(apple.box.minX)")
        }
        // Every advance but a size or two landing exactly on a step, which
        // Core Text's own arithmetic tips either way (19 points is one).
        #expect(misses.count <= 2, "advances differ at \(misses)")
    }

    static let fonts: [(String, CGFloat)] = [("Montserrat-Black", 20), ("Montserrat-SemiBold", 15), ("KoHo-Bold", 13), ("Montserrat-Black", 31.5)]
    static let texts = ["😀a", "a😀b👍🏽", "Lv. 8 🐑", "👨‍👩‍👧", "🇯🇵 Japan", "❤️", "#️⃣1"]

    @Test("Lines with emoji: one glyph a sequence, at Core Text's widths")
    func lines() {
        for (name, size) in Self.fonts {
            let font = FontKey(name: name, size: size)
            for text in Self.texts {
                let width = CTLineGetTypographicBounds(FontFallbackTests.coreTextLine(text, name, size), nil, nil, nil)
                let tolerance = name == "Montserrat-SemiBold" ? 0.01 : 1e-4
                #expect(abs(Fonts.engine.measure(text, font: font).advance - width) <= tolerance, "\(name) \(size) '\(text)'")
            }
        }
        // A family, a flag and a toned thumb are each one emoji glyph.
        let runs = Fonts.engine.shape("👨‍👩‍👧🇯🇵👍🏽", font: Fonts.display(20)) ?? []
        #expect(runs.flatMap(\.glyphs).count == 3 && runs.allSatisfy { $0.font == "AppleColorEmoji" })
    }

    @Test("Label frames with emoji match SpriteKit's at every size from 6 to 40 points")
    @MainActor
    func labelSizes() {
        _ = CoreTextFallback.registered
        var misses: [String] = []
        for size in stride(from: 6.0, through: 40.0, by: 0.5) as StrideThrough<CGFloat> {
            for (name, text) in [("Montserrat-Black", "😀"), ("Montserrat-Black", "a😀"), ("KoHo-Bold", "Lv 😀👍🏽")] {
                let apple = SpriteKit.SKLabelNode(attributedText: NSAttributedString(string: text, attributes: [.font: NSFont(name: name, size: size)!]))
                let ours = SpriteKitShim.SKLabelNode(fontNamed: name)
                ours.fontSize = size
                ours.text = text
                if apple.frame != ours.contentFrame { misses.append("\(name) \(size) '\(text)': \(apple.frame) against \(ours.contentFrame)") }
            }
        }
        #expect(misses.isEmpty, "\(misses.count) frames differ: \(misses.prefix(12))")
    }

    @Test("Label frames with emoji match SpriteKit's")
    @MainActor
    func labels() {
        _ = CoreTextFallback.registered
        for (name, size) in Self.fonts {
            for text in Self.texts {
                let apple = SpriteKit.SKLabelNode(attributedText: NSAttributedString(string: text, attributes: [.font: NSFont(name: name, size: size)!]))
                let ours = SpriteKitShim.SKLabelNode(fontNamed: name)
                ours.fontSize = size
                ours.text = text
                #expect(apple.frame == ours.contentFrame, "\(name) \(size) '\(text)'")
            }
        }
    }

    @Test("Each kind of colour data gives an image: strikes (CBDT, sbix) and COLR layers")
    func kinds() throws {
        // The engine installs the PNG decoder strikes are decoded with.
        _ = Fonts.engine
        // ChromaCheck's test fonts: glyph 1 a square of one colour each.
        for (file, red) in [("chromacheck-cbdt", 100), ("chromacheck-colr", 200), ("chromacheck-sbix", 150)] {
            let face = try FaceHandle(file: FontFile(path: Fonts.directory + "/" + file + ".ttf"), size: 32, instance: nil)
            #expect(face.hasColourGlyphs, "\(file)")
            let image = try #require(face.colourImage(1, pixels: 16), "\(file)")
            #expect(image.width == 16 && image.height == 16)
            var sums = [0, 0, 0, 0]
            for at in stride(from: 0, to: image.pixels.count, by: 4) {
                for channel in 0 ..< 4 { sums[channel] += Int(image.pixels[at + channel]) }
            }
            #expect(sums.map { $0 / 256 } == [red, 0, 0, 255], "\(file): \(sums.map { $0 / 256 })")
            #expect(face.colourImage(0, pixels: 16) == nil, "\(file): .notdef has no colour")
        }
        let plain = try FaceHandle(file: FontFile(path: Fonts.directory + "/Montserrat.ttf"), size: 32, instance: nil)
        #expect(!plain.hasColourGlyphs)
    }

    @Test("A glyph the nearest strike leaves out comes from a larger one")
    func missingStrike() throws {
        _ = Fonts.engine
        // Apple Color Emoji's 20-pixel strike leaves out some glyphs its
        // larger strikes have (437 among them).
        let face = try FaceHandle(file: FontFile(path: "/System/Library/Fonts/Apple Color Emoji.ttc"), size: 16, instance: nil)
        let hbFace = try #require(face.exactFont.flatMap { hb_font_get_face($0) })
        func hasPNG(_ glyph: UInt32, ppem: UInt32) -> Bool {
            let font = hb_font_create(hbFace)!
            defer { hb_font_destroy(font) }
            hb_font_set_ppem(font, ppem, ppem)
            let blob = hb_ot_color_glyph_reference_png(font, glyph)!
            defer { hb_blob_destroy(blob) }
            return hb_blob_get_length(blob) > 0
        }
        let left = try #require((1 ..< 3000).lazy.map(UInt32.init).first { !hasPNG($0, ppem: 20) && hasPNG($0, ppem: 160) })
        let image = try #require(face.colourImage(left, pixels: 20), "glyph \(left)")
        #expect(image.width == 20 && stride(from: 3, to: image.pixels.count, by: 4).contains { image.pixels[$0] > 0 })
    }

    @Test("A colour glyph goes onto an RGBA page, once a size")
    func atlas() throws {
        _ = Fonts.engine
        let library = FontLibrary()
        let atlas = GlyphAtlas(pageSize: 256, library: library)
        let name = try #require(try library.register(path: Fonts.directory + "/chromacheck-colr.ttf").last)
        let font = FontKey(name: name, size: 32)
        let glyph = try #require(atlas.colourGlyph(1, font: font, pixels: 24))
        #expect(glyph.isColour && glyph.size == CGSize(width: 24, height: 24))
        #expect(atlas.colourGlyph(1, font: font, pixels: 24) == glyph, "the same rect asked twice")
        #expect(atlas.colourGlyph(1, font: font, pixels: 48) != glyph, "another size, another entry")
        let page = try #require(atlas.colourPages.first)
        #expect(page.bytesPerPixel == 4 && atlas.pages.isEmpty, "colour pages only")
        let at = (Int(glyph.rect.minY) * page.width + Int(glyph.rect.minX)) * 4
        #expect(Array(page.pixels[at ..< at + 4]) == [200, 0, 0, 255])
    }

    /// UIKit's `boundingRect` with emoji, measured on Catalyst (macOS
    /// 27.2): a line keeps its font's height, and an emoji is as wide as
    /// Core Text spaces it.
    static let rects: [FallbackStringDrawingTests.Rect] = [
        FallbackStringDrawingTests.Rect("Montserrat-Black", 15.0, "😀", .left, x: 0.0, y: 0.0, w: 20.0, h: 19.0),
        FallbackStringDrawingTests.Rect("Montserrat-Black", 15.0, "a😀b", .left, x: 0.0, y: 0.0, w: 40.085, h: 19.0),
        FallbackStringDrawingTests.Rect("Montserrat-Black", 15.0, "Lv. 8 🐑", .left, x: 0.0, y: 0.0, w: 61.66999999999999, h: 19.0),
        FallbackStringDrawingTests.Rect("Montserrat-Black", 15.0, "👨‍👩‍👧 family and 🇯🇵 flags wrap 😀😀😀", .left, x: 0.0, y: 0.0, w: 150.285, h: 38.0),
        FallbackStringDrawingTests.Rect("KoHo-Bold", 20.0, "😀", .left, x: 0.0, y: 0.0, w: 23.0, h: 26.0),
        FallbackStringDrawingTests.Rect("KoHo-Bold", 20.0, "a😀b", .left, x: 0.0, y: 0.0, w: 45.480000000000004, h: 26.0),
        FallbackStringDrawingTests.Rect("KoHo-Bold", 20.0, "Lv. 8 🐑", .left, x: 0.0, y: 0.0, w: 70.34, h: 26.0),
        FallbackStringDrawingTests.Rect("KoHo-Bold", 20.0, "👨‍👩‍👧 family and 🇯🇵 flags wrap 😀😀😀", .left, x: 0.0, y: 0.0, w: 157.12, h: 78.0),
        FallbackStringDrawingTests.Rect("Montserrat-SemiBold", 13.0, "😀", .left, x: 0.0, y: 0.0, w: 17.0, h: 16.0),
        FallbackStringDrawingTests.Rect("Montserrat-SemiBold", 13.0, "a😀b", .left, x: 0.0, y: 0.0, w: 33.80709353999566, h: 16.0),
        FallbackStringDrawingTests.Rect("Montserrat-SemiBold", 13.0, "Lv. 8 🐑", .left, x: 0.0, y: 0.0, w: 50.19374476683332, h: 16.0),
        FallbackStringDrawingTests.Rect("Montserrat-SemiBold", 13.0, "👨‍👩‍👧 family and 🇯🇵 flags wrap 😀😀😀", .left, x: 0.0, y: 0.0, w: 151.1435783000232, h: 32.0),
    ]

    @Test("Bounding rects with emoji match UIKit's", arguments: rects)
    func boundingRect(_ item: FallbackStringDrawingTests.Rect) {
        FallbackStringDrawingTests().boundingRect(item)
    }

    struct Emoji: CustomTestStringConvertible {
        var font: String, size: CGFloat, text: String, rect: CGRect, scale: CGFloat, box: [Int], ink: Int, colour: Int
        init(_ font: String, _ size: CGFloat, _ text: String, _ rect: CGRect, scale: CGFloat, box: [Int], ink: Int, colour: Int) {
            self.font = font; self.size = size; self.text = text; self.rect = rect; self.scale = scale
            self.box = box; self.ink = ink; self.colour = colour
        }
        var testDescription: String { "\(font) \(size) '\(text)' at \(scale)x" }
    }

    /// UIKit's `draw(in:)` of white text with emoji on Catalyst: the ink's
    /// box in pixels, its total coverage, and how many pixels are coloured
    /// (red and blue apart by more than 40).
    static let inks: [Emoji] = [
        Emoji("Montserrat-Black", 15.0, "😀", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, box: [4, 3, 23, 22], ink: 59495, colour: 242),
        Emoji("Montserrat-Black", 15.0, "a😀b", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, box: [4, 3, 43, 22], ink: 94440, colour: 242),
        Emoji("Montserrat-Black", 15.0, "Lv. 8 🐑", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, box: [4, 3, 65, 22], ink: 97156, colour: 0),
        Emoji("KoHo-Bold", 20.0, "😀", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, box: [4, 6, 26, 28], ink: 79024, colour: 319),
        Emoji("KoHo-Bold", 20.0, "a😀b", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, box: [4, 6, 48, 28], ink: 112377, colour: 319),
        Emoji("KoHo-Bold", 20.0, "Lv. 8 🐑", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, box: [5, 7, 74, 28], ink: 110267, colour: 0),
        Emoji("Montserrat-Black", 31.5, "😀", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, box: [5, 6, 35, 36], ink: 169768, colour: 659),
        Emoji("Montserrat-Black", 31.5, "a😀b", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, box: [4, 6, 77, 36], ink: 316172, colour: 659),
        Emoji("Montserrat-Black", 31.5, "Lv. 8 🐑", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 1.0, box: [5, 7, 124, 36], ink: 345532, colour: 0),
        Emoji("Montserrat-Black", 15.0, "😀", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, box: [14, 10, 69, 66], ink: 516845, colour: 1941),
        Emoji("Montserrat-Black", 15.0, "a😀b", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, box: [13, 10, 131, 66], ink: 816532, colour: 1941),
        Emoji("Montserrat-Black", 15.0, "Lv. 8 🐑", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, box: [14, 14, 194, 66], ink: 839063, colour: 0),
        Emoji("KoHo-Bold", 20.0, "😀", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, box: [13, 18, 79, 84], ink: 714668, colour: 2652),
        Emoji("KoHo-Bold", 20.0, "a😀b", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, box: [14, 18, 146, 84], ink: 1017758, colour: 2652),
        Emoji("KoHo-Bold", 20.0, "Lv. 8 🐑", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, box: [15, 23, 221, 83], ink: 1002298, colour: 2),
        Emoji("Montserrat-Black", 31.5, "😀", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, box: [12, 17, 107, 112], ink: 1495161, colour: 5494),
        Emoji("Montserrat-Black", 31.5, "a😀b", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, box: [14, 17, 233, 112], ink: 2816203, colour: 5494),
        Emoji("Montserrat-Black", 31.5, "Lv. 8 🐑", CGRect(x: 4.3, y: 3.6, width: 240.0, height: 60.0), scale: 3.0, box: [17, 22, 370, 111], ink: 3086635, colour: 0),
    ]

    @Test("Drawn emoji land where UIKit draws them, in their own colours", arguments: inks)
    func pixels(_ item: Emoji) throws {
        _ = Fonts.engine
        let context = BitmapContext(width: Int(250 * item.scale), height: Int(70 * item.scale), scale: item.scale)
        let block = try #require(TextBlock(runs: [TextBlock.Run(item.text, font: FontKey(name: item.font, size: item.size), colour: .white)],
                                           maxWidth: item.rect.width))
        block.draw(in: item.rect, context: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var box = [context.width, context.height, -1, -1], total = 0, colour = 0
        for y in 0 ..< context.height {
            for x in 0 ..< context.width where data[(y * context.width + x) * 4 + 3] > 0 {
                let at = (y * context.width + x) * 4
                box = [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)]
                total += Int(data[at + 3])
                if abs(Int(data[at]) - Int(data[at + 2])) > 40 { colour += 1 }
            }
        }
        // The baseline's row is UIKit's. The image snaps to whole pixels,
        // where Core Graphics draws it at its fractional place and smears
        // its faint edges a pixel further (two across, at 1x, for the
        // sheep's pale wool): a pixel either side, two across at 1x.
        let across = item.scale == 1 ? 2 : 1
        #expect(abs(box[3] - item.box[3]) <= 1 && abs(box[1] - item.box[1]) <= 1, "rows \(box) against \(item.box)")
        #expect(abs(box[0] - item.box[0]) <= across && abs(box[2] - item.box[2]) <= across, "columns \(box) against \(item.box)")
        #expect(abs(Double(total) / Double(item.ink) - 1) < 0.06, "ink \(total) against \(item.ink)")
        #expect(abs(colour - item.colour) <= max(4, item.colour / 10), "coloured pixels \(colour) against \(item.colour)")
    }

    @Test("Emoji keep their colours whatever the text's colour and its alpha, unless it's clear")
    func untinted() throws {
        _ = Fonts.engine
        func draw(_ colour: SpriteKitShim.SKColor) throws -> [UInt8] {
            let context = BitmapContext(width: 40, height: 40, scale: 1)
            let block = try #require(TextBlock(runs: [TextBlock.Run("😀", font: Fonts.display(20), colour: colour)], maxWidth: 40))
            block.draw(in: CGRect(x: 2, y: 2, width: 36, height: 36), context: context)
            return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: 40 * 40 * 4))
        }
        // As UIKit draws them (red at half alpha is pixel for pixel white).
        let white = try draw(.white), black = try draw(.black), faint = try draw(SpriteKitShim.SKColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        #expect(white == black && white == faint)
        let clear = try draw(SpriteKitShim.SKColor(white: 1, alpha: 0))
        #expect(clear.allSatisfy { $0 == 0 })
    }
}
#endif

#if canImport(CoreText) && os(macOS)
@Suite("Colour pages as a cache") struct ColourPageEvictionTests {
    /// A tiny atlas: 32-pixel colour pages, one 24-pixel glyph each.
    static func atlas(limit: Int) throws -> (GlyphAtlas, FontKey) {
        _ = Fonts.engine
        let library = FontLibrary()
        let atlas = GlyphAtlas(pageSize: 64, colourPageSize: 32, library: library)
        atlas.colourPageLimit = limit
        let name = try #require(try library.register(path: Fonts.directory + "/chromacheck-colr.ttf").last)
        return (atlas, FontKey(name: name, size: 32))
    }

    @Test("Past the limit, the least recently drawn page is emptied for new glyphs")
    func evicts() throws {
        let (atlas, font) = try Self.atlas(limit: 2)
        let a = try #require(atlas.colourGlyph(1, font: font, pixels: 24))
        atlas.nextFrame()
        let b = try #require(atlas.colourGlyph(1, font: font, pixels: 25))
        atlas.nextFrame()
        // a drawn again: b is now the least recently drawn.
        _ = atlas.colourGlyph(1, font: font, pixels: 24)
        atlas.nextFrame()
        let epoch = atlas.colourEpoch
        let c = try #require(atlas.colourGlyph(1, font: font, pixels: 26))
        #expect(atlas.colourPages.count == 2, "no page past the limit")
        #expect(c.page == b.page && a.page != b.page, "b's page emptied for c")
        #expect(atlas.colourEpoch == epoch + 1)
        // a drawn this frame too, then b again: both pages are in use this
        // frame, so b goes onto a page past the limit.
        #expect(atlas.colourGlyph(1, font: font, pixels: 24) == a, "a kept its place")
        let again = try #require(atlas.colourGlyph(1, font: font, pixels: 25))
        #expect(atlas.colourPages.count == 3 && again.page == 2)
    }

    @Test("A page drawn from this frame is never emptied under it")
    func keepsCurrent() throws {
        let (atlas, font) = try Self.atlas(limit: 1)
        let a = try #require(atlas.colourGlyph(1, font: font, pixels: 24))
        let b = try #require(atlas.colourGlyph(1, font: font, pixels: 25))
        #expect(a.page != b.page && atlas.colourPages.count == 2, "a page past the limit rather than a's emptied")
        // Touched by a caller drawing what it looked up before.
        atlas.nextFrame()
        atlas.touchColourPages([a.page])
        let c = try #require(atlas.colourGlyph(1, font: font, pixels: 26))
        #expect(c.page == b.page, "the untouched page is the one emptied")
        #expect(atlas.colourGlyph(1, font: font, pixels: 24) == a)
    }
}
#endif
