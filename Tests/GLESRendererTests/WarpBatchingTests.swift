import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim

@Suite("Warped sprites")
struct WarpBatchingTests {
    private func batches(_ build: (SKScene) -> Void) -> [SpriteBatcher.Batch] {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        build(scene)
        guard case let .batches(batches)? = SpriteBatcher().passes(for: DrawList(scene: scene)).first else { return [] }
        return batches
    }

    /// One cell whose top right corner is drawn half a width further right.
    private func leaning() -> SKWarpGeometryGrid {
        var destination = SKWarpGeometryGrid().destinationPositions
        destination[3].x = 1.5
        return SKWarpGeometryGrid(columns: 1, rows: 1,
                                  sourcePositions: SKWarpGeometryGrid().sourcePositions,
                                  destinationPositions: destination)
    }

    @Test("A warped sprite draws its mesh through its transform, anchor and texture rect")
    func mesh() {
        let atlas = SKTexture(imageNamed: "Atlas")
        let slice = SKTexture(rect: CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5), in: atlas)
        let list = batches { scene in
            let node = SKSpriteNode(texture: slice, size: CGSize(width: 20, height: 10))
            node.anchorPoint = CGPoint(x: 0.5, y: 0)
            node.position = CGPoint(x: 50, y: 30)
            node.warpGeometry = leaning()
            node.subdivisionLevels = 0
            scene.addChild(node)
        }
        #expect(list.count == 1)
        let v = list[0].vertices, stride = SpriteBatcher.floatsPerVertex
        #expect(v.count == 4 * stride)
        #expect(list[0].indices == [0, 1, 3, 0, 3, 2])
        // Bottom left, then the moved top right: x = 50 - 10 + 1.5 * 20.
        #expect(Array(v[0..<4]) == [40, 30, 0.5, 0.25])
        #expect(Array(v[(3 * stride)..<(3 * stride + 4)]) == [70, 40, 0.75, 0.75])
    }

    @Test("Subdivision follows the node's levels")
    func levels() {
        let list = batches { scene in
            let node = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
            node.warpGeometry = leaning()
            scene.addChild(node)
        }
        // The default, 2: four by four small cells.
        #expect(list[0].vertices.count == 25 * SpriteBatcher.floatsPerVertex)
        #expect(list[0].indices.count == 16 * 6)
    }

    @Test("Warped and plain sprites of one texture share a batch")
    func merges() {
        let texture = SKTexture(imageNamed: "Brick")
        let list = batches { scene in
            for i in 0..<3 {
                let node = SKSpriteNode(texture: texture, size: CGSize(width: 10, height: 10))
                node.position = CGPoint(x: CGFloat(i) * 12, y: 0)
                if i == 1 { node.warpGeometry = leaning() }
                scene.addChild(node)
            }
        }
        #expect(list.count == 1)
        #expect(list[0].vertices.count == (4 + 25 + 4) * SpriteBatcher.floatsPerVertex)
        #expect(list[0].indices.max() == UInt16(4 + 25 + 4 - 1))
    }

    @Test("A batch starts afresh before its 16-bit indices run out")
    func splits() {
        let texture = SKTexture(imageNamed: "Brick")
        // 8 × 8 cells at level 3: 65 × 65 = 4,225 vertices each.
        let grid = SKWarpGeometryGrid(columns: 8, rows: 8)
            .replacingByDestinationPositions(positions: SKWarpGeometryGrid(columns: 8, rows: 8)
                .destinationPositions.map { SIMD2($0.x + 0.1 * $0.y * $0.x, $0.y) })
        let list = batches { scene in
            for _ in 0..<20 {
                let node = SKSpriteNode(texture: texture, size: CGSize(width: 10, height: 10))
                node.warpGeometry = grid
                node.subdivisionLevels = 3
                scene.addChild(node)
            }
        }
        #expect(list.count == 2)
        for batch in list {
            #expect(batch.vertices.count / SpriteBatcher.floatsPerVertex <= 65_536)
        }
        #expect(list.reduce(0) { $0 + $1.vertices.count } == 20 * 4_225 * SpriteBatcher.floatsPerVertex)
    }
}
