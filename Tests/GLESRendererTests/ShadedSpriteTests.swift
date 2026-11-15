import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim

/// What a custom shader sees as `v_tex_coord` on a packed image.
///
/// SpriteKit hands it the texture's own 0…1, and on iOS every image of the
/// game's is a texture of its own. Android packs them into atlas pages, and
/// the shaded sprites were drawn with the page's coordinates: `CrumbleNode`
/// struck its cracks far off its brick (a plain brick in the Level
/// Designer's tool grid) and read the crack colour from a fixed row of the
/// page (vertical streaks across Starry Sky's cracked tiles).
@Suite("Shaded sprites")
@MainActor
struct ShadedSpriteTests {
    /// `BrickGarden1` as the index packs it: 64 × 80 points at (1822, 246)
    /// on a 2048 page, its top face and a sliver of its front kept when it
    /// stretches down below a raised tile.
    private static let index = try! AssetIndex(json: Data("""
    {
      "version": 2, "scale": 3,
      "pages": [{"file": "p.png", "width": 2048, "height": 2048}],
      "assets": {
        "Brick1": {"page": 0, "rect": [1822, 246, 192, 240], "size": [64, 80], "caps": [67.2, 0, 4.48, 0]},
        "Brick2": {"page": 0, "rect": [1822, 496, 192, 240], "size": [64, 80], "caps": [67.2, 0, 4.48, 0]}
      }
    }
    """.utf8))

    private func brick(_ name: String = "Brick1", height: CGFloat = 62.5, shaded: SKShader? = SKShader(source: "void main() {}")) -> SKSpriteNode {
        let node = SKSpriteNode(texture: SKTexture(imageNamed: name, in: Self.index), size: CGSize(width: 50, height: height))
        // TileNode's slice: the top cap and the foot kept, the front between them stretching.
        node.centerRect = CGRect(x: 0, y: 4.48 / 80, width: 1, height: (80 - 67.2 - 4.48) / 80)
        node.shader = shaded
        return node
    }

    private func batches(_ nodes: [SKSpriteNode]) -> [SpriteBatcher.Batch] {
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        for node in nodes { scene.addChild(node) }
        guard case let .batches(batches)? = SpriteBatcher().passes(for: DrawList(scene: scene)).first else { return [] }
        return batches
    }

    /// Every vertex's texture coordinate in a batch.
    private func uvs(_ batch: SpriteBatcher.Batch) -> [CGPoint] {
        stride(from: 0, to: batch.vertices.count, by: SpriteBatcher.floatsPerVertex).map {
            CGPoint(x: CGFloat(batch.vertices[$0 + 2]), y: CGFloat(batch.vertices[$0 + 3]))
        }
    }

    @Test("A shaded, 9-sliced packed brick sees its own image's 0…1, as SpriteKit gives it")
    func ownSpace() throws {
        for height in [62.5, 110] as [CGFloat] {
            let found = batches([brick(height: height)])
            let batch = try #require(found.first)
            #expect(found.count == 1 && batch.quadCount > 1, "drawn as one batch of its slices")
            #expect(batch.ownImage)
            let points = uvs(batch)
            #expect(abs(points.map(\.x).min()! - 0) < 1e-6 && abs(points.map(\.x).max()! - 1) < 1e-6)
            #expect(abs(points.map(\.y).min()! - 0) < 1e-6 && abs(points.map(\.y).max()! - 1) < 1e-6)
            // The top cap ends where the brick's slice says, in its own space.
            let capEdge = 1 - 67.2 / 80
            #expect(points.contains { abs($0.y - capEdge) < 1e-5 })
        }
    }

    @Test("An unshaded brick keeps its page's coordinates, batching with its page")
    func pageSpace() throws {
        let found = batches([brick(shaded: nil), brick("Brick2", shaded: nil)])
        let batch = try #require(found.first)
        #expect(found.count == 1)
        #expect(!batch.ownImage)
        let points = uvs(batch)
        #expect(abs(points.map(\.x).min()! - 1822.0 / 2048) < 1e-5)
    }

    @Test("Shaded sprites merge only when they show the same image")
    func mergesByImage() {
        let shader = SKShader(source: "void main() {}")
        // Fresh `SKTexture`s of one image merge, as `txtr` makes them.
        #expect(batches([brick(shaded: shader), brick(shaded: shader)]).count == 1)
        // Two images on one page don't: each is bound alone.
        #expect(batches([brick(shaded: shader), brick("Brick2", shaded: shader)]).count == 2)
    }

    @Test("A slice of a shaded image sees its place within that image")
    func sliceOfImage() throws {
        let image = SKTexture(imageNamed: "Brick1", in: Self.index)
        let node = SKSpriteNode(texture: SKTexture(rect: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), in: image), size: CGSize(width: 10, height: 10))
        node.shader = SKShader(source: "void main() {}")
        let points = uvs(try #require(batches([node]).first))
        #expect(abs(points.map(\.x).min()! - 0.25) < 1e-6 && abs(points.map(\.x).max()! - 0.75) < 1e-6)
        #expect(abs(points.map(\.y).min()! - 0.5) < 1e-6 && abs(points.map(\.y).max()! - 0.75) < 1e-6)
    }
}
