import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// What a game actually asks of the layer: a label that knows how big it
/// is. Everything the rest of the UI positions — buttons sized to their
/// labels, `centerCapitals`, `TextBlockNode` — is built on this.
// Nodes are main-actor, as SpriteKit's are (#406), so building a draw list is too.
@Suite("Label layout")
@MainActor
struct LabelTests {
    private func label(_ text: String, size: CGFloat = 32) -> SKLabelNode {
        _ = Fonts.engine
        let node = SKLabelNode()
        node.fontName = "Montserrat-Black"
        node.fontSize = size
        node.text = text
        return node
    }

    @Test("A label's frame is its ink rounded out to whole points, a point to spare all round")
    func frameIsInkRoundedOut() {
        let node = label("Lightning")
        let ink = Fonts.engine.measure("Lightning", font: Fonts.display(32)).inkBounds

        #expect(node.contentFrame.width == ink.maxX.rounded(.up) - ink.minX.rounded(.down) + 2)
        #expect(node.contentFrame.height == ink.maxY.rounded(.up) - ink.minY.rounded(.down) + 2)
        #expect(node.contentFrame.width > ink.width + 2)
    }

    @Test("The ink is drawn a point inside the frame, as SpriteKit draws it")
    func inkInsideFrame() throws {
        for mode in [SKLabelHorizontalAlignmentMode.left, .center, .right] {
            let node = label("(Español)"); node.horizontalAlignmentMode = mode
            let layout = try #require(node.layout)
            let ink = layout.lines[0].line.inkBounds.offsetBy(dx: layout.lines[0].origin.x, dy: layout.lines[0].origin.y)
            let frame = node.contentFrame
            #expect(abs(ink.minX - (frame.minX + 1 + ink.minX - ink.minX.rounded(.down))) < 0.001)
            #expect(ink.maxX <= frame.maxX - 1 + 0.001)
            #expect(ink.minY >= frame.minY + 1 - 0.001)
            #expect(ink.maxY <= frame.maxY - 1 + 0.001)
        }
    }

    @Test("An empty label frames its padding alone, and an unknown face nothing at all")
    func nothingToMeasure() {
        // SpriteKit frames an empty label 2 × 2.
        #expect(label("").contentFrame.size == CGSize(width: 2, height: 2))

        let unknown = label("Lightning")
        unknown.fontName = "NoSuchFont"
        #expect(unknown.contentFrame == .zero)
    }

    @Test("Horizontal alignment places the frame: its left edge, middle or right edge on the origin")
    func horizontal() {
        let left = label("Play"); left.horizontalAlignmentMode = .left
        let centre = label("Play"); centre.horizontalAlignmentMode = .center
        let right = label("Play"); right.horizontalAlignmentMode = .right
        let width = left.contentFrame.width

        #expect(left.contentFrame.minX == 0)
        #expect(right.contentFrame.maxX == 0)
        #expect(centre.contentFrame.minX == -(width / 2).rounded(.down))
        #expect(centre.contentFrame.width == width && right.contentFrame.width == width)
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
        #expect(centre.contentFrame.minY == -(centre.contentFrame.height / 2).rounded(.down))
        #expect(abs(top.contentFrame.maxY) < 0.001)
        #expect(abs(bottom.contentFrame.minY) < 0.001)
        #expect(abs(centre.contentFrame.height - baseline.contentFrame.height) < 0.001)
    }

    @Test("A descender lifts a centred label's capitals, which is what a game corrects for")
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

    @Test("Lines stack by the font's ascent, descent and leading, each rounded, as SpriteKit's do")
    func lineStacking() throws {
        let node = label("Bump\nand\ntrade", size: 20)
        node.numberOfLines = 0
        node.verticalAlignmentMode = .baseline
        let layout = try #require(node.layout)
        let metrics = try #require(Fonts.engine.fontMetrics(Fonts.display(20)))
        let lineHeight = metrics.ascent.rounded() + metrics.descent.rounded() + metrics.leading.rounded()

        let first = layout.lines[0].origin.y
        #expect(abs(layout.lines[1].origin.y - (first - lineHeight)) < 0.001)
        #expect(abs(layout.lines[2].origin.y - (first - lineHeight * 2)) < 0.001)
        #expect(node.contentFrame.height > lineHeight * 2)
    }

    @Test("preferredMaxLayoutWidth wraps, and nothing comes out wider")
    func wrapping() throws {
        let text = "Tap a tile to send it one step, and bump another to trade places"
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

    @Test("numberOfLines caps a wrap at one line more, as SpriteKit does, and never the text's own lines")
    func lineLimit() throws {
        let text = "Tap a tile to send it one step, and bump another to trade places"
        let node = label(text, size: 18)
        node.numberOfLines = 2
        node.preferredMaxLayoutWidth = 180
        #expect(try #require(node.layout).lines.count == 3)

        let own = label("A\nB\nC\nD", size: 18)
        own.numberOfLines = 2
        #expect(try #require(own.layout).lines.count == 4)
    }

    @Test("Layout is stable across repeated calls and reflects every change")
    func caching() throws {
        let node = label("Lightning")
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
    @MainActor func drawList() throws {
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
        let metrics = try #require(Fonts.engine.fontMetrics(Fonts.display(30)))
        #expect(metrics.lineHeight == metrics.ascent + metrics.descent + metrics.leading)
        #expect(metrics.ascent > 0)
        // UIFont.descender is the negative of this, which the shim flips.
        #expect(metrics.descent > 0)
    }
}
