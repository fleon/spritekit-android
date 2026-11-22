import Foundation
import Testing
@testable import SpriteKitShim

// Which node a touch goes to, as Apple's SpriteKit picks it, measured on a
// Mac (macOS 27.2, its view's `mouseDown` and Mac Catalyst's `nodes(at:)`;
// iOS's `touchesBegan` asks the same `nodeAtPoint:recursive:` and walks up
// the same way). Each scene here was built there and tapped at the same
// points; the expectations are what SpriteKit did. Setting the view's
// `ignoresSiblingOrder` changed none of them.

@Suite("Which node a touch goes to")
@MainActor
struct TouchRoutingTests {
    private final class Tap: SKSpriteNode {
        var taps = 0
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { taps += 1 }
    }

    private final class Group: SKNode {
        var taps = 0
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { taps += 1 }
    }

    private final class Narrow: SKSpriteNode {
        var taps = 0
        override func contains(_ point: CGPoint) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { taps += 1 }
    }

    private func scene() -> SKScene {
        SKScene(size: CGSize(width: 200, height: 200))
    }

    private func tap(_ name: String, at position: CGPoint, side: CGFloat = 40, z: CGFloat = 0, takes: Bool = true) -> Tap {
        let node = Tap(color: .white, size: CGSize(width: side, height: side))
        node.name = name
        node.position = position
        node.zPosition = z
        node.isUserInteractionEnabled = takes
        return node
    }

    private func group(_ name: String, at position: CGPoint, z: CGFloat = 0, takes: Bool = true) -> Group {
        let node = Group()
        node.name = name
        node.position = position
        node.zPosition = z
        node.isUserInteractionEnabled = takes
        return node
    }

    private func art(at position: CGPoint, side: CGFloat, z: CGFloat = 0) -> SKSpriteNode {
        let node = SKSpriteNode(color: .white, size: CGSize(width: side, height: side))
        node.name = "art"
        node.position = position
        node.zPosition = z
        return node
    }

    /// 100 × 100 texels, transparent but for the middle 20 × 20.
    private func paddedTexture() -> SKTexture {
        var bytes = [UInt8](repeating: 0, count: 100 * 100 * 4)
        for y in 40..<60 {
            for x in 40..<60 {
                bytes[(y * 100 + x) * 4] = 255
                bytes[(y * 100 + x) * 4 + 3] = 255
            }
        }
        return SKTexture(data: Data(bytes), size: CGSize(width: 100, height: 100))
    }

    private func target(_ scene: SKScene, _ x: CGFloat, _ y: CGFloat) -> SKNode? {
        defer { scene.cancelTouches(timestamp: 0) }
        return scene.deliverTouch(phase: .began, at: CGPoint(x: x, y: y), timestamp: 0)
    }

    private func names(_ scene: SKScene, _ x: CGFloat, _ y: CGFloat) -> [String] {
        scene.nodes(at: CGPoint(x: x, y: y)).map { $0.name ?? "-" }
    }

    @Test("The higher zPosition wins, whatever the children's order")
    func higherZ() {
        for aFirst in [false, true] {
            let scene = scene()
            let a = tap("A", at: CGPoint(x: 100, y: 100), z: 2)
            let b = tap("B", at: CGPoint(x: 120, y: 100), z: 1)
            if aFirst {
                scene.addChild(a)
                scene.addChild(b)
            } else {
                scene.addChild(b)
                scene.addChild(a)
            }
            #expect(target(scene, 110, 100) === a)
            #expect(target(scene, 130, 100) === b)
            #expect(names(scene, 110, 100) == ["A", "B"])
        }
    }

    @Test("At the same zPosition, the later child wins")
    func laterChild() {
        let scene = scene()
        let a = tap("A", at: CGPoint(x: 100, y: 100))
        let b = tap("B", at: CGPoint(x: 120, y: 100))
        scene.addChild(a)
        scene.addChild(b)
        #expect(target(scene, 110, 100) === b)
        #expect(names(scene, 110, 100) == ["B", "A"])
    }

    @Test("A sprite is hit over its whole quad, transparent texels included")
    func paddedSprite() {
        let scene = scene()
        let padded = Tap(texture: paddedTexture())
        padded.name = "Padded"
        padded.position = CGPoint(x: 100, y: 100)
        padded.zPosition = 2
        padded.isUserInteractionEnabled = true
        let neighbour = tap("Neighbour", at: CGPoint(x: 150, y: 100), z: 1)
        scene.addChild(padded)
        scene.addChild(neighbour)
        #expect(target(scene, 140, 100) === padded)
        #expect(target(scene, 160, 100) === neighbour)
    }

    @Test("What is drawn at the point comes before a frame that only holds it, whatever their zPositions")
    func drawnBeforeFrames() {
        let scene = scene()
        let holder = group("Group", at: CGPoint(x: 100, y: 100), z: 5)
        holder.addChild(art(at: CGPoint(x: -60, y: 0), side: 10))
        holder.addChild(art(at: CGPoint(x: 60, y: 0), side: 10))
        let button = tap("Button", at: CGPoint(x: 100, y: 100), side: 20, z: 1)
        scene.addChild(holder)
        scene.addChild(button)
        #expect(target(scene, 105, 100) === button)
        #expect(names(scene, 105, 100) == ["Button", "Group"])
        // Where nothing is drawn, the frame alone takes it.
        #expect(target(scene, 130, 100) === holder)
        // A plain node's own content is its position: there it counts as
        // drawn, and its zPosition wins.
        #expect(target(scene, 100, 100) === holder)
        #expect(names(scene, 100, 100) == ["Group", "Button"])
    }

    @Test("Of what is drawn, the topmost node wins even when it takes no touches, and the touch walks up from it")
    func plainNodeStopsTouches() {
        let scene = scene()
        let button = tap("Button", at: CGPoint(x: 100, y: 100), z: 1)
        scene.addChild(button)
        scene.addChild(tap("Cover", at: CGPoint(x: 100, y: 100), z: 2, takes: false))
        #expect(target(scene, 100, 100) === scene)
        #expect(button.taps == 0)

        let nested = self.scene()
        let under = tap("Button", at: CGPoint(x: 100, y: 100), z: 1)
        let panel = group("Panel", at: CGPoint(x: 100, y: 100), z: 2)
        panel.addChild(tap("Cover", at: .zero, takes: false))
        nested.addChild(under)
        nested.addChild(panel)
        #expect(target(nested, 100, 100) === panel)
        #expect(names(nested, 100, 100) == ["Cover", "Panel", "Button"])
    }

    @Test("A control is ranked by the zPosition of what it draws there, not its own")
    func drawnChildZ() {
        let scene = scene()
        let control = group("Control", at: CGPoint(x: 100, y: 100), z: 1)
        control.addChild(art(at: .zero, side: 40, z: 5))
        let other = tap("Other", at: CGPoint(x: 100, y: 100), z: 3)
        scene.addChild(control)
        scene.addChild(other)
        #expect(target(scene, 100, 100) === control)
        #expect(names(scene, 100, 100) == ["art", "Other", "Control"])

        let low = self.scene()
        let raised = group("Control", at: CGPoint(x: 100, y: 100), z: 2)
        raised.addChild(art(at: .zero, side: 80, z: -3))
        let neighbour = group("Other", at: CGPoint(x: 150, y: 100), z: 1)
        neighbour.addChild(art(at: .zero, side: 40))
        low.addChild(raised)
        low.addChild(neighbour)
        #expect(target(low, 135, 100) === neighbour)
        #expect(names(low, 135, 100) == ["art", "art", "Control", "Other"])
        #expect(target(low, 120, 100) === raised)
    }

    @Test("A child that takes touches keeps them from its parent over its own area")
    func nestedControls() {
        let scene = scene()
        let parent = tap("Parent", at: CGPoint(x: 100, y: 100), side: 60)
        let child = tap("Child", at: CGPoint(x: 10, y: 0), side: 20)
        parent.addChild(child)
        scene.addChild(parent)
        #expect(target(scene, 110, 100) === child)
        #expect(target(scene, 80, 100) === parent)
    }

    @Test("A hidden part still widens its parent's frame, below anything drawn")
    func hiddenPart() {
        let scene = scene()
        let holder = group("Group", at: CGPoint(x: 100, y: 100), z: 2)
        holder.addChild(art(at: .zero, side: 10))
        let hidden = art(at: CGPoint(x: 60, y: 0), side: 10)
        hidden.isHidden = true
        holder.addChild(hidden)
        let button = tap("Button", at: CGPoint(x: 160, y: 100), side: 20, z: 1)
        scene.addChild(holder)
        scene.addChild(button)
        #expect(target(scene, 160, 100) === button)
        #expect(names(scene, 160, 100) == ["Button", "Group"])
        #expect(target(scene, 130, 100) === holder)
    }

    @Test("A hidden or transparent node takes nothing")
    func hiddenAndClear() {
        let scene = scene()
        let under = tap("Under", at: CGPoint(x: 50, y: 100), z: 1)
        let hidden = tap("Hidden", at: CGPoint(x: 50, y: 100), z: 2)
        hidden.isHidden = true
        let under2 = tap("Under2", at: CGPoint(x: 150, y: 100), z: 1)
        let clear = tap("Clear", at: CGPoint(x: 150, y: 100), z: 2)
        clear.alpha = 0
        [under, hidden, under2, clear].forEach(scene.addChild)
        #expect(target(scene, 50, 100) === under)
        #expect(target(scene, 150, 100) === under2)
    }

    @Test("An override of contains(_:) isn't consulted")
    func containsOverride() {
        let scene = scene()
        scene.addChild(tap("Under", at: CGPoint(x: 100, y: 100), z: 1))
        let narrow = Narrow(color: .white, size: CGSize(width: 40, height: 40))
        narrow.position = CGPoint(x: 100, y: 100)
        narrow.zPosition = 2
        narrow.isUserInteractionEnabled = true
        scene.addChild(narrow)
        #expect(target(scene, 100, 100) === narrow)
    }

    @Test("A scene takes touches by default; one that doesn't lets a touch on nothing go nowhere")
    func sceneTakesTouches() {
        #expect(SKScene(size: CGSize(width: 1, height: 1)).isUserInteractionEnabled)
        #expect(SKScene().isUserInteractionEnabled)
        #expect(!SKNode().isUserInteractionEnabled)

        let scene = scene()
        #expect(target(scene, 10, 10) === scene)
        scene.isUserInteractionEnabled = false
        let a = tap("A", at: CGPoint(x: 100, y: 100))
        scene.addChild(a)
        scene.addChild(tap("Plain", at: CGPoint(x: 30, y: 30), takes: false))
        #expect(target(scene, 100, 100) === a)
        #expect(target(scene, 170, 170) == nil)
        #expect(target(scene, 30, 30) == nil)
        // A touch that went nowhere has no later phases.
        #expect(scene.deliverTouch(phase: .ended, at: CGPoint(x: 30, y: 30), timestamp: 0) == nil)
    }

    @Test("nodes(at:): drawn nodes by zPosition, then the frames that only hold the point by zPosition")
    func nodesOrder() {
        let scene = scene()
        let control = group("Control", at: CGPoint(x: 100, y: 100), z: 2, takes: false)
        let shadow = art(at: .zero, side: 80)
        shadow.name = "shadow"
        control.addChild(shadow)
        scene.addChild(control)
        scene.addChild(tap("Next", at: CGPoint(x: 150, y: 100), z: 1, takes: false))
        let gap = group("Gap", at: CGPoint(x: 150, y: 100), z: 5, takes: false)
        gap.addChild(art(at: CGPoint(x: -60, y: 0), side: 10))
        gap.addChild(art(at: CGPoint(x: 60, y: 0), side: 10))
        scene.addChild(gap)
        #expect(names(scene, 135, 100) == ["shadow", "Next", "Gap", "Control"])
        #expect(target(scene, 135, 100) === scene)
    }
}
