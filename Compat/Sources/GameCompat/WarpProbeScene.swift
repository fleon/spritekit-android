import Foundation
import SpriteKitShim

/// Real backdrop pieces bent by the game's own `BackdropWarp` and
/// `BackdropTouch`, on bare lawn: the shell's `warp` scene (`debug.switchlings.scene`).
///
/// Not a backdrop — `LawnNode` lays a lawn out round a board and is the
/// backdrop stage's. This only shows that SKWarpGeometry bends on Android as
/// it does on iOS: a tree crown stirring, plants swaying at the game's own
/// values and at four times the sway, a butterfly beating its wings, and
/// a bush and a hedge reacting to a tap now and then, as they would to a
/// player's. A tap on any of them plays its reaction too.
public final class WarpProbeScene: SKScene {
    /// Pieces are shown larger than a backdrop lays them, so the bend reads.
    private static let magnify: CGFloat = 1.6
    private var touchable: [(node: SKSpriteNode, reaction: BackdropTouch.Reaction)] = []

    public override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .aspectFill
        backgroundColor = WorldTheme.garden.palette.backgroundBottom
    }

    public override func didMove(to view: SKView) {
        guard children.isEmpty else { return }
        // The scene is a wide canvas shown with aspect fill: lay out in the
        // part of it the screen shows.
        let aspect = view.bounds.height > 0 ? view.bounds.width / view.bounds.height : 1
        let w = min(size.width, size.height * aspect), h = min(size.height, size.width / aspect)
        let left = (size.width - w) / 2, bottom = (size.height - h) / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: left + x, y: bottom + y) }
        // The renderer clears to black and draws no scene background yet.
        let ground = SKSpriteNode(color: backgroundColor, size: size)
        ground.anchorPoint = .zero
        ground.zPosition = -10
        addChild(ground)

        // A crown from above, stirring as Bug Woods' canopy does, and the
        // same crown stirring four times as far.
        let crownStir = DesignSystem.lawnCrownStir
        let stir = DesignSystem.lawnCrownStirPeriod.lowerBound
        BackdropWarp.crown(piece("BackdropMeadowKitOak", at: pt(w * 0.28, h * 0.84), scale: 1), reach: crownStir, period: stir, seed: 3)
        BackdropWarp.crown(piece("BackdropMeadowKitOak", at: pt(w * 0.72, h * 0.84), scale: 1), reach: crownStir * 4, period: stir, seed: 11)

        // Plants at the lawn's own sway, then at four times it.
        let plants = ["BackdropGardenKitFoxglove", "BackdropGardenKitTulips", "BackdropFarmKitSunflower", "BackdropMeadowKitFern"]
        for (row, sway) in [(0.52, DesignSystem.lawnPlantSway), (0.34, DesignSystem.lawnPlantSway * 4)] {
            for (index, name) in plants.enumerated() {
                let node = piece(name, at: pt(w * (0.13 + 0.235 * CGFloat(index)), h * CGFloat(row)), foot: true)
                BackdropWarp.plant(node, pin: DesignSystem.lawnPlantPin, degrees: sway,
                                   period: DesignSystem.lawnSwayPeriod + Double(index % 5) * 0.41, seed: index)
                touchable.append((node, .rustle(pin: DesignSystem.lawnPlantPin)))
            }
        }

        // Wings beating round a still body.
        let butterfly = piece("BackdropGardenKitButterflyBlue", at: pt(w * 0.5, h * 0.66), scale: 2.5)
        BackdropWarp.wings(butterfly, body: 0.08, fold: 0.35, lift: 0.08, beat: 0.42, phase: 0)

        // Reactions to a tap, taking turns.
        let bush = piece("BackdropGardenKitRoseBush", at: pt(w * 0.27, h * 0.1), foot: true)
        let hedge = piece("BackdropGardenKitHedge", at: pt(w * 0.73, h * 0.1), foot: true)
        let stool = piece("BackdropMeadowKitToadstool", at: pt(w * 0.5, h * 0.2), foot: true)
        touchable += [(bush, .rustle(pin: 0.05)), (hedge, .squash(pin: 0)), (stool, .rock(pin: 0))]
        let turns: [(SKSpriteNode, BackdropTouch.Reaction)] = [
            (bush, .rustle(pin: 0.05)), (hedge, .squash(pin: 0)), (stool, .rock(pin: 0)), (stool, .hop),
        ]
        var turn = 0
        run(.repeatForever(.sequence([
            .wait(forDuration: 1.4),
            .run {
                let (node, reaction) = turns[turn % turns.count]
                BackdropTouch.react(node, reaction)
                turn += 1
            },
        ])))
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        let items = touchable.map { (frame: $0.node.frame, item: $0) }
        guard let hit = BackdropTouch.hit(point, in: items) else { return }
        BackdropTouch.react(hit.node, hit.reaction)
    }

    private func piece(_ name: String, at point: CGPoint, foot: Bool = false, scale: CGFloat = magnify) -> SKSpriteNode {
        let node = SKSpriteNode(imageNamed: name)
        node.size = CGSize(width: node.size.width * scale, height: node.size.height * scale)
        node.anchorPoint = pt(0.5, foot ? DesignSystem.lawnPieceFoot : 0.5)
        node.position = point
        node.zPosition = 1 - point.y / max(size.height, 1)
        addChild(node)
        return node
    }
}
