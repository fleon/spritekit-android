import Foundation
import Testing
@testable import SpriteKitShim

// The whole layer is testable with no device, window or GL context, because
// a frame is a value (DrawList) rather than a sequence of draw calls.

@Suite("Scene graph")
struct SceneGraphTests {
    @Test("A child's world transform composes through its parents")
    func worldTransform() {
        let root = SKNode()
        root.position = CGPoint(x: 100, y: 50)
        let child = SKNode()
        child.position = CGPoint(x: 10, y: 10)
        root.addChild(child)

        let placed = CGPoint.zero.applying(child.worldTransform)
        #expect(placed.x == 110)
        #expect(placed.y == 60)
    }

    @Test("Scale compounds down the tree")
    func scaleCompounds() {
        let root = SKNode()
        root.setScale(2)
        let child = SKNode()
        child.setScale(3)
        child.position = CGPoint(x: 1, y: 0)
        root.addChild(child)

        // The child's own offset is scaled by the parent, not by itself.
        let placed = CGPoint.zero.applying(child.worldTransform)
        #expect(abs(placed.x - 2) < 0.0001)
    }

    @Test("convert round-trips between two nodes")
    func convertRoundTrip() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let a = SKNode(); a.position = CGPoint(x: 10, y: 20)
        let b = SKNode(); b.position = CGPoint(x: -5, y: 7); b.zRotation = 0.3
        scene.addChild(a)
        scene.addChild(b)

        let point = CGPoint(x: 3, y: 4)
        let there = a.convert(point, to: b)
        let back = a.convert(there, from: b)
        #expect(abs(back.x - point.x) < 0.0001)
        #expect(abs(back.y - point.y) < 0.0001)
    }

    @Test("Alpha multiplies down the tree")
    func alphaMultiplies() {
        let root = SKNode(); root.alpha = 0.5
        let child = SKNode(); child.alpha = 0.5
        root.addChild(child)
        #expect(child.worldAlpha == 0.25)
    }

    @Test("removeFromParent detaches both ways")
    func removeFromParent() {
        let root = SKNode()
        let child = SKNode()
        root.addChild(child)
        #expect(root.children.count == 1)
        child.removeFromParent()
        #expect(root.children.isEmpty)
        #expect(child.parent == nil)
    }

    @Test("Accumulated frame spans the subtree")
    func accumulatedFrame() {
        let root = SKNode()
        let left = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        left.position = CGPoint(x: -20, y: 0)
        let right = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        right.position = CGPoint(x: 20, y: 0)
        root.addChild(left)
        root.addChild(right)

        let frame = root.calculateAccumulatedFrame()
        #expect(frame.minX == -25)
        #expect(frame.maxX == 25)
    }

    @Test("A hidden child is left out of the accumulated frame")
    func hiddenLeftOut() {
        let root = SKNode()
        let shown = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        let hidden = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        hidden.position = CGPoint(x: 100, y: 0)
        hidden.isHidden = true
        root.addChild(shown)
        root.addChild(hidden)
        #expect(root.calculateAccumulatedFrame().maxX == 5)
    }
}

@Suite("Actions")
struct ActionTests {
    /// Drives a node's actions the way the renderer does.
    private func run(_ node: SKNode, seconds: TimeInterval, step: TimeInterval = 1.0 / 60) {
        var played: TimeInterval = 0
        while played < seconds {
            node.tickActions(step)
            played += step
        }
    }

    @Test("move(to:) lands exactly on its target")
    func moveTo() {
        let node = SKNode()
        node.run(.move(to: CGPoint(x: 100, y: 0), duration: 0.5))
        run(node, seconds: 0.6)
        #expect(abs(node.position.x - 100) < 0.0001)
    }

    @Test("A sequence runs its steps in order and finishes")
    func sequence() {
        let node = SKNode()
        var marks: [String] = []
        node.run(.sequence([
            .run { marks.append("one") },
            .wait(forDuration: 0.1),
            .run { marks.append("two") },
        ]))
        run(node, seconds: 0.3)
        #expect(marks == ["one", "two"])
        #expect(!node.hasActions)
    }

    @Test("customAction is handed elapsed seconds, not progress")
    func customActionElapsed() {
        let node = SKNode()
        var last: CGFloat = -1
        node.run(.customAction(withDuration: 1.0) { _, elapsed in last = elapsed })
        run(node, seconds: 0.5)
        // Halfway through a one-second action, SpriteKit reports ~0.5s.
        #expect(last > 0.4 && last < 0.6)
    }

    @Test("repeatForever keeps running and never reports done")
    func repeatForever() {
        let node = SKNode()
        var ticks = 0
        node.run(.repeatForever(.sequence([
            .run { ticks += 1 },
            .wait(forDuration: 0.1),
        ])))
        run(node, seconds: 0.55)
        #expect(ticks >= 4)
        #expect(node.hasActions)
    }

    @Test("A keyed action replaces the one already under that key")
    func keyedReplacement() {
        let node = SKNode()
        node.run(.fadeAlpha(to: 0, duration: 10), withKey: "fade")
        node.run(.fadeAlpha(to: 1, duration: 10), withKey: "fade")
        #expect(node.action(forKey: "fade") != nil)
        node.removeAction(forKey: "fade")
        #expect(node.action(forKey: "fade") == nil)
        #expect(!node.hasActions)
    }

    @Test("A group finishes only when its longest member does")
    func group() {
        let node = SKNode()
        node.run(.group([
            .fadeAlpha(to: 0, duration: 0.1),
            .move(to: CGPoint(x: 10, y: 0), duration: 0.4),
        ]))
        run(node, seconds: 0.2)
        #expect(node.hasActions)
        run(node, seconds: 0.4)
        #expect(!node.hasActions)
        #expect(abs(node.position.x - 10) < 0.0001)
    }

    @Test("Paused nodes do not advance")
    func paused() {
        let node = SKNode()
        node.isPaused = true
        node.run(.move(to: CGPoint(x: 100, y: 0), duration: 0.1))
        run(node, seconds: 0.3)
        #expect(node.position.x == 0)
    }

    @Test("A node's speed scales its own actions")
    func speed() {
        let fast = SKNode(); fast.speed = 2
        let slow = SKNode(); slow.speed = 1
        for node in [fast, slow] {
            node.run(.move(to: CGPoint(x: 100, y: 0), duration: 1.0))
        }
        run(fast, seconds: 0.5)
        run(slow, seconds: 0.5)
        #expect(fast.position.x > slow.position.x)
    }

    @Test("removeFromParent as an action detaches the node")
    func removeAction() {
        let root = SKNode()
        let child = SKNode()
        root.addChild(child)
        child.run(.sequence([.wait(forDuration: 0.05), .removeFromParent()]))
        run(root, seconds: 0.2)
        #expect(root.children.isEmpty)
    }
}

@Suite("Draw list")
struct DrawListTests {
    @Test("Sprites come out ordered by accumulated zPosition")
    func zOrder() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let back = SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1))
        back.zPosition = 1
        back.name = "back"
        let front = SKSpriteNode(color: .blue, size: CGSize(width: 1, height: 1))
        front.zPosition = 10
        front.name = "front"
        scene.addChild(front)
        scene.addChild(back)

        let list = DrawList(scene: scene)
        #expect(list.commands.count == 2)
        // Added front-first, but z decides: back must be drawn first.
        if case let .sprite(first) = list.commands[0] {
            #expect(first.color.red == 1)  // the red one
        } else {
            Issue.record("expected a sprite")
        }
    }

    @Test("A parent's zPosition accumulates into its children's")
    func zAccumulates() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let low = SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1))
        low.zPosition = 100

        let group = SKNode()
        group.zPosition = 1000
        let high = SKSpriteNode(color: .blue, size: CGSize(width: 1, height: 1))
        high.zPosition = 1
        group.addChild(high)

        scene.addChild(group)
        scene.addChild(low)

        let list = DrawList(scene: scene)
        // The grouped sprite sits at 1001, above the loose one at 100.
        if case let .sprite(first) = list.commands[0] {
            #expect(first.color.red == 1)
        } else {
            Issue.record("expected a sprite")
        }
    }

    @Test("Hidden and fully transparent subtrees are skipped")
    func skipsInvisible() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let hidden = SKNode(); hidden.isHidden = true
        hidden.addChild(SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1)))
        let transparent = SKNode(); transparent.alpha = 0
        transparent.addChild(SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1)))
        scene.addChild(hidden)
        scene.addChild(transparent)
        #expect(DrawList(scene: scene).commands.isEmpty)
    }

    @Test("An effect node collapses its subtree into one command")
    func effectNesting() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let effect = SKEffectNode()
        effect.shader = SKShader(source: "void main() {}")
        for _ in 0 ..< 3 {
            effect.addChild(SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1)))
        }
        scene.addChild(effect)

        let list = DrawList(scene: scene)
        #expect(list.commands.count == 1)
        guard case let .effect(e) = list.commands[0] else {
            Issue.record("expected an effect")
            return
        }
        #expect(e.contents.commands.count == 3)
        #expect(e.shader != nil)
        #expect(list.spriteCount == 3)
    }

    @Test("A crop node carries its mask separately")
    func cropMask() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let crop = SKCropNode()
        crop.maskNode = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 10))
        crop.addChild(SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1)))
        scene.addChild(crop)

        guard case let .crop(c) = DrawList(scene: scene).commands[0] else {
            Issue.record("expected a crop")
            return
        }
        #expect(c.mask.commands.count == 1)
        #expect(c.contents.commands.count == 1)
    }

    @Test("Sprite anchor points place the quad")
    func anchorPoint() {
        let sprite = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        #expect(sprite.contentFrame.minX == -5)
        sprite.anchorPoint = .zero
        #expect(sprite.contentFrame.minX == 0)
    }

    @Test("A frame carries the node's shader and attributes through")
    func shaderPassthrough() {
        let scene = SKScene(size: CGSize(width: 10, height: 10))
        let sprite = SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1))
        sprite.shader = SKShader(source: "x", uniforms: [SKUniform(name: "u_tint", float: 0.5)])
        sprite.setValue(SKAttributeValue(float: 2), forAttribute: "a_run")
        scene.addChild(sprite)

        guard case let .sprite(drawn) = DrawList(scene: scene).commands[0] else {
            Issue.record("expected a sprite")
            return
        }
        #expect(drawn.shader?.uniforms.first?.name == "u_tint")
        #expect(drawn.attributeValues["a_run"]?.floatValue == 2)
    }
}

@Suite("A frame of a scene")
struct FrameTests {
    /// A scene subclass, the way the game writes them.
    final class DemoScene: SKScene {
        private(set) var moved = false
        private(set) var updates = 0
        override func didMove(to view: SKView) { moved = true }
        override func update(_ currentTime: TimeInterval) { updates += 1 }
    }

    @Test("Presenting a scene calls didMove, and a tick drives update and actions")
    func sceneLifecycle() {
        let view = SKView(bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        let scene = DemoScene(size: CGSize(width: 200, height: 100))
        let sprite = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        sprite.run(.move(to: CGPoint(x: 50, y: 0), duration: 0.5))
        scene.addChild(sprite)

        view.presentScene(scene)
        #expect(scene.moved)

        var list = DrawList()
        var time: TimeInterval = 0
        for _ in 0 ..< 40 {
            time += 1.0 / 60
            list = view.tick(currentTime: time, delta: 1.0 / 60)
        }
        #expect(scene.updates == 40)
        #expect(abs(sprite.position.x - 50) < 0.0001)
        #expect(list.commands.count == 1)
    }
}
