import Foundation
import SpriteKitShim

/// Starry Sky's backdrop, drawn by the game's own `NightSkyNode`.
///
/// This file is the port's, not the game's — everything it drives is real:
/// `NightSkyNode` (972 lines), `BandedLayerNode`, `Theme` and `WorldTheme` are
/// symlinked out of `Source/` and compiled unmodified, and the colours, the
/// nebula, the stars, the planets and the shooting stars are the ones the
/// iOS build shows.
///
/// It stands in for `BackdropNode`, which is the real host and belongs to a
/// later ring: that one also owns the edge blur, the gradient underneath, the
/// ambient motes and `keepClear` fed from each screen's layout. The sequence
/// here is the one `BackdropNode` performs — lay out, say what the screen
/// covers, bake, then let the backdrop's own action run — so what is being
/// measured is the real cost of the real scenery.
///
/// A board of Sky's bricks sits over it, lit as the board art is lit, so the
/// frame has something in front of the backdrop to composite against and the
/// two measurements (with the sky, without it) differ by the sky alone.
public final class SkyBackdropScene: SKScene {
    /// Whether the night draws at all. The point of the measurement: the
    /// same board, the same frame loop, with and without the backdrop.
    public var drawsBackdrop: Bool

    /// Whether the night draws in bands (`BandedLayerNode`), which is what
    /// iOS does on every screen that shows a board.
    public let banded: Bool

    private var backdrop: NightSkyNode?
    private let board = SKNode()
    private var laidOut = CGSize.zero
    private var baked = false

    private let cell: CGFloat = 50

    public init(size: CGSize, drawsBackdrop: Bool = true, banded: Bool = true) {
        self.drawsBackdrop = drawsBackdrop
        self.banded = banded
        super.init(size: size)
        scaleMode = .aspectFill
    }

    public override func didMove(to view: SKView) {
        // Sky's own background, so a frame drawn without the backdrop still
        // shows the colour the gradient would stand in with.
        backgroundColor = WorldTheme.sky.palette.backgroundBottom
        build()
    }

    public override func didChangeSize(_ oldSize: CGSize) {
        guard !children.isEmpty else { return }
        build()
    }

    private func build() {
        removeAllChildren()
        backdrop = nil
        baked = false
        laidOut = .zero

        if drawsBackdrop, let look = NightSkyNode.look(for: .sky) {
            let night = NightSkyNode(look: look, banded: banded)
            night.zPosition = -100
            addChild(night)
            // The shooting star flies over everything, the board included —
            // `BackdropNode` hosts `fliers` outside its edge blur, at
            // `DesignSystem.backdropFliersZ`.
            if let fliers = night.fliers {
                fliers.zPosition = DesignSystem.backdropFliersZ
                addChild(fliers)
            }
            backdrop = night
        }

        board.zPosition = 0
        addChild(board)
        buildBoard()
    }

    /// A board's worth of Sky's bricks, laid out as the game lays them: row
    /// by row, back to front, each cell's brick picked by where it sits.
    private func buildBoard() {
        board.removeAllChildren()
        let columns = 6, rows = 5
        board.position = CGPoint(x: size.width / 2, y: size.height / 2)

        let originX = -CGFloat(columns - 1) * cell / 2
        let originY = -CGFloat(rows - 1) * cell / 2

        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let texture = txtr("BrickSky\((row * columns + column) % 4 + 1)")

                // A brick is not a square: its top face fills the cell and its
                // front face hangs below it, which is the whole mechanism by
                // which a nearer row covers the row behind. `TileNode` sizes
                // it `cell * painted.height / painted.width` and lifts it so
                // the top face lands on the cell. Drawn square, as this was,
                // the board reads flat — the same slip `BoardPreviewScene`
                // had and #397 fixed.
                let art = texture.size()
                let height = art.width > 0 ? cell * art.height / art.width : cell
                let brick = SKSpriteNode(texture: texture,
                                         size: CGSize(width: cell, height: height))

                let cellY = originY + CGFloat(rows - 1 - row) * cell
                brick.position = CGPoint(
                    x: originX + CGFloat(column) * cell,
                    y: cellY + cell / 2 - height / 2
                )
                // `DesignSystem.boardRowSpan`, which this target can name
                // because it compiles the real file: the z a row takes, so
                // the BoardDepth order within a row fits between two rows.
                brick.zPosition = CGFloat(row) * DesignSystem.boardRowSpan
                board.addChild(brick)
            }
        }
    }

    public override func update(_ currentTime: TimeInterval) {
        guard let backdrop, let view else { return }
        guard size.width > 0, size.height > 0 else { return }

        let area = CGRect(origin: .zero, size: size)
        if laidOut != size {
            laidOut = size
            baked = false
            backdrop.position = .zero
            backdrop.layout(area, drawing: area)
            // What the screen covers, so the planets start in free room.
            // `BackdropNode` is fed this by whichever scene is up; the board
            // is what covers anything here.
            backdrop.keepClear(
                [board.calculateAccumulatedFrame().applying(board.localTransform)],
                safe: area, variant: 0, animated: false
            )
            // Behind gameplay the night calms and shades away from the board.
            backdrop.focus(on: board.calculateAccumulatedFrame().applying(board.localTransform))
        }

        if !baked {
            // Points of the view to a scene unit: 1 where the scene is sized
            // to the view, which is how `DesignSystem.sceneSize(for:)` sizes
            // it. A band's cache renders at the scene's density and is
            // magnified inside by this, then shrunk back.
            let pointsPerUnit = view.contentScaleFactor > 0
                ? (view.bounds.height / view.contentScaleFactor) / size.height
                : 1
            backdrop.bake(in: view, pointsPerUnit: max(pointsPerUnit, 0.001))
            baked = backdrop.hasBaked
        }
    }
}

extension NightSkyNode {
    /// Whether `bake` got its floor. It keeps the texture privately, and the
    /// scene needs to know whether to ask again next frame — the first few
    /// frames run before the renderer can answer `texture(from:)`.
    var hasBaked: Bool {
        !children.filter { !$0.isHidden }.isEmpty
    }
}
