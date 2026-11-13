import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// What the game actually asks of the layer: a label that knows how big it
/// is. Everything the rest of the UI positions — buttons sized to their
/// labels, `centerCapitals`, `TextBlockNode` — is built on this.
@Suite("Label layout")
struct LabelTests {
    private func label(_ text: String, size: CGFloat = 32) -> SKLabelNode {
        _ = Fonts.engine
        let node = SKLabelNode()
        node.fontName = "ChironGoRoundTC-Black"
        node.fontSize = size
        node.text = text
        return node
    }

    @Test("A label's frame is the ink of its text")
    func frameIsInk() {
        let node = label("Switchlings")
        let measured = Fonts.engine.measure("Switchlings", font: Fonts.chiron(32))

        #expect(node.contentFrame.width > 0)
        #expect(abs(node.contentFrame.width - measured.inkBounds.width) < 0.001)
        #expect(abs(node.contentFrame.height - measured.inkBounds.height) < 0.001)
    }

    @Test("An empty or unknown label has no frame at all")
    func nothingToMeasure() {
        #expect(label("").contentFrame == .zero)

        let unknown = label("Switchlings")
        unknown.fontName = "NoSuchFont"
        #expect(unknown.contentFrame == .zero)
    }

    @Test("Horizontal alignment moves the frame by the line's advance")
    func horizontal() {
        let advance = Fonts.engine.measure("Play", font: Fonts.chiron(32)).advance

        let left = label("Play"); left.horizontalAlignmentMode = .left
        let centre = label("Play"); centre.horizontalAlignmentMode = .center
        let right = label("Play"); right.horizontalAlignmentMode = .right

        #expect(left.contentFrame.minX >= 0)
        #expect(right.contentFrame.maxX <= 0.001)
        #expect(abs(left.contentFrame.minX - (right.contentFrame.minX + advance)) < 0.001)
        #expect(abs(centre.contentFrame.minX - (left.contentFrame.minX - advance / 2)) < 0.001)
    }

    @Test("Vertical alignment works on the ink, as SpriteKit's does")
    func vertical() {
        // The game leans on this: `.center` centres the glyphs drawn, which
        // is why TextHelpers has to correct for it to line capitals up.
        let baseline = label("gpqy"); baseline.verticalAlignmentMode = .baseline
        let centre = label("gpqy"); centre.verticalAlignmentMode = .center
        let top = label("gpqy"); top.verticalAlignmentMode = .top
        let bottom = label("gpqy"); bottom.verticalAlignmentMode = .bottom

        #expect(baseline.contentFrame.minY < 0)          // descenders below the origin
        #expect(abs(centre.contentFrame.midY) < 0.001)
        #expect(abs(top.contentFrame.maxY) < 0.001)
        #expect(abs(bottom.contentFrame.minY) < 0.001)
        #expect(abs(centre.contentFrame.height - baseline.contentFrame.height) < 0.001)
    }

    @Test("A descender lifts a centred label's capitals, which is what the game corrects for")
    func inkCentring() {
        let caps = label("HELLO"); caps.verticalAlignmentMode = .center
        let hanging = label("HELLOg"); hanging.verticalAlignmentMode = .center

        // Both are centred on their own ink. The one with a descender has a
        // taller box hanging below the baseline, so centring it pushes its
        // capitals up — exactly the drift `TextHelpers.capitalsOffset`
        // exists to undo on buttons, and it only has to exist because
        // SpriteKit centres ink rather than the typographic box.
        #expect(hanging.contentFrame.maxY > caps.contentFrame.maxY)
        #expect(hanging.contentFrame.minY < caps.contentFrame.minY)
    }

    @Test("numberOfLines of 1 keeps one line whatever the text holds")
    func singleLine() {
        let node = label("Bump\nand trade")
        node.numberOfLines = 1
        let layout = node.layout
        #expect(layout?.lines.count == 1)
        #expect(layout?.lines.first?.line.text == "Bump and trade")
    }

    @Test("Newlines break lines once more than one is allowed")
    func explicitBreaks() throws {
        let node = label("Bump\nand\ntrade", size: 20)
        node.numberOfLines = 0
        let layout = try #require(node.layout)
        #expect(layout.lines.map(\.line.text) == ["Bump", "and", "trade"])
    }

    @Test("Lines stack by the font's line height")
    func lineStacking() throws {
        let node = label("Bump\nand\ntrade", size: 20)
        node.numberOfLines = 0
        node.verticalAlignmentMode = .baseline
        let layout = try #require(node.layout)
        let lineHeight = try #require(Fonts.engine.fontMetrics(Fonts.chiron(20))).lineHeight

        #expect(layout.lines[0].origin.y == 0)
        #expect(abs(layout.lines[1].origin.y + lineHeight) < 0.001)
        #expect(abs(layout.lines[2].origin.y + lineHeight * 2) < 0.001)
        #expect(node.contentFrame.height > lineHeight * 2)
    }

    @Test("preferredMaxLayoutWidth wraps, and nothing comes out wider")
    func wrapping() throws {
        let text = "Tap a Switchling to send it one step, and bump another to trade arrows"
        let node = label(text, size: 18)
        node.numberOfLines = 0
        node.preferredMaxLayoutWidth = 180

        let layout = try #require(node.layout)
        #expect(layout.lines.count > 3)
        for placed in layout.lines {
            #expect(placed.line.advance <= 180.001, "'\(placed.line.text)' is \(placed.line.advance)")
        }
        // Nothing lost in the breaking.
        let rejoined = layout.lines.map(\.line.text).joined(separator: " ")
        #expect(rejoined == text)
    }

    @Test("numberOfLines caps how many lines a wrap produces")
    func lineLimit() throws {
        let text = "Tap a Switchling to send it one step, and bump another to trade arrows"
        let node = label(text, size: 18)
        node.numberOfLines = 2
        node.preferredMaxLayoutWidth = 180
        #expect(try #require(node.layout).lines.count == 2)
    }

    @Test("Layout is stable across repeated calls and reflects every change")
    func caching() throws {
        let node = label("Switchlings")
        let first = try #require(node.layout)
        #expect(node.layout == first)
        #expect(node.contentFrame == first.bounds)

        node.fontSize = 48
        let bigger = try #require(node.layout)
        #expect(bigger.bounds.width > first.bounds.width)

        node.fontSize = 32
        #expect(node.layout == first)
    }

    @Test("The draw list carries the layout, so the renderer never measures again")
    func drawList() throws {
        _ = Fonts.engine
        let scene = SKScene(size: CGSize(width: 400, height: 200))
        let node = label("Play")
        node.position = CGPoint(x: 200, y: 100)
        scene.addChild(node)

        let list = DrawList(scene: scene)
        let carried = list.commands.compactMap { command -> DrawList.Label? in
            if case .label(let label) = command { return label }
            return nil
        }
        let label = carried.first!
        #expect(label.text == "Play")
        #expect(label.layout == node.layout)
        #expect(label.layout?.lines.count == 1)
    }

    @Test("A Thai label measures its marks as the shaper placed them")
    func thaiLabel() {
        _ = Fonts.engine
        let node = SKLabelNode()
        node.fontName = "KoHo-Bold"
        node.fontSize = 28
        node.text = "\u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}"

        let naive = Fonts.naive(node.text!, font: Fonts.koHo(28)).advance
        #expect(node.contentFrame.width > 0)
        #expect(node.contentFrame.width < naive)
        // The upper vowels reach above the capitals.
        let plain = SKLabelNode()
        plain.fontName = "KoHo-Bold"
        plain.fontSize = 28
        plain.text = "\u{0E2A}\u{0E27}\u{0E2A}\u{0E14}"
        #expect(node.contentFrame.maxY > plain.contentFrame.maxY)
    }
}

@Suite("UIFont")
struct FontMetricsTests {
    /// `UIFont` here is the Android stand-in, and on a Mac the real UIKit one
    /// is used instead, so what can be checked on the host is that the
    /// numbers it forwards are the ones the provider reports — in the same
    /// sign convention UIKit uses.
    @Test("Forwarded metrics follow UIKit's conventions")
    func conventions() throws {
        let metrics = try #require(Fonts.engine.fontMetrics(Fonts.chiron(30)))
        #expect(metrics.lineHeight == metrics.ascent + metrics.descent + metrics.leading)
        #expect(metrics.ascent > 0)
        // UIFont.descender is the negative of this, which the shim flips.
        #expect(metrics.descent > 0)
    }
}
