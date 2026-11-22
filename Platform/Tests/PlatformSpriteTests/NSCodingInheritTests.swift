import Foundation
import Macros
import Testing
import SpriteKitShim

@NSCodingUnsupported(inherit: .size)
private final class SampleScene: SKScene {
    let marker = 1
}

@NSCodingUnsupported(inherit: .plain)
private final class SampleNode: SKNode {
    var count = 0
}

/// A family of nodes its base makes by type, as `Kind.init()`.
private class PieceNode: SKNode {
    var kind: String { "piece" }

    required override init() {
        super.init()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func make(_ type: PieceNode.Type) -> PieceNode { type.init() }
}

@NSCodingUnsupported(inherit: .requiredPlain)
private final class StonePiece: PieceNode {
    override var kind: String { "stone" }
}

/// Classes that add `init?(coder:)` keep the initializers they'd lose.
struct NSCodingInheritTests {
    @Test("A scene is made with init(size:) and a node with init()")
    func passThrough() {
        let scene = SampleScene(size: CGSize(width: 30, height: 20))
        #expect(scene.size == CGSize(width: 30, height: 20))
        #expect(scene.marker == 1)
        #expect(SampleNode().count == 0)
        #expect(PieceNode.make(StonePiece.self).kind == "stone")
    }
}
