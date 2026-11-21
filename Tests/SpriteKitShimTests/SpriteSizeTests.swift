import Foundation
import Testing
@testable import SpriteKitShim

// A sprite's size as Apple's SpriteKit keeps it, measured on a Mac
// (macOS 27.2): it reads scaled, is set through the scale, and the actions
// that size a sprite work before the scale.

@Suite("A sprite's size")
@MainActor
struct SpriteSizeTests {
    private func sprite() -> SKSpriteNode {
        SKSpriteNode(color: .red, size: CGSize(width: 40, height: 20))
    }

    @Test("It reads scaled, by the scale's magnitude")
    func readsScaled() {
        let node = sprite()
        node.setScale(2)
        #expect(node.size == CGSize(width: 80, height: 40))
        #expect(node.frame.size == CGSize(width: 80, height: 40))
        node.setScale(1)
        node.xScale = -1
        #expect(node.size == CGSize(width: 40, height: 20))
        node.xScale = 0
        #expect(node.size == CGSize(width: 0, height: 20))
    }

    @Test("Set while scaled, it keeps the size before the scale")
    func setThroughScale() {
        let node = sprite()
        node.setScale(2)
        node.size = CGSize(width: 100, height: 100)
        #expect(node.size == CGSize(width: 100, height: 100))
        node.setScale(1)
        #expect(node.size == CGSize(width: 50, height: 50))
    }

    @Test("Set along an axis scaled to 0, it keeps the size as given")
    func setAtZeroScale() {
        let node = sprite()
        node.size = CGSize(width: 50, height: 50)
        node.xScale = 0
        node.size = CGSize(width: 30, height: 30)
        #expect(node.size == CGSize(width: 0, height: 30))
        node.xScale = 1
        #expect(node.size == CGSize(width: 30, height: 30))
    }

    @Test("Size over scale gives the size before it, however small the scale")
    func tinyScale() {
        let node = sprite()
        node.setScale(1e-15)
        #expect(abs(node.size.width / node.xScale - 40) < 1e-9)
        #expect(abs(node.size.height / node.yScale - 20) < 1e-9)
    }

    @Test("It's drawn at the size before the scale, the transform scaling it")
    func drawnUnscaled() {
        let node = sprite()
        node.setScale(2)
        #expect(node.contentFrame == CGRect(x: -20, y: -10, width: 40, height: 20))
    }

    @Test("setTexture(_:resize:) takes the texture's size before the scale")
    func setTextureResize() {
        let node = sprite()
        node.setScale(2)
        let texture = SKTexture(data: Data(repeating: 0, count: 10 * 10 * 4), size: CGSize(width: 10, height: 10))
        node.run(.setTexture(texture, resize: true))
        node.tickActions(0)
        #expect(node.size == CGSize(width: texture.size().width * 2, height: texture.size().height * 2))
    }
}
