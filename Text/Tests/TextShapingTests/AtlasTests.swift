import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

@Suite("Glyph atlas")
struct AtlasTests {
    private func fresh() -> (GlyphAtlas, TextEngine) {
        let atlas = GlyphAtlas(pageSize: 256, library: Fonts.engine.library)
        return (atlas, TextEngine(library: Fonts.engine.library, atlas: atlas))
    }

    @Test("Asking twice gives back the same rect, and rasterises once")
    func stableRects() throws {
        let (atlas, _) = fresh()
        let font = Fonts.chiron(24)
        let glyphs = (Fonts.engine.shape("Salamanders", font: font) ?? []).flatMap(\.glyphs)
        let key = GlyphAtlas.Key(font: font.name, size: font.size, glyph: glyphs[0].glyph)

        let first = try #require(atlas.glyph(key, font: font))
        let count = atlas.count
        let again = try #require(atlas.glyph(key, font: font))

        #expect(first == again)
        #expect(atlas.count == count)
        #expect(first.size.width > 0)
        #expect(first.size.height > 0)
    }

    @Test("Each glyph gets its own rect, and none overlap")
    func packing() {
        let (atlas, _) = fresh()
        let font = Fonts.chiron(18)
        let glyphs = (Fonts.engine.shape("ABCDEFGHIJKLMNOPQRSTUVWXYZ", font: font) ?? []).flatMap(\.glyphs)
        let entries = glyphs.compactMap {
            atlas.glyph(GlyphAtlas.Key(font: font.name, size: font.size, glyph: $0.glyph), font: font)
        }

        #expect(entries.count == 26)
        for (i, a) in entries.enumerated() {
            for b in entries[(i + 1)...] where a.page == b.page {
                #expect(!a.rect.intersects(b.rect))
            }
        }
    }

    @Test("The same glyph at two sizes is two entries")
    func keyedBySize() throws {
        let (atlas, _) = fresh()
        let small = Fonts.chiron(16)
        let large = Fonts.chiron(48)
        let glyph = try #require((Fonts.engine.shape("S", font: small) ?? []).first?.glyphs.first?.glyph)

        let a = try #require(atlas.glyph(GlyphAtlas.Key(font: small.name, size: small.size, glyph: glyph), font: small))
        let b = try #require(atlas.glyph(GlyphAtlas.Key(font: large.name, size: large.size, glyph: glyph), font: large))

        #expect(a.rect != b.rect)
        #expect(b.size.height > a.size.height)
        #expect(atlas.count == 2)
    }

    @Test("A rasterised glyph has ink in it, and only inside its rect")
    func coverage() throws {
        let (atlas, _) = fresh()
        let font = Fonts.chiron(32)
        let glyph = try #require((Fonts.engine.shape("S", font: font) ?? []).first?.glyphs.first?.glyph)
        let entry = try #require(atlas.glyph(GlyphAtlas.Key(font: font.name, size: font.size, glyph: glyph), font: font))
        let page = atlas.pages[entry.page]

        var ink = 0
        for y in Int(entry.rect.minY)..<Int(entry.rect.maxY) {
            for x in Int(entry.rect.minX)..<Int(entry.rect.maxX) where page.pixels[y * page.width + x] > 0 {
                ink += 1
            }
        }
        #expect(ink > 0)

        // The padding ring round it stays clear, so bilinear sampling at the
        // edge cannot pull a neighbour in.
        let top = Int(entry.rect.minY) - 1
        if top >= 0 {
            for x in Int(entry.rect.minX)..<Int(entry.rect.maxX) {
                #expect(page.pixels[top * page.width + x] == 0)
            }
        }
    }

    @Test("A space is cached as a real entry with nothing to draw")
    func emptyGlyph() throws {
        let (atlas, _) = fresh()
        let font = Fonts.chiron(24)
        let glyph = try #require((Fonts.engine.shape(" ", font: font) ?? []).first?.glyphs.first?.glyph)
        let entry = try #require(atlas.glyph(GlyphAtlas.Key(font: font.name, size: font.size, glyph: glyph), font: font))
        #expect(entry.isEmpty)
        #expect(entry.page == -1)
    }

    @Test("Pages fill up and the next one is started")
    func multiplePages() {
        let (atlas, _) = fresh()                    // 256 px pages
        let font = Fonts.chiron(48)
        let text = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let glyphs = (Fonts.engine.shape(text, font: font) ?? []).flatMap(\.glyphs)
        for glyph in glyphs {
            _ = atlas.glyph(GlyphAtlas.Key(font: font.name, size: font.size, glyph: glyph.glyph), font: font)
        }
        #expect(atlas.pages.count > 1)
        #expect(atlas.pages.allSatisfy { $0.width == 256 && $0.height == 256 })
    }

    @Test("A page reports what changed, so the renderer uploads a sub-rect")
    func dirtyRects() throws {
        let (atlas, _) = fresh()
        let font = Fonts.chiron(20)
        let glyph = try #require((Fonts.engine.shape("W", font: font) ?? []).first?.glyphs.first?.glyph)
        _ = atlas.glyph(GlyphAtlas.Key(font: font.name, size: font.size, glyph: glyph), font: font)

        let page = atlas.pages[0]
        #expect(page.dirty != nil)
        let generation = page.generation
        page.clearDirty()
        #expect(page.dirty == nil)
        #expect(page.generation == generation)
    }

    @Test("Shaping and rasterising together place every glyph on the line")
    func placed() {
        let (_, engine) = fresh()
        let font = Fonts.chiron(28)
        let placed = engine.placedGlyphs("Play", font: font)
        #expect(placed.count == 4)
        // Pens march left to right and the frames follow them.
        for (a, b) in zip(placed, placed.dropFirst()) {
            #expect(b.origin.x > a.origin.x)
        }
        #expect(placed.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
    }
}
