import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

@Suite("Metrics")
struct MetricsTests {
    @Test("A face reports real vertical metrics")
    func metrics() throws {
        let metrics = try #require(Fonts.engine.fontMetrics(Fonts.chiron(32)))
        #expect(metrics.ascent > 0)
        #expect(metrics.descent > 0)
        #expect(metrics.lineHeight >= metrics.ascent + metrics.descent)
        #expect(metrics.lineHeight > 32 * 0.9)
        #expect(metrics.capHeight > 0)
        #expect(metrics.capHeight <= metrics.ascent)
        #expect(metrics.xHeight > 0)
        #expect(metrics.xHeight < metrics.capHeight)
    }

    @Test("Metrics scale with the point size")
    func scaling() throws {
        let small = try #require(Fonts.engine.fontMetrics(Fonts.chiron(20)))
        let large = try #require(Fonts.engine.fontMetrics(Fonts.chiron(40)))
        // FreeType grid-fits a face's global metrics to whole pixels, so
        // doubling the size doubles them to within a few per cent rather
        // than exactly.
        #expect(abs(large.ascent - small.ascent * 2) / large.ascent < 0.05)
        #expect(abs(large.lineHeight - small.lineHeight * 2) / large.lineHeight < 0.05)
    }

    @Test("Measurement is stable across repeated calls")
    func stability() {
        let font = Fonts.chiron(26.5)
        let first = Fonts.engine.measure("Stump your friends", font: font)
        Fonts.engine.flush()
        let afterFlush = Fonts.engine.measure("Stump your friends", font: font)
        let cached = Fonts.engine.measure("Stump your friends", font: font)

        #expect(first == afterFlush)
        #expect(first == cached)
        #expect(first.advance > 0)
        #expect(first.inkBounds.height > 0)
    }

    @Test("A fractional size is honoured, not rounded to whole points")
    func fractionalSize() {
        let narrow = Fonts.engine.measure("Salamanders", font: Fonts.chiron(20))
        let wide = Fonts.engine.measure("Salamanders", font: Fonts.chiron(20.5))
        #expect(wide.advance > narrow.advance)
    }

    @Test("The named instances of the variable font really differ")
    func namedInstances() {
        // A game may ask a variable font for weights by name, and they are
        // instances of one variable file rather than three faces. If the
        // axis were never set they would all measure the same.
        let text = "Salamanders"
        let black = Fonts.engine.measure(text, font: FontKey(name: "ChironGoRoundTC-Black", size: 32))
        let semibold = Fonts.engine.measure(text, font: FontKey(name: "ChironGoRoundTC-SemiBold", size: 32))
        let light = Fonts.engine.measure(text, font: FontKey(name: "ChironGoRoundTC-Light", size: 32))

        #expect(black.advance > semibold.advance)
        #expect(semibold.advance > light.advance)
    }

    @Test("Every name the fixtures ask for resolves")
    func registeredNames() {
        let names = Fonts.engine.library.registeredNames
        for wanted in [
            "ChironGoRoundTC-Black",       // .black
            "ChironGoRoundTC-ExtraBold",   // .heavy
            "ChironGoRoundTC-SemiBold",    // everything else
            "KoHo-Bold",                   // Thai
        ] {
            #expect(names.contains(wanted), "\(wanted) is not registered")
        }
    }

    @Test("Ink bounds sit around the baseline, not on it")
    func inkBounds() {
        let font = Fonts.chiron(40)
        let caps = Fonts.engine.measure("HELLO", font: font).inkBounds
        let descending = Fonts.engine.measure("gpqy", font: font).inkBounds

        #expect(caps.minY >= -0.5)              // capitals sit on the baseline
        #expect(caps.maxY > 0)
        #expect(descending.minY < -1)           // descenders hang below it
        #expect(descending.maxY < caps.maxY)    // and none of these reaches cap height
    }

    @Test("A line of spaces has width but no ink")
    func spacesOnly() {
        let line = Fonts.engine.measure("   ", font: Fonts.chiron())
        #expect(line.advance > 0)
        #expect(line.inkBounds.height == 0)
    }
}
