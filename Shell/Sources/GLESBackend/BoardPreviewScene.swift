import Foundation
import GLESRenderer
import SpriteKitShim
import ShellCore

/// Stage 1's visual bar: real packed art, drawn on Android through the whole
/// layer — scene graph, actions, batching, the translated default shader and
/// the projection.
///
/// Deliberately *not* the game's `BoardNode`. That needs `Timeline`, the rig
/// runtime, world lighting and the live backdrops, which are stage 2 onward.
/// This lays out the same board art by hand so the pipeline can be proved
/// before any of that exists, and so a wrong atlas rect or a flipped UV is
/// obvious at a glance rather than hidden inside the real board's maths.
public final class BoardPreviewScene: SKScene {
    private let cell: CGFloat = 50

    public override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.08, green: 0.09, blue: 0.14, alpha: 1)
        build()
    }

    private func build() {
        removeAllChildren()

        // A board's worth of bricks, laid out as the game lays them: row by
        // row, back to front, each cell's brick picked by where it sits.
        let columns = 6, rows = 5
        let board = SKNode()
        board.position = CGPoint(x: size.width / 2, y: size.height / 2)
        addChild(board)

        let originX = -CGFloat(columns - 1) * cell / 2
        let originY = -CGFloat(rows - 1) * cell / 2

        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let name = "BrickGarden\((row * columns + column) % 4 + 1)"
                let brick = SKSpriteNode(texture: SKTexture(imageNamed: name),
                                         size: CGSize(width: cell, height: cell))
                brick.position = CGPoint(
                    x: originX + CGFloat(column) * cell,
                    y: originY + CGFloat(rows - 1 - row) * cell
                )
                // Nearer rows draw over farther ones, as BoardDepth orders them.
                brick.zPosition = CGFloat(row)
                board.addChild(brick)
            }
        }

        // One arrow tile, floating and bobbing, to prove actions drive the
        // frame and that alpha composites.
        let tile = SKSpriteNode(texture: SKTexture(imageNamed: "ArrowTile"),
                                size: CGSize(width: cell * 0.8, height: cell * 0.8))
        tile.zPosition = 100
        tile.position = CGPoint(x: 0, y: cell)
        board.addChild(tile)
        tile.run(.repeatForever(.sequence([
            .move(by: CGVector(dx: 0, dy: 8), duration: 0.9),
            .move(by: CGVector(dx: 0, dy: -8), duration: 0.9),
        ])))

        // A tinted sprite, so colorBlendFactor is exercised too.
        let glyph = SKSpriteNode(texture: SKTexture(imageNamed: "ArrowGlyph"),
                                 size: CGSize(width: cell * 0.5, height: cell * 0.5))
        glyph.color = SKColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1)
        glyph.colorBlendFactor = 1
        glyph.zPosition = 101
        glyph.position = CGPoint(x: 0, y: cell)
        board.addChild(glyph)

        addType()

        Log.info("preview scene: \(board.children.count) nodes, scene \(Int(size.width))x\(Int(size.height)) pt")

        // What the layer resolved, read back from the device rather than
        // reasoned about. A rect of the whole page means the name did not
        // resolve; a rect that looks right while the art does not means the
        // page is upside down, which is how the v-flip bug showed itself.
        for name in ["BrickGarden1", "ArrowTile"] {
            let texture = SKTexture(imageNamed: name)
            let r = texture.textureRect
            Log.info(String(
                format: "%@ page %@ uv %.4f,%.4f %.4fx%.4f size %.0fx%.0f",
                name, texture.page.map(String.init) ?? "nil",
                Double(r.minX), Double(r.minY), Double(r.width), Double(r.height),
                Double(texture.size().width), Double(texture.size().height)
            ))
        }
    }

    public override func didChangeSize(_ oldSize: CGSize) {
        guard !children.isEmpty else { return }
        build()
    }

    // MARK: Type and shapes

    /// The visual bar for text and vector shapes: real strings in the game's
    /// own faces on a rasterised surface, drawn through the glyph atlas and
    /// the path rasteriser.
    ///
    /// The Thai is what matters. Both lines are real strings out of
    /// `Assets/th.lproj`, and between them they hold every case FreeType
    /// alone gets wrong — SARA AM splitting into two glyphs and reordering
    /// them, a tone mark taking its shifted form over a tall consonant, a
    /// consonant swapping for its tail-less form under a below-vowel, and
    /// marks positioned by GPOS rather than stacked at the pen. If the
    /// shaper is not doing its job that is visibly broken, where a Latin
    /// line would look perfectly fine.
    ///
    /// The first line also wraps, which is the other half of it: Thai breaks
    /// between grapheme clusters rather than at spaces, and never straight
    /// after a leading vowel.
    private func addType() {
        // The scene is a wide canvas shown with aspect fill, so only the
        // middle of its width is ever on screen. This is what a phone sees.
        let visible: CGFloat = 340
        let card = SKNode()
        card.zPosition = 500
        addChild(card)

        let body = SKLabelNode(fontNamed: "KoHo-Bold")
        body.text = "ให้สวิตช์ลิงสองตัวยืนบนทั้งสองซีก แล้วชนกัน เพื่อเปิดประตูของสวิตช์ไว้ถาวร"
        body.fontSize = 17
        body.numberOfLines = 0
        body.preferredMaxLayoutWidth = visible - 48

        let samples: [SKLabelNode] = [
            body,
            label("สวิตช์ลิง ลำ ที่ ญุ", font: "KoHo-Bold", size: 26),
            label("Switchlings", font: "ChironGoRoundTC-Black", size: 26),
            label("スイッチリング 斯威奇灵 Свитчлинг", font: "ChironGoRoundTC-ExtraBold", size: 15),
        ]

        // Stacked by what each one actually measured, so a label that wrapped
        // to three lines takes three lines of room — which is the layout and
        // the renderer agreeing, read back rather than assumed.
        let gap: CGFloat = 12
        let heights = samples.map { max($0.contentFrame.height, $0.fontSize) }
        let inset: CGFloat = 18
        let height = heights.reduce(0, +) + gap * CGFloat(samples.count - 1) + inset * 2

        let panel = SKShapeNode()
        panel.path = UIBezierPath(
            roundedRect: CGRect(x: -visible / 2, y: -height / 2, width: visible, height: height),
            cornerRadius: 18
        ).cgPath
        panel.fillColor = SKColor(red: 0.99, green: 0.97, blue: 0.92, alpha: 1)
        panel.strokeColor = SKColor(red: 0.42, green: 0.33, blue: 0.24, alpha: 1)
        panel.lineWidth = 3
        panel.lineJoin = .round
        card.addChild(panel)

        var y = height / 2 - inset
        for (sample, lineHeight) in zip(samples, heights) {
            sample.fontColor = SKColor(red: 0.18, green: 0.13, blue: 0.1, alpha: 1)
            sample.horizontalAlignmentMode = .center
            sample.verticalAlignmentMode = .top
            sample.zPosition = 1
            sample.position = CGPoint(x: 0, y: y)
            card.addChild(sample)
            report(sample)
            y -= lineHeight + gap
        }

        card.position = CGPoint(x: size.width / 2, y: size.height / 2 - cell * 2.5 - height / 2)

        // An open, stroked path with a round cap and a round join, so caps
        // and joins are on screen too and not only in the tests.
        let tick = SKShapeNode()
        let stroke = UIBezierPath()
        stroke.move(to: CGPoint(x: -visible / 2 + 10, y: -height / 2 - 34))
        stroke.addLine(to: CGPoint(x: -visible / 2 + 30, y: -height / 2 - 50))
        stroke.addLine(to: CGPoint(x: -visible / 2 + 62, y: -height / 2 - 16))
        tick.path = stroke.cgPath
        tick.strokeColor = SKColor(red: 0.35, green: 0.78, blue: 0.45, alpha: 1)
        tick.fillColor = .clear
        tick.lineWidth = 7
        tick.lineCap = .round
        tick.lineJoin = .round
        card.addChild(tick)

        // The same path filled rather than stroked, with a mitred join, so
        // the two rules and the two joins can be told apart at a glance.
        let wedge = SKShapeNode()
        let filled = UIBezierPath()
        filled.move(to: CGPoint(x: visible / 2 - 66, y: -height / 2 - 48))
        filled.addLine(to: CGPoint(x: visible / 2 - 10, y: -height / 2 - 48))
        filled.addLine(to: CGPoint(x: visible / 2 - 38, y: -height / 2 - 14))
        filled.close()
        wedge.path = filled.cgPath
        wedge.fillColor = SKColor(red: 0.95, green: 0.72, blue: 0.25, alpha: 1)
        wedge.strokeColor = SKColor(red: 0.42, green: 0.33, blue: 0.24, alpha: 1)
        wedge.lineWidth = 3
        wedge.lineJoin = .miter
        card.addChild(wedge)
    }

    private func label(_ text: String, font: String, size: CGFloat) -> SKLabelNode {
        let label = SKLabelNode(fontNamed: font)
        label.text = text
        label.fontSize = size
        return label
    }

    /// What the layer worked out for a label, read back rather than assumed.
    /// A zero frame means no font was registered; a width that does not
    /// match the glyphs drawn means the layout and the renderer disagree.
    private func report(_ label: SKLabelNode) {
        let frame = label.contentFrame
        let lines = label.layout?.lines.count ?? 0
        Log.info(String(
            format: "label %@ pt in %@: %d line(s), ink %.1f x %.1f at %.1f, %.1f",
            String(format: "%.0f", Double(label.fontSize)),
            label.fontName ?? "(none)",
            lines,
            Double(frame.width), Double(frame.height),
            Double(frame.minX), Double(frame.minY)
        ))
    }
}
