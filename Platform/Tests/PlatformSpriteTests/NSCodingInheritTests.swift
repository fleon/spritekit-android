import Foundation
import Macros
import Testing
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
#endif

@NSCodingUnsupported(inherit: .size)
private final class SampleScene: SKScene {
    let marker = 1
}

@NSCodingUnsupported(inherit: .plain)
private final class SampleNode: SKNode {
    var count = 0
}

/// Classes that add `init?(coder:)` keep the initializers they'd lose.
struct NSCodingInheritTests {
    @Test("A scene is made with init(size:) and a node with init()")
    func passThrough() {
        let scene = SampleScene(size: CGSize(width: 30, height: 20))
        #expect(scene.size == CGSize(width: 30, height: 20))
        #expect(scene.marker == 1)
        #expect(SampleNode().count == 0)
    }
}
