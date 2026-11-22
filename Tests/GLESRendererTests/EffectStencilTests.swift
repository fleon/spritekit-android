import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim

// A crop clips through the stencil of the target it draws in. A crop inside
// an offscreen picture (an effect node, or a scene a crossfade draws as one
// translucent picture) draws in that picture's target, so the target needs a
// stencil: on one without, GL passes every stencil test and the crop's
// contents draw whole (a game's gradient title, masked by its text, came out
// a solid block for the length of a crossfade).

/// A crop of a 100 × 100 sprite to a 20 × 20 mask.
private func crop() -> SKCropNode {
    let crop = SKCropNode()
    crop.maskNode = SKSpriteNode(color: .white, size: CGSize(width: 20, height: 20))
    crop.addChild(SKSpriteNode(color: .red, size: CGSize(width: 100, height: 100)))
    crop.position = CGPoint(x: 100, y: 50)
    return crop
}

/// The effect passes at the top of `passes`, in order.
private func effects(_ passes: [SpriteBatcher.Pass]) -> [[SpriteBatcher.Pass]] {
    passes.compactMap { pass in
        if case let .effect(_, _, _, _, _, _, _, _, _, contents, _) = pass { return contents }
        return nil
    }
}

@Test("A crossfade into a scene with a crop draws it in a target with a stencil")
func crossfadeKeepsCropsMasked() throws {
    let view = SKView(bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
    let outgoing = SKScene(size: CGSize(width: 200, height: 100))
    outgoing.addChild(crop())
    let incoming = SKScene(size: CGSize(width: 200, height: 100))
    incoming.addChild(crop())
    view.presentScene(outgoing)
    view.presentScene(incoming, transition: .crossFade(withDuration: 1))

    // Halfway: the outgoing scene drawn as it is, the incoming one as a
    // translucent picture, its crop inside.
    let passes = SpriteBatcher().passes(for: view.tick(currentTime: 0, delta: 0.5))
    let pictures = effects(passes)
    #expect(pictures.count == 1)
    let incomingPicture = try #require(pictures.first)
    #expect(SpriteBatcher.Pass.needStencil(incomingPicture))
    // The outgoing scene's crop draws on the view's own target, which has one.
    #expect(passes.contains { if case .crop = $0 { return true }; return false })
}

@Test("A crossfade into a scene without a crop needs no stencil")
func crossfadeWithoutCropsNeedsNoStencil() throws {
    let view = SKView(bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
    view.presentScene(SKScene(size: CGSize(width: 200, height: 100)))
    let incoming = SKScene(size: CGSize(width: 200, height: 100))
    incoming.addChild(SKSpriteNode(color: .blue, size: CGSize(width: 10, height: 10)))
    view.presentScene(incoming, transition: .crossFade(withDuration: 1))

    let incomingPicture = try #require(effects(SpriteBatcher().passes(for: view.tick(currentTime: 0, delta: 0.5))).first)
    #expect(!SpriteBatcher.Pass.needStencil(incomingPicture))
}

@Test("An effect node's crop needs its target's stencil; one in a nested effect needs the nested target's")
func effectNodeCropsNeedAStencil() throws {
    let scene = SKScene(size: CGSize(width: 200, height: 100))
    let effect = SKEffectNode()
    effect.shouldEnableEffects = true
    effect.alpha = 0.5
    effect.addChild(crop())
    scene.addChild(effect)

    let outer = SKEffectNode()
    outer.shouldEnableEffects = true
    outer.alpha = 0.5
    let inner = SKEffectNode()
    inner.shouldEnableEffects = true
    inner.alpha = 0.5
    inner.addChild(crop())
    outer.addChild(inner)
    scene.addChild(outer)

    let pictures = effects(SpriteBatcher().passes(for: DrawList(scene: scene)))
    #expect(pictures.count == 2)
    #expect(SpriteBatcher.Pass.needStencil(pictures[0]))
    // The outer effect holds only the inner one, which draws in a target of
    // its own and asks for its own stencil.
    #expect(!SpriteBatcher.Pass.needStencil(pictures[1]))
    let nested = try #require(effects(pictures[1]).first)
    #expect(SpriteBatcher.Pass.needStencil(nested))
}

@Test("A kept target is remade when its contents come to need a stencil, or no longer do")
func keptTargetFollowsItsStencil() {
    let device = RecordingDevice()
    let pool = RenderTargetPool(device: device)
    let key = RenderTargetPool.Key(owner: ObjectIdentifier(SKEffectNode()))

    let plain = pool.kept(for: key, width: 64, height: 64, generation: 0, contents: 0, stencil: false)
    #expect(plain?.target.stencil == 0)

    let stenciled = pool.kept(for: key, width: 64, height: 64, generation: 0, contents: 0, stencil: true)
    #expect(stenciled?.target.stencil != 0)
    #expect(stenciled?.needsRedraw == true)
    #expect(device.createdTargets.count == 2)
    #expect(device.deletedTargets.count == 1)

    // Asked for again as it is, it's kept.
    _ = pool.kept(for: key, width: 64, height: 64, generation: 0, contents: 0, stencil: true)
    #expect(device.createdTargets.count == 2)
}
