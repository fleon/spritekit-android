import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// Android's fallback chain, read from its font configuration and chosen
/// from as Minikin chooses: the Mac's CJK faces stand in for the device's.
@Suite("Android's system fallback chain")
struct SystemFontFallbackTests {
    /// The shape of AOSP's fonts.xml: a named default family with its
    /// weights (a variable file set by axis), named families that aren't
    /// fallbacks, an alias, an elegant variant, a collection's faces by
    /// index, a face for the serif chain only, and comments.
    static let configuration = """
    <?xml version="1.0" encoding="utf-8"?>
    <familyset version="23">
        <!-- first font is default -->
        <family name="sans-serif">
            <font weight="400" style="normal">Roboto-Regular.ttf
              <axis tag="wdth" stylevalue="100" />
              <axis tag="wght" stylevalue="400" />
            </font>
            <font weight="700" style="normal">Roboto-Regular.ttf
              <axis tag="wght" stylevalue="700" />
            </font>
            <font weight="400" style="italic">Roboto-Italic.ttf</font>
        </family>
        <alias name="arial" to="sans-serif" />
        <family name="serif">
            <font weight="400" style="normal">NotoSerif-Regular.ttf</font>
        </family>
        <family lang="und-Thai" variant="elegant">
            <font weight="400" style="normal">NotoSerifThai-Regular.ttf</font>
        </family>
        <family lang="und-Thai" variant="compact">
            <font weight="400" style="normal">NotoSansThaiUI-Regular.ttf</font>
        </family>
        <family lang="zh-Hans">
            <font weight="400" style="normal" index="2" postScriptName="NotoSansCJKjp-Regular">NotoSansCJK-Regular.ttc</font>
            <font weight="400" style="normal" index="2" fallbackFor="serif"
              postScriptName="NotoSerifCJKjp-Regular">NotoSerifCJK-Regular.ttc</font>
        </family>
        <family lang="zh-Hant,zh-Bopo">
            <font weight="400" style="normal" index="3">NotoSansCJK-Regular.ttc</font>
        </family>
        <family lang="ja">
            <font weight="400" style="normal" index="0">NotoSansCJK-Regular.ttc</font>
        </family>
        <family lang="ko">
            <font weight="400" style="normal" index="1">NotoSansCJK-Regular.ttc</font>
        </family>
        <family lang="und-Zsye">
            <font weight="400" style="normal">NotoColorEmoji.ttf</font>
        </family>
    </familyset>
    """

    @Test("The chain is sans-serif, then the unnamed families in order, without the elegant variants")
    func parse() {
        let families = SystemFontFallback.parse(Self.configuration, directory: "/system/fonts")
        #expect(families.map(\.languages) == [[], ["und-Thai"], ["zh-Hans"], ["zh-Hant", "zh-Bopo"], ["ja"], ["ko"], ["und-Zsye"]])
        let roboto = families[0].fonts
        #expect(roboto.map(\.face.path) == ["/system/fonts/Roboto-Regular.ttf", "/system/fonts/Roboto-Regular.ttf", "/system/fonts/Roboto-Italic.ttf"])
        #expect(roboto.map(\.weight) == [400, 700, 400] && roboto.map(\.isItalic) == [false, false, true])
        #expect(roboto[0].face.variations == ["wdth": 100, "wght": 400] && roboto[1].face.variations == ["wght": 700])
        #expect(families[1].fonts[0].face.path == "/system/fonts/NotoSansThaiUI-Regular.ttf")
        #expect(families[2...5].map { $0.fonts[0].face.index } == [2, 3, 0, 1])
        #expect(families[2].fonts.map(\.face.path) == ["/system/fonts/NotoSansCJK-Regular.ttc"], "the serif chain's face left out")
    }

    @Test("A configuration without families gives no chain")
    func empty() {
        #expect(SystemFontFallback.parse("<familyset></familyset>", directory: "/system/fonts").isEmpty)
        #expect(SystemFontFallback.load(languages: [], configurations: ["/no/such/fonts.xml"]) == nil)
    }

    @Test("A user's language matches its own tag and narrower ones, Chinese regions by script")
    func languages() {
        #expect(SystemFontFallback.matches("ja-JP", "ja"))
        #expect(SystemFontFallback.matches("ja", "ja"))
        #expect(!SystemFontFallback.matches("jv", "ja"))
        #expect(SystemFontFallback.matches("zh-Hans-CN", "zh-Hans"))
        #expect(SystemFontFallback.matches("zh-CN", "zh-Hans"))
        #expect(SystemFontFallback.matches("zh_TW", "zh-Hant"))
        #expect(SystemFontFallback.matches("zh-HK", "zh-Hant"))
        #expect(!SystemFontFallback.matches("zh-TW", "zh-Hans"))
        #expect(!SystemFontFallback.matches("en-US", "und-Latn"))
    }

    // MARK: - Choosing, over the Mac's faces

    static let hiraginoGB = Font(face: FallbackFace(path: Fonts.hiragino))
    static let gothic = Font(face: FallbackFace(path: Fonts.appleSDGothic))
    static let gothicBold = Font(face: FallbackFace(path: Fonts.appleSDGothic, index: 6), weight: 700)
    typealias Font = SystemFontFallback.Font

    static func chain(languages: [String]) -> SystemFontFallback {
        SystemFontFallback(families: [
            .init(languages: [], fonts: [Font(face: FallbackFace(path: Fonts.directory + "/Montserrat.ttf"))]),
            .init(languages: ["zh-Hans"], fonts: [hiraginoGB]),
            .init(languages: ["ko"], fonts: [gothic, gothicBold]),
        ], languages: languages, library: Fonts.engine.library)
    }

    @Test("A character goes to the first family that has it", .enabled(if: Fonts.hasCJK))
    func firstCovering() {
        let fallback = Self.chain(languages: ["en-US"])
        let font = FontKey(name: "KoHo-Bold", size: 20)
        #expect(fallback.face(for: "é", font: font, weight: 400)?.path == Fonts.directory + "/Montserrat.ttf")
        #expect(fallback.face(for: "ク", font: font, weight: 400)?.path == Fonts.hiragino)
        #expect(fallback.face(for: "한", font: font, weight: 400)?.path == Fonts.appleSDGothic)
        #expect(fallback.face(for: "\u{E000}", font: font, weight: 400) == nil, "a private-use character nothing has")
        #expect(fallback.face(for: "\u{200D}", font: font, weight: 400) == nil, "a joiner draws nothing, so falls back nowhere")
    }

    @Test("A family for a language the user reads beats an earlier one", .enabled(if: Fonts.hasCJK))
    func languagePreferred() throws {
        // Both have Han; Korean readers get the Korean family's.
        let han: Character = "日"
        let font = FontKey(name: "KoHo-Bold", size: 20)
        let gothicHasHan = try #require(Fonts.engine.library.file(atPath: Fonts.appleSDGothic).flatMap {
            try? FaceHandle(file: $0, size: 16, instance: nil)
        }).covers("日")
        #expect(Self.chain(languages: ["en-US"]).face(for: han, font: font, weight: 400)?.path == Fonts.hiragino)
        if gothicHasHan {
            #expect(Self.chain(languages: ["ko-KR", "en-US"]).face(for: han, font: font, weight: 400)?.path == Fonts.appleSDGothic)
        }
    }

    @Test("Within a family, the font nearest the text's weight", .enabled(if: Fonts.hasCJK))
    func weight() {
        let fallback = Self.chain(languages: [])
        let font = FontKey(name: "Montserrat-Black", size: 20)
        #expect(fallback.face(for: "한", font: font, weight: 900)?.index == 6)
        #expect(fallback.face(for: "한", font: font, weight: 500)?.index == 0)
    }

    @Test("Lines fall back through the chain, at the fallback face's advances", .enabled(if: Fonts.hasCJK))
    func lines() throws {
        let library = FontLibrary()
        let engine = TextEngine(library: library, atlas: GlyphAtlas(library: library))
        _ = try library.register(path: Fonts.directory + "/KoHo-Bold.ttf")
        engine.fallback = SystemFontFallback(families: [
            .init(languages: ["zh-Hans"], fonts: [Self.hiraginoGB]),
            .init(languages: ["ko"], fonts: [Self.gothic]),
        ], languages: [], library: library)
        let font = FontKey(name: "KoHo-Bold", size: 20)
        let runs = try #require(engine.shape("ไทย クロ 한국", font: font))
        #expect(runs.map { $0.font ?? "-" } == ["-", "HiraginoSansGB-W3", "-", "AppleSDGothicNeo-Regular"])
        let kana = try #require(library.face(FontKey(name: "HiraginoSansGB-W3", size: 20))).shapeRuns("クロ")
        #expect(runs[1].glyphs.map(\.glyph) == kana.flatMap { $0.glyphs.map(\.glyph) })
        #expect(abs(runs[1].advance - kana.reduce(0) { $0 + $1.advance }) < 1e-9)
        // Drawable: the fallback glyphs rasterise from their own face.
        let placed = engine.placedGlyphs("クロ", font: font)
        #expect(placed.count == 2 && placed.allSatisfy { !$0.atlas.isEmpty })
    }
}
