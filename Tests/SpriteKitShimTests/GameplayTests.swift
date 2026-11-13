import Foundation
import Testing
@testable import SpriteKitShim

// The two things the gameplay ring added to the shim: 9-slicing, which the
// board's kerbs and raised bricks need before anything it draws looks right,
// and touch delivery, which is how a tap reaches a Switchling.
//
// Both are host-testable for the same reason the rest of the layer is: a
// frame is a value and a touch is a walk over the tree. No device, no
// window, no GL context.

@Suite("Nine-slice")
struct NineSliceTests {
    /// A kerb-shaped case: 40 points of art, 12 fixed either side, drawn
    /// 200 long.
    private let art = CGSize(width: 40, height: 40)
    private let center = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)

    @Test("An unsliced sprite stays one quad")
    func unsliced() {
        let sprite = SKSpriteNode(texture: SKTexture(imageNamed: "Anything"), size: CGSize(width: 100, height: 20))
        #expect(!sprite.isSliced)
        #expect(DrawList(scene: scene(with: sprite)).spriteCount == 1)
    }

    @Test("A sliced sprite draws as nine")
    func nine() {
        let sprite = SKSpriteNode(texture: SKTexture(imageNamed: "Anything"), size: CGSize(width: 200, height: 200))
        sprite.centerRect = center
        #expect(sprite.isSliced)
        // Without a texture whose art size is known, nothing can be sliced:
        // the patches need the border widths in points.
        let patches = NineSlice.patches(
            frame: CGRect(x: -100, y: -100, width: 200, height: 200),
            textureSize: art,
            center: center
        )
        #expect(patches.count == 9)
    }

    @Test("Corners keep their size while the middle stretches")
    func cornersKeepTheirSize() {
        let patches = NineSlice.patches(
            frame: CGRect(x: 0, y: 0, width: 200, height: 40),
            textureSize: art,
            center: center
        )
        let widths = Set(patches.map(\.frame.width).map { ($0 * 1000).rounded() / 1000 })
        // 12 fixed either side, 176 in the middle.
        #expect(widths == [12, 176])
        let heights = Set(patches.map(\.frame.height).map { ($0 * 1000).rounded() / 1000 })
        #expect(heights == [12, 16])
    }

    @Test("The patches tile the frame exactly, with no gap and no overlap")
    func tilesTheFrame() {
        let frame = CGRect(x: -50, y: -20, width: 137, height: 61)
        let patches = NineSlice.patches(frame: frame, textureSize: art, center: center)
        #expect(patches.map(\.frame).reduce(CGRect.null) { $0.union($1) } == frame)
        let area = patches.reduce(0) { $0 + $1.frame.width * $1.frame.height }
        #expect(abs(area - frame.width * frame.height) < 0.001)
    }

    @Test("Each patch samples its own part of the texture, in order")
    func samplesInOrder() {
        let patches = NineSlice.patches(
            frame: CGRect(x: 0, y: 0, width: 200, height: 200),
            textureSize: art,
            center: center
        )
        // Rows run bottom to top, columns left to right, and the unit rects
        // tile 0...1 the same way the frames tile the frame.
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9
                && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
        }
        #expect(near(patches[0].unit, CGRect(x: 0, y: 0, width: 0.3, height: 0.3)))
        #expect(near(patches[4].unit, center))
        #expect(abs(patches[8].unit.maxX - 1) < 1e-9)
        #expect(abs(patches[8].unit.maxY - 1) < 1e-9)
    }

    @Test("Borders too big for the frame shrink together rather than overlap")
    func bordersShrink() {
        // 24 points of fixed border asked to fit in 8: both shrink to 4, and
        // the middle, left with nothing, is dropped rather than inverted.
        let frame = CGRect(x: 0, y: 0, width: 8, height: 40)
        let patches = NineSlice.patches(frame: frame, textureSize: art, center: center)
        #expect(patches.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
        #expect(Set(patches.map(\.frame.width)) == [4])
        #expect(patches.map(\.frame).reduce(CGRect.null) { $0.union($1) } == frame)
    }

    private func scene(with node: SKNode) -> SKScene {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        scene.addChild(node)
        return scene
    }
}

@Suite("Touches")
struct TouchTests {
    /// A node that records what it was handed, standing in for the game's
    /// own `touchesBegan` overrides.
    final class Tappable: SKSpriteNode {
        var began: [CGPoint] = []
        var moved: [CGPoint] = []
        var ended = 0
        var cancelled = 0

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            began += touches.map { $0.location(in: self) }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            moved += touches.map { $0.location(in: self) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { ended += 1 }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelled += 1 }
    }

    private func scene() -> SKScene {
        SKScene(size: CGSize(width: 200, height: 200))
    }

    private func tappable(at position: CGPoint, size: CGFloat = 40) -> Tappable {
        let node = Tappable(color: .white, size: CGSize(width: size, height: size))
        node.position = position
        node.isUserInteractionEnabled = true
        return node
    }

    @Test("A node that takes touches gets the ones that land on it")
    func lands() {
        let scene = scene()
        let node = tappable(at: CGPoint(x: 100, y: 100))
        scene.addChild(node)

        scene.deliverTouch(phase: .began, at: CGPoint(x: 100, y: 100), timestamp: 0)
        #expect(node.began.count == 1)
        #expect(node.began.first == CGPoint(x: 0, y: 0))
    }

    @Test("A touch that misses goes to the scene, not to the node")
    func misses() {
        let scene = scene()
        let node = tappable(at: CGPoint(x: 100, y: 100))
        scene.addChild(node)

        let target = scene.deliverTouch(phase: .began, at: CGPoint(x: 10, y: 10), timestamp: 0)
        #expect(node.began.isEmpty)
        #expect(target === scene)
    }

    @Test("The topmost node takes the tap")
    func topmostWins() {
        let scene = scene()
        let under = tappable(at: CGPoint(x: 100, y: 100))
        under.zPosition = 1
        let over = tappable(at: CGPoint(x: 100, y: 100))
        over.zPosition = 2
        scene.addChild(under)
        scene.addChild(over)

        scene.deliverTouch(phase: .began, at: CGPoint(x: 100, y: 100), timestamp: 0)
        #expect(over.began.count == 1)
        #expect(under.began.isEmpty)
    }

    @Test("A node is hit over everything it draws, children included")
    func hitsOverChildren() {
        // Every one of the game's buttons is a plain SKNode whose art hangs
        // off it, so hit-testing the node's own quad would never find one.
        final class Holder: SKNode {
            var taps = 0
            override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { taps += 1 }
        }
        let scene = scene()
        let holder = Holder()
        holder.position = CGPoint(x: 100, y: 100)
        holder.isUserInteractionEnabled = true
        holder.addChild(SKSpriteNode(color: .white, size: CGSize(width: 40, height: 40)))
        scene.addChild(holder)

        scene.deliverTouch(phase: .began, at: CGPoint(x: 110, y: 110), timestamp: 0)
        #expect(holder.taps == 1)
    }

    @Test("A touch stays with the node it began on, even once it leaves")
    func staysWithItsNode() {
        let scene = scene()
        let node = tappable(at: CGPoint(x: 100, y: 100))
        scene.addChild(node)

        scene.deliverTouch(phase: .began, at: CGPoint(x: 100, y: 100), timestamp: 0)
        scene.deliverTouch(phase: .moved, at: CGPoint(x: 10, y: 10), timestamp: 0.1)
        scene.deliverTouch(phase: .ended, at: CGPoint(x: 10, y: 10), timestamp: 0.2)

        #expect(node.moved.count == 1)
        #expect(node.moved.first == CGPoint(x: -90, y: -90))
        #expect(node.ended == 1)
    }

    @Test("Two fingers are tracked apart")
    func twoFingers() {
        let scene = scene()
        let left = tappable(at: CGPoint(x: 50, y: 100))
        let right = tappable(at: CGPoint(x: 150, y: 100))
        scene.addChild(left)
        scene.addChild(right)

        scene.deliverTouch(phase: .began, at: CGPoint(x: 50, y: 100), identifier: 1, timestamp: 0)
        scene.deliverTouch(phase: .began, at: CGPoint(x: 150, y: 100), identifier: 2, timestamp: 0)
        scene.deliverTouch(phase: .ended, at: CGPoint(x: 150, y: 100), identifier: 2, timestamp: 0.1)

        #expect(left.began.count == 1)
        #expect(right.began.count == 1)
        #expect(left.ended == 0)
        #expect(right.ended == 1)
    }

    @Test("A hidden node takes nothing")
    func hidden() {
        let scene = scene()
        let node = tappable(at: CGPoint(x: 100, y: 100))
        node.isHidden = true
        scene.addChild(node)

        scene.deliverTouch(phase: .began, at: CGPoint(x: 100, y: 100), timestamp: 0)
        #expect(node.began.isEmpty)
    }

    @Test("Cancelling reaches every touch in flight")
    func cancelsEverything() {
        let scene = scene()
        let node = tappable(at: CGPoint(x: 100, y: 100), size: 200)
        scene.addChild(node)

        scene.deliverTouch(phase: .began, at: CGPoint(x: 100, y: 100), identifier: 1, timestamp: 0)
        scene.deliverTouch(phase: .began, at: CGPoint(x: 90, y: 90), identifier: 2, timestamp: 0)
        scene.cancelTouches(timestamp: 0.1)

        #expect(node.cancelled == 2)
    }

    @Test("nodes(at:) lists what is drawn there, topmost first")
    func nodesAtPoint() {
        let scene = scene()
        let under = SKSpriteNode(color: .white, size: CGSize(width: 40, height: 40))
        under.position = CGPoint(x: 100, y: 100)
        under.zPosition = 1
        let over = SKSpriteNode(color: .white, size: CGSize(width: 40, height: 40))
        over.position = CGPoint(x: 100, y: 100)
        over.zPosition = 5
        scene.addChild(under)
        scene.addChild(over)

        let hits = scene.nodes(at: CGPoint(x: 100, y: 100))
        #expect(hits.first === over)
        #expect(hits.contains { $0 === under })
        // The scene itself draws its own rect, so a point inside it with
        // nothing on it finds the scene and nothing else — SpriteKit's own
        // answer, which is why `atPoint` returns the receiver.
        #expect(scene.nodes(at: CGPoint(x: 5, y: 5)).map { ObjectIdentifier($0) } == [ObjectIdentifier(scene)])
    }
}

@Suite("Actions that change their own node's actions")
struct ReentrantActionTests {
    // The game does this constantly and SpriteKit allows it: a looping
    // glance schedules the next one from inside itself, a board cue starts
    // the move it announces, a completion starts the next step. Advancing
    // the list in place made the second access abort the process with
    // "Fatal access conflict detected" — a real crash on a device, three
    // seconds into the first level.

    @Test("An action may start another on the same node from inside itself")
    func startsAnother() {
        let node = SKNode()
        var ran = 0
        node.run(.sequence([
            .wait(forDuration: 0.1),
            .run {
                ran += 1
                if ran < 3 {
                    node.run(.sequence([.wait(forDuration: 0.1), .run { ran += 1 }]))
                }
            },
        ]))
        for _ in 0 ..< 10 { node.tickActions(0.1) }
        #expect(ran >= 2)
    }

    @Test("An action may replace itself by key from inside itself")
    func replacesItself() {
        let node = SKNode()
        var loops = 0
        func schedule() {
            node.run(.sequence([
                .wait(forDuration: 0.1),
                .run {
                    loops += 1
                    if loops < 4 { schedule() }
                },
            ]), withKey: "loop")
        }
        schedule()
        for _ in 0 ..< 20 { node.tickActions(0.1) }
        #expect(loops == 4)
    }

    @Test("An action may stop every action on its node")
    func clearsThemAll() {
        let node = SKNode()
        var later = 0
        node.run(.sequence([.wait(forDuration: 0.3), .run { later += 1 }]))
        node.run(.sequence([.wait(forDuration: 0.1), .run { node.removeAllActions() }]))
        for _ in 0 ..< 10 { node.tickActions(0.1) }
        #expect(later == 0)
        #expect(!node.hasActions)
    }

    @Test("A child may remove itself while its parent walks the tree")
    func childRemovesItself() {
        let parent = SKNode()
        let child = SKNode()
        parent.addChild(child)
        parent.addChild(SKNode())
        child.run(.sequence([.wait(forDuration: 0.1), .run { child.removeFromParent() }]))
        for _ in 0 ..< 5 { parent.tickActions(0.1) }
        #expect(parent.children.count == 1)
    }
}
