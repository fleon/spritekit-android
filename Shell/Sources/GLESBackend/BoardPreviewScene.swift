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
}
