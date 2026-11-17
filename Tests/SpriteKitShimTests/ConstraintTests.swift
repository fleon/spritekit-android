import Foundation
import Testing
@testable import SpriteKitShim

// SpriteKit's constraints, pinned to SpriteKit's own: each case was run
// through `SKRenderer` on a Mac (macOS 27.2), a scene of nodes like these
// updated a tenth of a second at a time, and the numbers expected here are
// what it reported.

@MainActor
private final class Scene: SKScene {
    var log: [String] = []
    weak var watched: SKNode?
    override func update(_ currentTime: TimeInterval) { if let watched { log.append("update \(watched.position.x)") } }
    override func didApplyConstraints() { if let watched { log.append("constrained \(watched.position.x)") } }
}

@MainActor
private func frame(_ renderer: SKRenderer, _ clock: inout TimeInterval) {
    clock += 0.1
    renderer.update(atTime: clock)
}

@MainActor
private func makeScene() -> (Scene, () -> Void) {
    let scene = Scene(size: CGSize(width: 100, height: 100))
    let renderer = SKRenderer(device: MTLDevice())
    renderer.scene = scene
    var clock: TimeInterval = 100
    renderer.update(atTime: clock)
    return (scene, { frame(renderer, &clock) })
}

private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.001) -> Bool { abs(a - b) < tolerance }
private func near(_ a: CGPoint, _ x: CGFloat, _ y: CGFloat) -> Bool { near(a.x, x) && near(a.y, y) }

@Suite("Constraints: SpriteKit's")
@MainActor
struct ConstraintTests {
    @Test("Applied in the frame, after the actions, before didApplyConstraints")
    func whenTheyApply() {
        let (scene, step) = makeScene()
        let node = SKNode()
        scene.addChild(node)
        scene.watched = node
        node.constraints = [.positionX(SKRange(lowerLimit: 10, upperLimit: 20))]
        #expect(node.position.x == 0)
        node.run(.moveBy(x: 100, y: 0, duration: 1))
        step()
        #expect(near(node.position.x, 10))
        #expect(scene.log == ["update 0.0", "constrained 10.0"])
        step()
        #expect(near(node.position.x, 20))

        node.removeAllActions()
        node.position.x = -5
        #expect(node.position.x == -5)
        step()
        #expect(near(node.position.x, 10))
    }

    @Test("Positions in the reference node's space")
    func referenceNode() {
        let (scene, step) = makeScene()
        let reference = SKNode()
        reference.position = CGPoint(x: 50, y: 0)
        reference.setScale(2)
        scene.addChild(reference)
        let parent = SKNode()
        parent.position = CGPoint(x: 10, y: 0)
        scene.addChild(parent)
        let node = SKNode()
        parent.addChild(node)
        let constraint = SKConstraint.positionX(SKRange(lowerLimit: 5, upperLimit: 6))
        constraint.referenceNode = reference
        node.constraints = [constraint]
        step()
        #expect(near(node.position, 50, 0))
    }

    @Test("Not in a scene, or in a paused one: left alone; a paused node is not")
    func outOfScene() {
        let (scene, step) = makeScene()
        let loose = SKNode()
        loose.position.x = 100
        loose.constraints = [.positionX(SKRange(upperLimit: 1))]
        step()
        #expect(loose.position.x == 100)

        let paused = SKNode()
        paused.position.x = 100
        paused.isPaused = true
        scene.addChild(paused)
        paused.constraints = [.positionX(SKRange(upperLimit: 5))]
        step()
        #expect(near(paused.position.x, 5))

        let inPaused = SKNode()
        inPaused.position.x = 15
        scene.addChild(inPaused)
        inPaused.constraints = [.positionX(SKRange(upperLimit: 1))]
        scene.isPaused = true
        step()
        #expect(inPaused.position.x == 15)

        // Taken out, it is let go.
        scene.isPaused = false
        inPaused.removeFromParent()
        inPaused.position.x = 15
        step()
        #expect(inPaused.position.x == 15)
    }

    @Test("Distance from a node or a point")
    func distance() {
        let (scene, step) = makeScene()
        let target = SKNode()
        target.position = CGPoint(x: 50, y: 50)
        scene.addChild(target)
        let node = SKNode()
        node.position = CGPoint(x: 50, y: 0)
        scene.addChild(node)
        node.constraints = [.distance(SKRange(lowerLimit: 10, upperLimit: 20), to: target)]
        step()
        #expect(near(node.position, 50, 30))
        node.position = CGPoint(x: 52, y: 49)
        step()
        #expect(near(node.position, 58.944, 45.528))
        node.position = CGPoint(x: 50, y: 50)
        step()
        #expect(near(node.position, 50, 50))

        node.constraints = [.distance(SKRange(upperLimit: 10), to: CGPoint(x: 0, y: 0))]
        node.position = CGPoint(x: 30, y: 40)
        step()
        #expect(near(node.position, 6, 8))

        let other = SKNode()
        other.position = CGPoint(x: 20, y: 0)
        scene.addChild(other)
        node.constraints = [.distance(SKRange(upperLimit: 10), to: CGPoint(x: 0, y: 0), in: other)]
        node.position = CGPoint(x: 30, y: 40)
        step()
        #expect(near(node.position, 22.425, 9.701))

        // A target in a scaled parent, and a node in one: each in its parent's space.
        let holder = SKNode()
        holder.setScale(2)
        holder.position = CGPoint(x: 10, y: 0)
        scene.addChild(holder)
        let held = SKNode()
        held.position = CGPoint(x: 10, y: 0)
        holder.addChild(held)
        let far = SKNode()
        far.position = CGPoint(x: 100, y: 0)
        scene.addChild(far)
        far.constraints = [.distance(SKRange(upperLimit: 5), to: held)]
        let sibling = SKNode()
        holder.addChild(sibling)
        sibling.constraints = [.distance(SKRange(lowerLimit: 20), to: held)]
        step()
        #expect(near(far.position, 35, 0))
        #expect(near(sibling.position, -10, 0))
    }

    @Test("Rotation clamped as it is, unwrapped")
    func zRotation() {
        let (scene, step) = makeScene()
        let node = SKNode()
        node.zRotation = 3
        scene.addChild(node)
        node.constraints = [.zRotation(SKRange(lowerLimit: -1, upperLimit: 1))]
        step()
        #expect(near(node.zRotation, 1))
        node.zRotation = 7
        step()
        #expect(near(node.zRotation, 1))
        node.zRotation = -4
        step()
        #expect(near(node.zRotation, -1))
    }

    @Test("Orienting toward a node or point, within an offset")
    func orient() {
        let (scene, step) = makeScene()
        let target = SKNode()
        target.position = CGPoint(x: 0, y: 10)
        scene.addChild(target)
        let node = SKNode()
        scene.addChild(node)
        let cases: [(CGFloat, SKConstraint, CGFloat)] = [
            (0, .orient(to: target, offset: SKRange(constantValue: 0)), 1.5708),
            (0.3, .orient(to: target, offset: SKRange(lowerLimit: -0.5, upperLimit: 0.5)), 1.0708),
            (0, .orient(to: target, offset: SKRange(lowerLimit: -0.5, upperLimit: 0.5)), 1.0708),
            (0, .orient(to: target, offset: SKRange(constantValue: 0.25)), 1.8208),
            (0, .orient(to: CGPoint(x: -10, y: 0), offset: SKRange(constantValue: 0)), 3.1416),
            (0, .orient(to: CGPoint(x: -10, y: 0), in: target, offset: SKRange(constantValue: 0)), 2.3562),
        ]
        for (start, constraint, expected) in cases {
            node.zRotation = start
            node.constraints = [constraint]
            step()
            #expect(near(node.zRotation, expected, 0.0001), "from \(start) to \(expected)")
        }

        // Off by more than half a turn: brought round once, no more.
        target.position = CGPoint(x: -10, y: -1)
        node.constraints = [.orient(to: target, offset: SKRange(lowerLimit: -0.5, upperLimit: 0.5))]
        for (start, expected) in [(3.0, 3.0), (3 + 2 * CGFloat.pi, 3.7413), (1.0, 2.7413)] as [(CGFloat, CGFloat)] {
            node.zRotation = start
            step()
            #expect(near(node.zRotation, expected, 0.0001), "from \(start)")
        }
        target.position = CGPoint(x: -10, y: 1)
        for start in [-3.0, -3 - 2 * CGFloat.pi] {
            node.zRotation = start
            step()
            #expect(near(node.zRotation, 2.5419, 0.0001), "from \(start)")
        }

        // In a rotated parent, toward the target as the parent sees it.
        let parent = SKNode()
        parent.position.x = 100
        parent.zRotation = .pi / 2
        scene.addChild(parent)
        let child = SKNode()
        parent.addChild(child)
        let origin = SKNode()
        scene.addChild(origin)
        child.constraints = [.orient(to: origin, offset: SKRange(constantValue: 0))]
        step()
        #expect(near(child.zRotation, 1.5708, 0.0001))
    }

    @Test("A node's constraints run in order; disabled ones are skipped")
    func order() {
        let (scene, step) = makeScene()
        let node = SKNode()
        node.position.x = 100
        scene.addChild(node)
        let atMost = SKConstraint.positionX(SKRange(upperLimit: 10))
        let atLeast = SKConstraint.positionX(SKRange(lowerLimit: 50))
        node.constraints = [atMost, atLeast]
        step()
        #expect(near(node.position.x, 50))
        node.position.x = 100
        node.constraints = [atLeast, atMost]
        step()
        #expect(near(node.position.x, 10))
        atMost.enabled = false
        node.position.x = 100
        node.constraints = [atMost]
        step()
        #expect(near(node.position.x, 100))

        let both = SKNode()
        both.position = CGPoint(x: 100, y: -100)
        scene.addChild(both)
        both.constraints = [.positionX(SKRange(upperLimit: 5), y: SKRange(lowerLimit: 7))]
        step()
        #expect(near(both.position, 5, 7))

        // An inverted range holds its lower limit.
        let inverted = SKNode()
        scene.addChild(inverted)
        inverted.constraints = [.positionX(SKRange(lowerLimit: 10, upperLimit: 0))]
        for start: CGFloat in [5, 15] {
            inverted.position.x = start
            step()
            #expect(near(inverted.position.x, 10))
        }
    }

    /// B follows A (`distance` 0 from it) while A is held at x 50 from 100:
    /// B ends at 50 if A took its turn first, at 100 if B did.
    @Test("Nodes take turns in the order they were given constraints or entered the scene")
    func turnOrder() {
        func bAfter(_ setup: (SKScene, SKNode, SKNode, () -> Void) -> Void) -> CGFloat {
            let (scene, step) = makeScene()
            let a = SKNode()
            a.position.x = 100
            let b = SKNode()
            setup(scene, a, b, step)
            step()
            return b.position.x
        }
        let holdA = { SKConstraint.positionX(SKRange(constantValue: 50)) }
        let follow = { (a: SKNode) in SKConstraint.distance(SKRange(upperLimit: 0), to: a) }

        // Set in the scene: the order set, not the tree's.
        #expect(near(bAfter { scene, a, b, _ in
            scene.addChild(b); scene.addChild(a)
            a.constraints = [holdA()]; b.constraints = [follow(a)]
        }, 50))
        #expect(near(bAfter { scene, a, b, _ in
            scene.addChild(a); scene.addChild(b)
            b.constraints = [follow(a)]; a.constraints = [holdA()]
        }, 100))
        // Set before entering: the order they enter.
        #expect(near(bAfter { scene, a, b, _ in
            b.constraints = [follow(a)]; a.constraints = [holdA()]
            scene.addChild(a); scene.addChild(b)
        }, 50))
        #expect(near(bAfter { scene, a, b, _ in
            a.constraints = [holdA()]; b.constraints = [follow(a)]
            scene.addChild(b); scene.addChild(a)
        }, 100))
        // Set again before a pass: where it first was.
        #expect(near(bAfter { scene, a, b, _ in
            scene.addChild(a); scene.addChild(b)
            a.constraints = [holdA()]; b.constraints = [follow(a)]; a.constraints = [holdA()]
        }, 50))
        // Set again after one: to the end.
        #expect(near(bAfter { scene, a, b, step in
            scene.addChild(a); scene.addChild(b)
            b.constraints = [follow(a)]; a.constraints = [holdA()]
            step(); a.position.x = 100
            b.constraints = [follow(a)]
        }, 50))
        #expect(near(bAfter { scene, a, b, _ in
            scene.addChild(a); scene.addChild(b)
            b.constraints = []; a.constraints = [holdA()]
            b.constraints?.append(follow(a))
        }, 50))
        // Out and back in: to the end.
        #expect(near(bAfter { scene, a, b, step in
            scene.addChild(a); scene.addChild(b)
            b.constraints = [follow(a)]; a.constraints = [holdA()]
            step(); a.position.x = 100
            b.removeFromParent(); scene.addChild(b)
        }, 50))
        // A subtree entering at once: tree order.
        #expect(near(bAfter { scene, a, b, _ in
            let holder = SKNode(); holder.addChild(a); holder.addChild(b)
            b.constraints = [follow(a)]; a.constraints = [holdA()]
            scene.addChild(holder)
        }, 50))
        #expect(near(bAfter { scene, a, b, _ in
            let holder = SKNode(); holder.addChild(b); holder.addChild(a)
            a.constraints = [holdA()]; b.constraints = [follow(a)]
            scene.addChild(holder)
        }, 100))
    }

    @Test("A child given constraints before its parent sees where the parent was")
    func parentAndChild() {
        func childInScene(parentFirst: Bool) -> CGFloat {
            let (scene, step) = makeScene()
            let parent = SKNode()
            parent.position.x = 100
            scene.addChild(parent)
            let child = SKNode()
            parent.addChild(child)
            let inScene = SKConstraint.positionX(SKRange(constantValue: 30))
            inScene.referenceNode = scene
            if parentFirst {
                parent.constraints = [.positionX(SKRange(constantValue: 50))]
                child.constraints = [inScene]
            } else {
                child.constraints = [inScene]
                parent.constraints = [.positionX(SKRange(constantValue: 50))]
            }
            step()
            return child.position.x
        }
        #expect(near(childInScene(parentFirst: false), -70))
        #expect(near(childInScene(parentFirst: true), -20))
    }

    @Test("SKRange's limits")
    func ranges() {
        let none = SKRange.withNoLimits()
        #expect(none.lowerLimit == -.greatestFiniteMagnitude && none.upperLimit == .greatestFiniteMagnitude)
        let upper = SKRange(upperLimit: 3)
        #expect(upper.lowerLimit == -.greatestFiniteMagnitude && upper.upperLimit == 3)
        let lower = SKRange(lowerLimit: 3)
        #expect(lower.lowerLimit == 3 && lower.upperLimit == .greatestFiniteMagnitude)
        #expect(SKNode().constraints == nil)
    }
}
