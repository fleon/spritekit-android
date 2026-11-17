import Foundation
import Testing
@testable import SpriteKitShim

// `run(_:) async`, pinned to SpriteKit's: each case was run on a Mac (macOS
// 27.2) through `SKRenderer`, a tenth of a second a frame.

@Suite("Actions: run(_:) async")
@MainActor
struct AsyncRunTests {
    /// Frames of a tenth of a second, letting waiting tasks run around them.
    private func frames(_ scene: SKScene, _ count: Int) async {
        for _ in 0..<count {
            for _ in 0..<5 { await Task.yield() }
            scene.tickActions(0.1)
            for _ in 0..<5 { await Task.yield() }
        }
    }

    @Test("Returns once the action has finished, not before")
    func returnsWhenDone() async {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let node = SKNode()
        scene.addChild(node)
        var log: [String] = []
        Task { @MainActor in
            await node.run(.moveBy(x: 10, y: 0, duration: 0.3))
            log.append("done at \(node.position.x)")
        }
        await frames(scene, 2)
        log.append("after 2 frames")
        await frames(scene, 3)
        #expect(log == ["after 2 frames", "done at 10.0"])

        // An instant action returns on the frame that runs it.
        var instant = false
        Task { @MainActor in
            await node.run(.run {})
            instant = true
        }
        await frames(scene, 1)
        #expect(instant)
    }

    @Test("Awaited one after another, actions play in turn")
    func inTurn() async {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let node = SKNode()
        scene.addChild(node)
        var order: [String] = []
        Task { @MainActor in
            await node.run(.wait(forDuration: 0.2))
            order.append("first")
            await node.run(.wait(forDuration: 0.2))
            order.append("second")
        }
        await frames(scene, 1)
        #expect(order == [])
        // The first wait ends on its second frame; the next starts after it.
        await frames(scene, 1)
        #expect(order == ["first"])
        await frames(scene, 1)
        #expect(order == ["first"])
        await frames(scene, 1)
        #expect(order == ["first", "second"])
    }

    @Test("Never returns for an action taken off")
    func removed() async {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let node = SKNode()
        scene.addChild(node)
        var resumed = false
        Task { @MainActor in
            await node.run(.wait(forDuration: 1))
            resumed = true
        }
        await frames(scene, 1)
        node.removeAllActions()
        await frames(scene, 15)
        #expect(!resumed)
    }
}
