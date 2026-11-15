import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim

@Suite("Triangle meshes")
struct MeshBatchingTests {
    private func batches(_ build: (SKScene) -> Void) -> [SpriteBatcher.Batch] {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        build(scene)
        guard case let .batches(batches)? = SpriteBatcher().passes(for: DrawList(scene: scene)).first else { return [] }
        return batches
    }

    /// Two triangles over a 10-point square at the origin, the second drawn
    /// over the first, sampling the texture's lower left quarter.
    private func square() -> SKTriangleMesh {
        SKTriangleMesh(
            positions: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)],
            texCoords: [SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(0.5, 0.5), SIMD2(0, 0.5)],
            indices: [0, 1, 2, 0, 2, 3]
        )
    }

    @Test("A mesh draws its triangles through the node's transform, onto its texture's slice")
    func mesh() {
        let slice = SKTexture(rect: CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5), in: SKTexture(imageNamed: "Atlas"))
        let list = batches { scene in
            let node = SKSpriteNode(texture: slice, size: CGSize(width: 10, height: 10))
            node.position = CGPoint(x: 50, y: 30)
            node.xScale = 2
            node.alpha = 0.5
            node.triangleMesh = square()
            scene.addChild(node)
        }
        #expect(list.count == 1)
        let v = list[0].vertices, stride = SpriteBatcher.floatsPerVertex
        #expect(v.count == 4 * stride)
        #expect(list[0].indices == [0, 1, 2, 0, 2, 3])
        // Its own positions, not the quad's anchor: x = 50 + 2 × 10.
        #expect(Array(v[stride..<(stride + 4)]) == [70, 30, 0.625, 0.25])
        #expect(Array(v[(2 * stride)..<(3 * stride)]) == [70, 40, 0.625, 0.5, 1, 1, 1, 0.5, 0])
    }

    @Test("A shaded mesh samples its image's own 0…1")
    func shaded() {
        let slice = SKTexture(rect: CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5), in: SKTexture(imageNamed: "Atlas"))
        let list = batches { scene in
            let node = SKSpriteNode(texture: slice, size: CGSize(width: 10, height: 10))
            node.shader = SKShader(source: "void main() { gl_FragColor = SKDefaultShading(); }")
            node.triangleMesh = square()
            scene.addChild(node)
        }
        let v = list[0].vertices, stride = SpriteBatcher.floatsPerVertex
        #expect(Array(v[(2 * stride + 2)..<(2 * stride + 4)]) == [0.625, 0.5])
    }

    @Test("Meshes and plain sprites of one texture share a batch, in order")
    func merges() {
        let texture = SKTexture(imageNamed: "Rig")
        let list = batches { scene in
            for i in 0..<3 {
                let node = SKSpriteNode(texture: texture, size: CGSize(width: 10, height: 10))
                node.position = CGPoint(x: CGFloat(i) * 12, y: 0)
                node.zPosition = CGFloat(i)
                if i != 1 { node.triangleMesh = square() }
                scene.addChild(node)
            }
        }
        #expect(list.count == 1)
        #expect(list[0].vertices.count == 12 * SpriteBatcher.floatsPerVertex)
        #expect(list[0].indices == [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7, 8, 9, 10, 8, 10, 11])
    }

    @Test("A mesh written in place is a new picture to a rasterized node")
    func digest() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let node = SKSpriteNode(texture: SKTexture(imageNamed: "Rig"), size: CGSize(width: 10, height: 10))
        node.triangleMesh = square()
        scene.addChild(node)
        let before = DrawList(scene: scene).digest
        #expect(DrawList(scene: scene).digest == before)
        node.triangleMesh?.positions[2] = SIMD2(12, 10)
        node.triangleMesh?.touch()
        #expect(DrawList(scene: scene).digest != before)
    }
}
