import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim

// MARK: The fragment coordinate

@Test("A plain target flips gl_FragCoord to count down from the top left")
func fragCoordFlipsForATarget() {
    let space = FragCoordSpace.target(heightInPixels: 1000)

    // GL puts the bottom row's centre at y = 0.5; Metal — which is what the
    // game's shaders are written against — puts the *top* row's there.
    #expect(space.apply(12, 0.5).y == 999.5)
    #expect(space.apply(12, 999.5).y == 0.5)
    // x is untouched either way.
    #expect(space.apply(12, 0.5).x == 12)
}

@Test("The texture spans children off screen, not only the visible part")
func effectBoundsSpanOffscreenChildren() {
    let effect = SKEffectNode()
    let onScreen = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 10))
    onScreen.position = CGPoint(x: 5, y: 5)
    let farAway = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 10))
    farAway.position = CGPoint(x: 2000, y: 5)
    effect.addChild(onScreen)
    effect.addChild(farAway)

    // 0..2005 across: the whole subtree, however small the viewport is.
    #expect(effect.effectBounds.width == 2005)
}

@Test("A texture past the device's limit is clamped and says so")
func clampedTextureReportsItself() {
    let huge = EffectTexture(
        bounds: CGRect(x: 0, y: 0, width: 4000, height: 1000),
        density: 3, maximumSide: 4096
    )
    #expect(huge.isClamped)
    #expect(huge.widthInPixels <= 4096)
    #expect(huge.heightInPixels <= 4096)
    // The aspect is kept, so a clamped effect is soft rather than squashed.
    #expect(abs(Double(huge.widthInPixels) / Double(huge.heightInPixels) - 4) < 0.01)

    let small = EffectTexture(
        bounds: CGRect(x: 0, y: 0, width: 100, height: 50), density: 3, maximumSide: 4096
    )
    #expect(!small.isClamped)
    #expect(small.widthInPixels == 300)
}

@Test("Drawing into the texture covers exactly its bounds")
func effectProjectionCoversBounds() {
    let texture = EffectTexture(
        bounds: CGRect(x: -40, y: 10, width: 80, height: 20), density: 2, maximumSide: 4096
    )
    let m = texture.projection
    func clip(_ x: Float, _ y: Float) -> (Float, Float) {
        (m[0] * x + m[12], m[5] * y + m[13])
    }
    let bottomLeft = clip(-40, 10)
    let topRight = clip(40, 30)
    #expect(abs(bottomLeft.0 + 1) < 1e-5)
    #expect(abs(bottomLeft.1 + 1) < 1e-5)
    #expect(abs(topRight.0 - 1) < 1e-5)
    #expect(abs(topRight.1 - 1) < 1e-5)
}

// MARK: The pool

@Test("Transient targets are reused frame to frame rather than remade")
func transientTargetsAreReused() {
    let device = RecordingDevice()
    let pool = RenderTargetPool(device: device)

    _ = pool.transient(width: 128, height: 64, stencil: false)
    _ = pool.transient(width: 128, height: 64, stencil: false)
    #expect(device.createdTargets.count == 2)

    pool.endFrame()
    _ = pool.transient(width: 128, height: 64, stencil: false)
    _ = pool.transient(width: 128, height: 64, stencil: false)
    #expect(device.createdTargets.count == 2)

    // A different size is a different bucket.
    pool.endFrame()
    _ = pool.transient(width: 256, height: 64, stencil: false)
    #expect(device.createdTargets.count == 3)
}

@Test("A rasterizing node keeps its pixels until its generation moves")
func keptTargetHoldsUntilInvalidated() {
    let device = RecordingDevice()
    let pool = RenderTargetPool(device: device)
    let node = SKEffectNode()
    let key = RenderTargetPool.Key(owner: ObjectIdentifier(node))

    let first = pool.kept(for: key, width: 64, height: 64, generation: 0, contents: 7, stencil: false)
    #expect(first?.needsRedraw == true)
    pool.markDrawn(key, generation: 0, contents: 7)

    let second = pool.kept(for: key, width: 64, height: 64, generation: 0, contents: 7, stencil: false)
    #expect(second?.needsRedraw == false)
    #expect(second?.target == first?.target)
    #expect(device.createdTargets.count == 1)

    // What a layer cached in bands does to ask for a redraw.
    let third = pool.kept(for: key, width: 64, height: 64, generation: 1, contents: 7, stencil: false)
    #expect(third?.needsRedraw == true)
    #expect(third?.target == first?.target)
    #expect(device.createdTargets.count == 1)
}

@Test("A kept target is remade when the node changes size")
func keptTargetFollowsItsSize() {
    let device = RecordingDevice()
    let pool = RenderTargetPool(device: device)
    let key = RenderTargetPool.Key(owner: ObjectIdentifier(SKEffectNode()))

    _ = pool.kept(for: key, width: 64, height: 64, generation: 0, contents: 0, stencil: false)
    _ = pool.kept(for: key, width: 128, height: 64, generation: 0, contents: 0, stencil: false)
    #expect(device.createdTargets.count == 2)
    #expect(device.deletedTargets.count == 1)
}

@Test("A rasterizing node that goes away takes its target with it")
func keptTargetsAreEvicted() {
    let device = RecordingDevice()
    let pool = RenderTargetPool(device: device)
    let key = RenderTargetPool.Key(owner: ObjectIdentifier(SKEffectNode()))

    _ = pool.kept(for: key, width: 64, height: 64, generation: 0, contents: 0, stencil: false)
    pool.evictKept(except: [key])
    #expect(device.deletedTargets.isEmpty)

    pool.evictKept(except: [])
    #expect(device.deletedTargets.count == 1)
}

// MARK: The digest

@Test("A rasterized node redraws when its children move")
func digestFollowsTheContents() {
    let effect = SKEffectNode()
    effect.shouldRasterize = true
    let sprite = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 10))
    effect.addChild(sprite)

    func effectCommand(_ list: DrawList) -> DrawList.Effect? {
        for command in list.commands { if case let .effect(effect) = command { return effect } }
        return nil
    }

    let before = effectCommand(DrawList(scene: wrap(effect)))
    sprite.position = CGPoint(x: 3, y: 0)
    let after = effectCommand(DrawList(scene: wrap(effect)))

    #expect(before?.contentsDigest != after?.contentsDigest)
}

@Test("A uniform written inside a band redraws it through its generation, not its digest")
func digestIgnoresUniformValues() {
    // `u_time` running on must never redraw a band, or caching in bands would
    // cost what not caching costs; so the digest leaves uniform values out.
    // But a uniform the game writes does redraw, as on Apple's SpriteKit
    // (`RasterInvalidationTests`): a game caching in bands writes a band's
    // own uniforms only on the frame it redraws that band.
    let effect = SKEffectNode()
    effect.shouldRasterize = true
    let sprite = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 10))
    let uniform = SKUniform(name: "u_band", vectorFloat4: SIMD4(0, 0, 1, 1))
    sprite.shader = SKShader(source: "void main() {}", uniforms: [uniform])
    effect.addChild(sprite)

    func effectCommand(_ list: DrawList) -> DrawList.Effect? {
        for command in list.commands { if case let .effect(effect) = command { return effect } }
        return nil
    }

    let before = effectCommand(DrawList(scene: wrap(effect)))
    uniform.vectorFloat4Value = SIMD4(0, 0.5, 1, 1)
    let after = effectCommand(DrawList(scene: wrap(effect)))

    #expect(before?.contentsDigest == after?.contentsDigest)
    #expect(before?.rasterGeneration != after?.rasterGeneration)
}

@Test("Toggling shouldRasterize asks for a redraw, both ways round")
func rasterGenerationMovesOnEveryWrite() {
    let effect = SKEffectNode()
    let start = effect.rasterGeneration
    effect.shouldRasterize = true
    #expect(effect.rasterGeneration != start)

    // A game writes false then true; the false alone must already
    // count, since the renderer may see the list between the two.
    let afterOn = effect.rasterGeneration
    effect.shouldRasterize = false
    #expect(effect.rasterGeneration != afterOn)
    effect.shouldRasterize = true
    #expect(effect.rasterGeneration != afterOn)
}

private func wrap(_ node: SKNode) -> SKNode {
    let root = SKNode()
    if node.parent == nil { root.addChild(node) }
    return root
}

// MARK: Batching by page

@Test("Sprites on one packed page batch, whatever SKTexture objects they are")
func spritesBatchByPage() throws {
    // Every `SKTexture(imageNamed: "Brick1")` makes a fresh SKTexture, so a
    // tile map's bricks are thirty objects that all sit on one page.
    // Comparing identity put them in thirty draw calls; the shim's whole
    // reason for packing the art is that they should be one.
    let index = try AssetIndex(json: Data("""
    {"version": 2, "scale": 3,
     "pages": [{"file": "atlas-000.png", "width": 2048, "height": 2048},
               {"file": "atlas-001.png", "width": 2048, "height": 2048}],
     "assets": {
       "A": {"page": 0, "rect": [0, 0, 60, 60], "size": [20, 20]},
       "B": {"page": 0, "rect": [64, 0, 60, 60], "size": [20, 20]},
       "C": {"page": 1, "rect": [0, 0, 60, 60], "size": [20, 20]}
     }}
    """.utf8))
    // Resolved against this index, never by swapping `AssetIndex.shared`:
    // that global is process-wide and the batching suite, which runs in
    // parallel, names its textures "A" and "B" too.
    func row(_ names: [String]) -> [SpriteBatcher.Pass] {
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        for name in names {
            scene.addChild(SKSpriteNode(texture: SKTexture(imageNamed: name, in: index),
                                        size: CGSize(width: 20, height: 20)))
        }
        return SpriteBatcher().passes(for: DrawList(scene: scene))
    }

    guard case let .batches(sameePage) = row(["A", "B", "A", "B"]).first else {
        Issue.record("expected one pass"); return
    }
    #expect(sameePage.count == 1)
    #expect(sameePage[0].quadCount == 4)

    guard case let .batches(twoPages) = row(["A", "C", "A"]).first else {
        Issue.record("expected one pass"); return
    }
    #expect(twoPages.count == 3)
}

@Test("A rasterized node redraws when a shape's outline changes in place")
func digestFollowsAPathEdit() {
    // The shim's CGPath can be appended to after a shape has it, so the
    // digest reads its elements rather than trusting its identity.
    let effect = SKEffectNode()
    effect.shouldRasterize = true
    let path = CGMutablePath()
    path.move(to: .zero)
    path.addLine(to: CGPoint(x: 10, y: 0))
    let shape = SKShapeNode(path: path)
    shape.fillColor = .white
    effect.addChild(shape)

    func digest() -> UInt64? {
        let root = SKNode()
        if effect.parent == nil { root.addChild(effect) }
        for command in DrawList(scene: effect.parent ?? root).commands {
            if case let .effect(found) = command { return found.contentsDigest }
        }
        return nil
    }

    let before = digest()
    path.addLine(to: CGPoint(x: 10, y: 10))
    let after = digest()
    #expect(before != nil)
    #expect(before != after)
}
