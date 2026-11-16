import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim

private func scene(_ build: (SKScene) -> Void) -> DrawList {
    let scene = SKScene(size: CGSize(width: 100, height: 100))
    build(scene)
    return DrawList(scene: scene)
}

private func sprite(
    _ texture: SKTexture? = nil,
    size: CGFloat = 10,
    at point: CGPoint = .zero
) -> SKSpriteNode {
    let node = texture.map { SKSpriteNode(texture: $0, size: CGSize(width: size, height: size)) }
        ?? SKSpriteNode(color: .red, size: CGSize(width: size, height: size))
    node.position = point
    return node
}

@Suite("Batching")
struct BatchingTests {
    @Test("Sprites sharing texture, shader and blend merge into one batch")
    func merges() {
        let texture = SKTexture(imageNamed: "Brick")
        let list = scene { s in
            for i in 0 ..< 5 { s.addChild(sprite(texture, at: CGPoint(x: CGFloat(i) * 10, y: 0))) }
        }
        let passes = SpriteBatcher().passes(for: list)
        #expect(passes.count == 1)
        guard case let .batches(batches) = passes[0] else { Issue.record("expected batches"); return }
        #expect(batches.count == 1)
        #expect(batches[0].quadCount == 5)
        #expect(batches[0].vertices.count == 5 * 4 * SpriteBatcher.floatsPerVertex)
    }

    @Test("A different texture starts a new batch")
    func textureBreaks() {
        let a = SKTexture(imageNamed: "A"), b = SKTexture(imageNamed: "B")
        let list = scene { s in
            s.addChild(sprite(a)); s.addChild(sprite(b)); s.addChild(sprite(a))
        }
        guard case let .batches(batches) = SpriteBatcher().passes(for: list)[0] else {
            Issue.record("expected batches"); return
        }
        // Three, not two: order is never rearranged to merge the two As.
        #expect(batches.count == 3)
    }

    @Test("Slices of one atlas share a batch")
    func atlasSlicesMerge() {
        let atlas = SKTexture(imageNamed: "Atlas")
        let a = SKTexture(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), in: atlas)
        let b = SKTexture(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), in: atlas)
        let list = scene { s in s.addChild(sprite(a)); s.addChild(sprite(b)) }
        guard case let .batches(batches) = SpriteBatcher().passes(for: list)[0] else {
            Issue.record("expected batches"); return
        }
        #expect(batches.count == 1)
        #expect(batches[0].quadCount == 2)
    }

    @Test("A different shader starts a new batch")
    func shaderBreaks() {
        let texture = SKTexture(imageNamed: "Brick")
        let list = scene { s in
            s.addChild(sprite(texture))
            let shaded = sprite(texture)
            shaded.shader = SKShader(source: "void main() {}")
            s.addChild(shaded)
        }
        guard case let .batches(batches) = SpriteBatcher().passes(for: list)[0] else {
            Issue.record("expected batches"); return
        }
        #expect(batches.count == 2)
        #expect(batches[1].shader != nil)
    }

    @Test("A different blend mode starts a new batch")
    func blendBreaks() {
        let texture = SKTexture(imageNamed: "Brick")
        let list = scene { s in
            s.addChild(sprite(texture))
            let added = sprite(texture)
            added.blendMode = .add
            s.addChild(added)
        }
        guard case let .batches(batches) = SpriteBatcher().passes(for: list)[0] else {
            Issue.record("expected batches"); return
        }
        #expect(batches.count == 2)
        #expect(batches[1].blendMode == .add)
    }

    @Test("A sprite with its own attributes never merges")
    func attributesBreak() {
        let texture = SKTexture(imageNamed: "Brick")
        let list = scene { s in
            s.addChild(sprite(texture))
            let rigged = sprite(texture)
            rigged.setValue(SKAttributeValue(float: 1), forAttribute: "a_run")
            s.addChild(rigged)
            s.addChild(sprite(texture))
        }
        guard case let .batches(batches) = SpriteBatcher().passes(for: list)[0] else {
            Issue.record("expected batches"); return
        }
        #expect(batches.count == 3)
        #expect(batches[1].attributeValues["a_run"] != nil)
    }
}

@Suite("Vertices")
struct BatchVertexTests {
    /// Reads vertex `i`'s x and y out of a batch.
    private func point(_ batch: SpriteBatcher.Batch, _ i: Int) -> (Float, Float) {
        let base = i * SpriteBatcher.floatsPerVertex
        return (batch.vertices[base], batch.vertices[base + 1])
    }

    @Test("A centred sprite's corners straddle its position")
    func centred() {
        let list = scene { s in s.addChild(sprite(size: 10, at: CGPoint(x: 50, y: 50))) }
        guard case let .batches(batches) = SpriteBatcher().passes(for: list)[0] else {
            Issue.record("expected batches"); return
        }
        let (x0, y0) = point(batches[0], 0)
        let (x2, y2) = point(batches[0], 2)
        #expect(x0 == 45 && y0 == 45)
        #expect(x2 == 55 && y2 == 55)
    }

    @Test("An anchor point of zero puts the quad above and right of the position")
    func anchored() {
        let list = scene { s in
            let node = sprite(size: 10, at: CGPoint(x: 20, y: 20))
            node.anchorPoint = .zero
            s.addChild(node)
        }
        guard case let .batches(batches) = SpriteBatcher().passes(for: list)[0] else {
            Issue.record("expected batches"); return
        }
        let (x0, y0) = point(batches[0], 0)
        #expect(x0 == 20 && y0 == 20)
    }

    @Test("A parent's transform reaches the vertices")
    func inherited() {
        let list = scene { s in
            let group = SKNode()
            group.position = CGPoint(x: 100, y: 0)
            group.setScale(2)
            let node = sprite(size: 10)
            group.addChild(node)
            s.addChild(group)
        }
        guard case let .batches(batches) = SpriteBatcher().passes(for: list)[0] else {
            Issue.record("expected batches"); return
        }
        // 10pt wide, scaled 2x, centred at x=100 -> spans 90...110.
        let (x0, _) = point(batches[0], 0)
        let (x2, _) = point(batches[0], 2)
        #expect(x0 == 90)
        #expect(x2 == 110)
    }

    @Test("An atlas slice's UVs come from its texture rect")
    func sliceUVs() {
        let atlas = SKTexture(imageNamed: "Atlas")
        let slice = SKTexture(rect: CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.5), in: atlas)
        let list = scene { s in s.addChild(sprite(slice)) }
        guard case let .batches(batches) = SpriteBatcher().passes(for: list)[0] else {
            Issue.record("expected batches"); return
        }
        let base = SpriteBatcher.floatsPerVertex
        #expect(batches[0].vertices[2] == 0.25)   // u of vertex 0
        #expect(batches[0].vertices[3] == 0.5)    // v of vertex 0
        #expect(batches[0].vertices[base + 2] == 0.5) // u of vertex 1
    }

    @Test("v_color_mix.a carries the node's composited alpha")
    func alphaRides() {
        let list = scene { s in
            let group = SKNode()
            group.alpha = 0.5
            let node = sprite(size: 10)
            node.alpha = 0.5
            group.addChild(node)
            s.addChild(group)
        }
        guard case let .batches(batches) = SpriteBatcher().passes(for: list)[0] else {
            Issue.record("expected batches"); return
        }
        // rgba sits at offset 4..7; alpha is index 7.
        #expect(batches[0].vertices[7] == 0.25)
    }

    @Test("Two triangles a quad, wound consistently")
    func indices() {
        let list = scene { s in s.addChild(sprite()); s.addChild(sprite()) }
        guard case let .batches(batches) = SpriteBatcher().passes(for: list)[0] else {
            Issue.record("expected batches"); return
        }
        #expect(batches[0].indices == [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
    }
}

@Suite("Nested passes")
struct NestedPassTests {
    @Test("An effect node becomes its own pass around its contents")
    func effect() {
        let list = scene { s in
            s.addChild(sprite())
            let effect = SKEffectNode()
            effect.shader = SKShader(source: "void main() {}")
            for _ in 0 ..< 3 { effect.addChild(sprite()) }
            s.addChild(effect)
        }
        let passes = SpriteBatcher().passes(for: list)
        #expect(passes.count == 2)
        guard case let .effect(_, _, shader, _, _, _, _, _, _, contents) = passes[1] else {
            Issue.record("expected an effect"); return
        }
        #expect(shader != nil)
        #expect(contents.count == 1)
        #expect(passes[1].quadCount == 3)
    }

    @Test("A crop node keeps mask and contents apart")
    func crop() {
        let list = scene { s in
            let crop = SKCropNode()
            crop.maskNode = sprite(size: 50)
            crop.addChild(sprite())
            s.addChild(crop)
        }
        let passes = SpriteBatcher().passes(for: list)
        guard case let .crop(_, mask, contents) = passes[0] else {
            Issue.record("expected a crop"); return
        }
        #expect(mask.count == 1)
        #expect(contents.count == 1)
    }

    @Test("Labels and shapes break the batch so draw order survives")
    func textBreaksOrder() {
        let list = scene { s in
            s.addChild(sprite())
            let label = SKLabelNode(text: "hello")
            label.zPosition = 1
            s.addChild(label)
            let after = sprite()
            after.zPosition = 2
            s.addChild(after)
        }
        let passes = SpriteBatcher().passes(for: list)
        #expect(passes.count == 3)
        if case .label = passes[1] {} else { Issue.record("expected the label in the middle") }
    }
}

@Suite("Batches across empty crops and pass-through effects")
struct InlineTests {
    @Test("A crop with no mask doesn't break the batch, and keeps its place in the order")
    func cropWithoutMask() {
        let texture = SKTexture(imageNamed: "Brick")
        let list = scene { s in
            s.addChild(sprite(texture, at: CGPoint(x: 0, y: 0)))
            let crop = SKCropNode()
            crop.addChild(sprite(texture, at: CGPoint(x: 20, y: 0)))
            s.addChild(crop)
            s.addChild(sprite(texture, at: CGPoint(x: 40, y: 0)))
        }
        let passes = SpriteBatcher().passes(for: list)
        #expect(passes.count == 1)
        guard case let .batches(batches) = passes.first else { Issue.record("expected batches"); return }
        #expect(batches.count == 1)
        #expect(batches[0].quadCount == 3)
        // The middle quad is the crop's, where it was.
        let x = batches[0].vertices[4 * SpriteBatcher.floatsPerVertex]
        #expect(x == 15)
    }

    @Test("An effect node with no shader, cache or fade draws its children in place, carried by its transform")
    func passThroughEffect() {
        let texture = SKTexture(imageNamed: "Brick")
        let list = scene { s in
            s.addChild(sprite(texture))
            let effect = SKEffectNode()
            effect.position = CGPoint(x: 30, y: 5)
            effect.setScale(2)
            effect.addChild(sprite(texture))
            s.addChild(effect)
        }
        let passes = SpriteBatcher().passes(for: list)
        #expect(passes.count == 1)
        guard case let .batches(batches) = passes.first else { Issue.record("expected batches"); return }
        #expect(batches.count == 1)
        #expect(batches[0].quadCount == 2)
        // The effect's quad: 20 points wide round (30, 5).
        let at = 4 * SpriteBatcher.floatsPerVertex
        #expect(batches[0].vertices[at] == 20)
        #expect(batches[0].vertices[at + 1] == -5)
    }

    @Test("A cached effect node whose pixels are still good is composited without its contents")
    func freshRaster() {
        let effect = SKEffectNode()
        effect.shouldRasterize = true
        effect.addChild(sprite(SKTexture(imageNamed: "Brick")))
        let list = scene { $0.addChild(effect) }
        var batcher = SpriteBatcher()
        guard case let .effect(_, _, _, _, _, _, _, _, _, contents)? = batcher.passes(for: list).first else {
            Issue.record("expected the effect"); return
        }
        #expect(!contents.isEmpty)
        batcher.rasterIsFresh = { _, _, _ in true }
        guard case let .effect(_, _, _, _, _, _, _, _, _, kept)? = batcher.passes(for: list).first else {
            Issue.record("expected the effect"); return
        }
        #expect(kept.isEmpty)
    }
}

@Suite("Culling")
struct CullingTests {
    @Test("Sprites wholly outside the view are left out, warped ones by where their grid reaches; those touching it and effects stay")
    @MainActor func culls() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let inside = sprite(at: CGPoint(x: 50, y: 50))
        let outside = sprite(at: CGPoint(x: 300, y: 50))
        let touching = sprite(size: 20, at: CGPoint(x: 108, y: 50))
        let warped = sprite(at: CGPoint(x: -300, y: 50))
        warped.warpGeometry = SKWarpGeometryGrid(columns: 1, rows: 1)
        // Its frame lies outside, but its grid reaches in.
        let reaching = sprite(at: CGPoint(x: -20, y: 50))
        reaching.warpGeometry = SKWarpGeometryGrid(columns: 1, rows: 1)
            .replacingByDestinationPositions(positions: [SIMD2(0, 0), SIMD2(5, 0), SIMD2(0, 1), SIMD2(5, 1)])
        let effect = SKEffectNode()
        effect.shader = SKShader(source: "void main() { gl_FragColor = vec4(1.0); }")
        effect.addChild(sprite(at: CGPoint(x: 500, y: 500)))
        for node in [inside, outside, touching, warped, reaching, effect] { scene.addChild(node) }
        let all = DrawList(scene: scene, transform: .identity)
        let culled = DrawList(scene: scene, transform: .identity, culling: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(all.spriteCount == 6)
        #expect(culled.spriteCount == 4)
    }

    @Test("Inside an effect node that passes through, children cull by the view in its own space")
    @MainActor func cullsThroughPassThrough() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let effect = SKEffectNode()
        effect.position = CGPoint(x: 200, y: 0)
        effect.addChild(sprite(at: CGPoint(x: -150, y: 50)))
        effect.addChild(sprite(at: CGPoint(x: 0, y: 50)))
        scene.addChild(effect)
        let culled = DrawList(scene: scene, transform: .identity, culling: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(culled.spriteCount == 1)
    }
}

