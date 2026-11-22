// Labels centred by their font's metrics: every string in one font and size
// on the same baseline, whatever its letters. On the Mac host, where the
// shim's labels lay out as they do on Android, through a text provider
// that measures with CoreText, which the device's HarfBuzz and FreeType
// stack is held to (Text/, `CoreTextParityTests`), over the open-licensed
// fonts kept with those tests.
#if SPRITEKIT_SHIM && canImport(Darwin)
import CoreText
import Foundation
import SpriteKitShim
import Testing
@testable import PlatformSprite
import PlatformTestSupport

private final class CoreTextProvider: TextProvider, @unchecked Sendable {
    private func font(_ key: FontKey) -> CTFont { CTFontCreateWithName(key.name as CFString, key.size, nil) }

    func fontMetrics(_ key: FontKey) -> FontMetrics? {
        let font = font(key)
        return FontMetrics(
            ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font), leading: CTFontGetLeading(font),
            capHeight: CTFontGetCapHeight(font), xHeight: CTFontGetXHeight(font)
        )
    }

    func measure(_ text: String, font key: FontKey) -> TextLine {
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font(key)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return TextLine(text: text, advance: advance, inkBounds: CTLineGetBoundsWithOptions(line, .useGlyphPathBounds))
    }

    func breakLines(_ text: String, font: FontKey, maxWidth: CGFloat) -> [String] { [text] }
    func breakOffsets(in text: String) -> [Int] { [0] }
}

private enum Fixture {
    static let latin = "Montserrat-Bold"
    /// Latin and Thai in one face.
    static let thai = "KoHo-Bold"
    static let size: CGFloat = 40
    static let samples = ["MAP", "Quiz", "quiz", "pqyg", "Ågé", "ภาษาไทย", "ที่ญี่ปุ่น"]

    /// Registers the fonts and installs the provider, once.
    static let installed: Bool = {
        let fonts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Text/Tests/Fixtures/Fonts")
        for file in ["Montserrat.ttf", "KoHo-Bold.ttf"] {
            CTFontManagerRegisterFontsForURL(fonts.appendingPathComponent(file) as CFURL, .process, nil)
        }
        if TextMetrics.provider == nil { TextMetrics.provider = CoreTextProvider() }
        return CTFontCopyPostScriptName(CTFontCreateWithName(thai as CFString, size, nil)) as String == thai
    }()

    static func metrics(_ name: String) -> FontBandMetrics { FontBandMetrics(fontNamed: name, size: size) }
}

private func label(_ text: String, font: String) -> SKLabelNode {
    let label = SKLabelNode(fontNamed: font)
    label.fontSize = Fixture.size
    label.text = text
    return label
}

/// Where the label's first line draws its baseline, in its parent.
private func drawnBaseline(_ label: SKLabelNode) -> CGFloat? {
    if let aligned = label as? AlignedLabelNode {
        return drawnBaseline(aligned.textNode).map { label.position.y + $0 * label.yScale }
    }
    return label.layout.flatMap { $0.lines.first }.map { label.position.y + $0.origin.y }
}

private func spread(_ values: [CGFloat]) -> CGFloat { (values.max() ?? 0) - (values.min() ?? 0) }

struct TextBandTests {
    @Test func spriteKitCentringMovesWithTheLetters() throws {
        try #require(Fixture.installed)
        for font in [Fixture.latin, Fixture.thai] {
            let baselines = try Fixture.samples.map { text in
                let centred = label(text, font: font)
                centred.verticalAlignmentMode = .center
                return try #require(drawnBaseline(centred))
            }
            // What the bug looked like: several points apart.
            #expect(spread(baselines) > 5, "\(font): \(baselines)")
        }
    }

    @Test func centredByMetricsEveryStringSharesOneBaseline() throws {
        try #require(Fixture.installed)
        let centre = pt(0, 100)
        for font in [Fixture.latin, Fixture.thai] {
            for band in [TextBand.capitals, .line] {
                let labels = Fixture.samples.map { label($0, font: font) }
                labels.forEach { $0.centerVertically(on: centre, band: band) }
                let baselines = try labels.map { try #require(drawnBaseline($0)) }
                #expect(spread(baselines) == 0, "\(font) \(band): \(baselines)")
                #expect(labels.allSatisfy { $0.verticalAlignmentMode == .baseline })
                // The node sits where the band's middle is on the centre.
                let metrics = Fixture.metrics(font)
                let span = band.span(ascender: metrics.ascender, descender: metrics.descender, capHeight: metrics.capHeight)
                #expect(abs(labels[0].position.y + (span.bottom + span.top) / 2 - centre.y) < 1e-9)
            }
        }
    }

    @Test func theBandsAreReadFromTheFont() {
        #expect(Fixture.installed)
        let metrics = Fixture.metrics(Fixture.thai)
        #expect(metrics.capHeight > 0 && metrics.ascender > metrics.capHeight && metrics.descender < 0)
        #expect(metrics.baseline(.center, at: 0, band: .capitals) == -metrics.capHeight / 2)
        #expect(metrics.baseline(.center, at: 0, band: .line) == -(metrics.ascender + metrics.descender) / 2)
        #expect(metrics.baseline(.top, at: 10, band: .line) == 10 - metrics.ascender)
        #expect(metrics.baseline(.top, at: 10, band: .capitals) == 10 - metrics.capHeight)
        #expect(metrics.baseline(.bottom, at: 10, band: .line) == 10 - metrics.descender)
        #expect(metrics.baseline(.bottom, at: 10, band: .capitals) == 10)
        #expect(metrics.baseline(.baseline, at: 10, band: .line) == 10)
    }

    @Test func thaiInkCentresOnTheLineBand() throws {
        try #require(Fixture.installed)
        // A typical Thai line, marks above and below: its ink's middle is
        // within a point of the line band's, where the capitals band would
        // sit it lower.
        let metrics = Fixture.metrics(Fixture.thai)
        let provider = try #require(TextMetrics.provider)
        let ink = provider.measure("ภาษาไทยที่สุด", font: FontKey(name: Fixture.thai, size: Fixture.size)).inkBounds
        #expect(abs(ink.midY - (metrics.ascender + metrics.descender) / 2) < 1)
    }

    @Test func languagesPickTheirBand() {
        #expect(TextBand.forLanguage("th") == .line)
        #expect(TextBand.forLanguage("th-TH") == .line)
        #expect(TextBand.forLanguage("lo") == .line)
        #expect(TextBand.forLanguage("en") == .capitals)
        #expect(TextBand.forLanguage("pt-BR") == .capitals)
        #expect(TextBand.forLanguage("zh_Hans") == .capitals)
        #expect(Typography.textBand() == .capitals)
    }

    @Test func builderAlignsByTheBand() throws {
        try #require(Fixture.installed)
        let modes: [SKLabelVerticalAlignmentMode] = [.center, .top, .bottom]
        for mode in modes {
            let labels = Fixture.samples.map {
                PlatformSprite.label(.fontNamed(Fixture.thai, Fixture.size), .vAlign(mode), .text($0), .position(5, 50), .band(.line))
            }
            let baselines = try labels.map { try #require(drawnBaseline($0)) }
            #expect(spread(baselines) == 0, "\(mode): \(baselines)")
            #expect(labels[0].verticalAlignmentMode == mode && labels[0].position == pt(5, 50))
            // Drawn where a baseline label put at the band's baseline draws.
            let placed = label(Fixture.samples[0], font: Fixture.thai)
            placed.position = pt(5, Fixture.metrics(Fixture.thai).baseline(mode, at: 50, band: .line))
            #expect(near(try #require(drawnBaseline(labels[0])), try #require(drawnBaseline(placed))))
        }
        // A baseline label is left where it's put.
        let plain = PlatformSprite.label(.fontNamed(Fixture.thai, Fixture.size), .text("pq"), .position(5, 50))
        #expect(plain.position == pt(5, 50) && plain.verticalAlignmentMode == .baseline)
    }

    @Test func textBlockLinesSitOnEvenlySpacedBaselines() throws {
        try #require(Fixture.installed)
        let metrics = Fixture.metrics(Fixture.latin)
        let advance: CGFloat = 48, spacing: CGFloat = 6
        let bandMiddle = -metrics.baseline(.center, at: 0, band: .capitals)
        let texts = ["MAP", "pqyg", "Quiz", "quiz", "ÅÉ"]
        let hanging = textBlockBaselines(count: texts.count, advance: advance, lineSpacing: spacing, bandMiddle: bandMiddle)
        let labels = zip(texts, hanging).map { text, baseline in
            let line = label(text, font: Fixture.latin)
            line.position = pt(0, baseline)
            return line
        }
        let drawn = try labels.map { try #require(drawnBaseline($0)) }
        let steps = zip(drawn, drawn.dropFirst()).map { $0 - $1 }
        #expect(steps.allSatisfy { abs($0 - advance) < 1e-9 }, "\(drawn)")
        // The first line's capitals centred in its height below the top.
        #expect(abs(hanging[0] + bandMiddle - (-(advance - spacing) / 2)) < 1e-9)

        let fromBaseline = textBlockBaselines(count: 3, advance: advance, lineSpacing: spacing, bandMiddle: nil)
        #expect(fromBaseline == [0, -48, -96])
    }
}
#endif
