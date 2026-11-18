import Foundation
import Testing
@testable import SpriteKitShim

// Members games call with SpriteKit's and UIKit's own spelling, each as
// Apple's behaves (the scene's size and the row order measured on a Mac,
// macOS 27.2).

@MainActor
private final class SizedScene: SKScene {
    override init() { super.init(size: CGSize(width: 320, height: 568)) }
}

@MainActor
private final class FrameOrderScene: SKScene {
    var log: [String] = []
    override func update(_ currentTime: TimeInterval) { log.append("update") }
    override func didEvaluateActions() { log.append("actions") }
    override func didApplyConstraints() { log.append("constraints") }
    override func didFinishUpdate() { log.append("finish") }
}

@Suite("Apple's members")
@MainActor
struct AppleMembersTests {
    @Test("SKScene() is 1 × 1, and a subclass can override init() with its own size")
    func sceneInit() {
        #expect(SKScene().size == CGSize(width: 1, height: 1))
        #expect(SizedScene().size == CGSize(width: 320, height: 568))
    }

    @Test("A frame's callbacks come in SpriteKit's order")
    func frameCallbacks() {
        let scene = FrameOrderScene(size: CGSize(width: 10, height: 10))
        let renderer = SKRenderer(device: MTLDevice())
        renderer.scene = scene
        renderer.update(atTime: 1)
        #expect(scene.log == ["update", "actions", "constraints", "finish"])
    }

    @Test("SKTexture(data:size:flipped:) takes the first row as the top")
    func flippedData() {
        // A 1 × 2 texture: red then blue in the data.
        let rows = Data([255, 0, 0, 255, 0, 0, 255, 255])
        let size = CGSize(width: 1, height: 2)
        guard case let .data(plain) = SKTexture(data: rows, size: size, flipped: false).source,
              case let .data(flipped) = SKTexture(data: rows, size: size, flipped: true).source
        else {
            Issue.record("raw pixel data must stay `.data`"); return
        }
        // Stored bottom row first: unflipped the red row is the bottom,
        // flipped the blue one is.
        #expect(plain == rows)
        #expect(flipped == Data([0, 0, 255, 255, 255, 0, 0, 255]))
    }

    @Test("SKAction.scaleX(to:y:duration:) scales both axes")
    func scaleXY() {
        let scene = SKScene(size: CGSize(width: 10, height: 10))
        let renderer = SKRenderer(device: MTLDevice())
        renderer.scene = scene
        let node = SKNode()
        scene.addChild(node)
        node.run(.scaleX(to: 0, y: 2, duration: 0.5))
        for time in 0 ... 3 { renderer.update(atTime: TimeInterval(time)) }
        #expect(node.xScale == 0 && node.yScale == 2, "\(node.xScale) \(node.yScale)")
    }

    @Test("UIView carries contentScaleFactor, as every UIKit view does")
    func contentScale() {
        let view: UIView = SKView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        view.contentScaleFactor = 2.75
        #expect(view.contentScaleFactor == 2.75)
    }

    @Test("getWhite converts a grey and refuses any other colour")
    func getWhite() {
        var white: CGFloat = -1, alpha: CGFloat = -1
        #expect(SKColor.white.getWhite(&white, alpha: &alpha) && white == 1 && alpha == 1)
        #expect(SKColor(white: 0.25, alpha: 0.5).getWhite(&white, alpha: &alpha) && white == 0.25 && alpha == 0.5)
        #expect(!SKColor(red: 1, green: 0.5, blue: 0, alpha: 1).getWhite(&white, alpha: &alpha))
    }
}
