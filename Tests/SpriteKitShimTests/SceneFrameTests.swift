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
}
