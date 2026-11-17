import Foundation
import Testing
@testable import SpriteKitShim

// SKScene.frame as SpriteKit gives it on a Mac (macOS 27.2): the scene's size
// placed by its anchor point, whatever its position and scale; its
// accumulated frame takes its children in too.

@Suite("Scene frame")
struct SceneFrameTests {
    @Test("The frame follows the anchor point, not position or scale")
    func frame() {
        let scene = SKScene(size: CGSize(width: 390, height: 844))
        #expect(scene.frame == CGRect(x: 0, y: 0, width: 390, height: 844))
        scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        #expect(scene.frame == CGRect(x: -195, y: -422, width: 390, height: 844))
        scene.anchorPoint = CGPoint(x: 0.25, y: 1)
        #expect(scene.frame == CGRect(x: -97.5, y: -844, width: 390, height: 844))
        scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        scene.position = CGPoint(x: 10, y: 20)
        scene.xScale = 2
        #expect(scene.frame == CGRect(x: -195, y: -422, width: 390, height: 844))
    }

    @Test("The accumulated frame takes the children in")
    func accumulated() {
        let scene = SKScene(size: CGSize(width: 390, height: 844))
        scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        scene.addChild(SKSpriteNode(color: .red, size: CGSize(width: 1000, height: 10)))
        #expect(scene.calculateAccumulatedFrame() == CGRect(x: -500, y: -422, width: 1000, height: 844))
    }

    @Test("Position and scale stay out of the accumulated frame")
    func accumulatedIgnoresTransform() {
        let scene = SKScene(size: CGSize(width: 390, height: 844))
        scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        scene.position = CGPoint(x: 10, y: 20)
        scene.xScale = 2
        scene.addChild(SKSpriteNode(color: .red, size: CGSize(width: 1000, height: 10)))
        #expect(scene.calculateAccumulatedFrame() == CGRect(x: -500, y: -422, width: 1000, height: 844))
    }

    @Test("A scene is never among its own nodes")
    func notAmongItsNodes() {
        let scene = SKScene(size: CGSize(width: 390, height: 844))
        scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let back = SKSpriteNode(color: .red, size: CGSize(width: 100, height: 100))
        back.zPosition = -1
        scene.addChild(back)
        #expect(scene.nodes(at: .zero).map { ObjectIdentifier($0) } == [ObjectIdentifier(back)])
        #expect(scene.nodes(at: CGPoint(x: 150, y: 300)).isEmpty)
        #expect(scene.atPoint(CGPoint(x: 150, y: 300)) === scene)
    }

    private func names(_ nodes: [SKNode]) -> [String] { nodes.map { $0.name ?? "?" } }

    private func box(_ name: String, at position: CGPoint, side: CGFloat = 10) -> SKSpriteNode {
        let node = SKSpriteNode(color: .red, size: CGSize(width: side, height: side))
        node.name = name
        node.position = position
        return node
    }

    @Test("A node is found where its accumulated frame is, edges closed")
    func nodesByAccumulatedFrame() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let parent = box("P", at: CGPoint(x: 20, y: 20))
        parent.addChild(box("K", at: CGPoint(x: 20, y: 0)))
        scene.addChild(parent)
        // Covered only by the child: the parent is listed too.
        #expect(names(scene.nodes(at: CGPoint(x: 40, y: 20))) == ["K", "P"])
        // A hidden child still widens its parent's frame.
        parent.children[0].isHidden = true
        #expect(names(scene.nodes(at: CGPoint(x: 40, y: 20))) == ["P"])
        parent.children[0].isHidden = false

        let group = SKNode()
        group.name = "G"
        group.position = CGPoint(x: 60, y: 60)
        group.addChild(box("A", at: CGPoint(x: -10, y: 0), side: 4))
        group.addChild(box("B", at: CGPoint(x: 10, y: 0), side: 4))
        scene.addChild(group)
        #expect(names(scene.nodes(at: CGPoint(x: 60, y: 60))) == ["G"])

        let marker = SKNode()
        marker.name = "Z"
        marker.position = CGPoint(x: 3, y: 4)
        scene.addChild(marker)
        #expect(names(scene.nodes(at: CGPoint(x: 3, y: 4))) == ["Z"])
        #expect(names(scene.nodes(at: CGPoint(x: 3.001, y: 4))).isEmpty)

        let lone = box("L", at: CGPoint(x: 80, y: 20))
        scene.addChild(lone)
        #expect(names(scene.nodes(at: CGPoint(x: 75, y: 20))) == ["L"])
        #expect(names(scene.nodes(at: CGPoint(x: 85, y: 25))) == ["L"])
        #expect(names(scene.nodes(at: CGPoint(x: 85.001, y: 20))).isEmpty)
    }

    @Test("A node is never among its own nodes")
    func receiverLeftOut() {
        let parent = box("P", at: .zero)
        parent.addChild(box("K", at: CGPoint(x: 20, y: 0)))
        #expect(parent.nodes(at: .zero).isEmpty)
        #expect(names(parent.nodes(at: CGPoint(x: 20, y: 0))) == ["K"])
        #expect(parent.atPoint(.zero) === parent)
    }

    @Test("contains(_:) is the accumulated frame's, hidden or not, far edges open")
    func containsByAccumulatedFrame() {
        let parent = box("P", at: CGPoint(x: 20, y: 20))
        #expect(parent.contains(CGPoint(x: 15, y: 15)))
        #expect(!parent.contains(CGPoint(x: 25, y: 25)))
        parent.addChild(box("K", at: CGPoint(x: 20, y: 0)))
        #expect(parent.contains(CGPoint(x: 40, y: 20)))
        parent.isHidden = true
        #expect(parent.contains(CGPoint(x: 20, y: 20)))
        let marker = SKNode()
        marker.position = CGPoint(x: 3, y: 4)
        #expect(!marker.contains(CGPoint(x: 3, y: 4)))
    }

    @Test("Setting a scene's position or scale has no effect")
    func sceneTransformIgnored() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        scene.position = CGPoint(x: 7, y: 7)
        scene.setScale(2)
        #expect(scene.position == .zero)
        #expect(scene.xScale == 1 && scene.yScale == 1)
    }
}
