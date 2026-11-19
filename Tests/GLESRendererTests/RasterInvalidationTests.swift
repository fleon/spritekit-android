import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim

/// What makes a rasterized `SKEffectNode` draw its cached pixels again, as
/// measured on Apple's SpriteKit (an `SKRenderer` and an `SKView` on macOS,
/// reading pixels back): a probe sprite's attribute was changed along with
/// each change below, and showed only where the change redrew the cache.
@Suite("Raster invalidation")
@MainActor
struct RasterInvalidationTests {
    /// A scene with a rasterized effect node holding a shader sprite.
    private struct Rig {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let parent = SKNode()
        let effect = SKEffectNode()
        let sprite = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        let uniform = SKUniform(name: "u_value", float: 0.2)

        init() {
            effect.shouldRasterize = true
            let shader = SKShader(source: "void main() { gl_FragColor = vec4(u_value); }")
            shader.uniforms = [uniform]
            shader.attributes = [SKAttribute(name: "a_value", type: .float)]
            sprite.shader = shader
            effect.addChild(sprite)
            parent.addChild(effect)
            scene.addChild(parent)
        }
    }

    /// The cache key of every rasterized effect command, in draw order.
    private func keys(_ scene: SKScene) -> [String] {
        func walk(_ list: DrawList) -> [String] {
            list.commands.flatMap { command -> [String] in
                guard case let .effect(effect) = command else { return [] }
                let own = effect.shouldRasterize ? ["\(effect.rasterGeneration)/\(effect.contentsDigest)"] : []
                return own + walk(effect.contents)
            }
        }
        return walk(DrawList(scene: scene))
    }

    /// Whether `change` stales the rig's cached pixels.
    private func redraws(_ rig: Rig = Rig(), _ change: (Rig) -> Void) -> Bool {
        let before = keys(rig.scene)
        change(rig)
        return keys(rig.scene) != before
    }

    @Test("Nothing changed, or only time passed: the cache holds (u_time running on never redraws)")
    func holds() {
        let rig = Rig()
        let first = keys(rig.scene)
        #expect(keys(rig.scene) == first)
        #expect(keys(rig.scene) == first)
    }

    @Test("A uniform written on a descendant's shader redraws, the same value too")
    func descendantUniform() {
        #expect(redraws { $0.uniform.floatValue = 0.8 })
        #expect(redraws { $0.uniform.floatValue = $0.uniform.floatValue })
        #expect(redraws { $0.uniform.vectorFloat4Value = SIMD4(1, 0, 0, 1) })
        #expect(redraws { $0.uniform.textureValue = SKTexture(imageNamed: "Brick") })
    }

    @Test("A uniform written on the effect node's own shader redraws")
    func ownUniform() {
        let rig = Rig()
        let own = SKUniform(name: "u_own", float: 0.2)
        let shader = SKShader(source: "void main() { gl_FragColor = texture2D(u_texture, v_tex_coord) * u_own; }")
        shader.uniforms = [own]
        rig.effect.shader = shader
        _ = keys(rig.scene)
        #expect(redraws(rig) { _ in own.floatValue = 0.5 })
    }

    @Test("One SKUniform shared by two cached nodes redraws both")
    func sharedUniform() {
        let rig = Rig()
        let second = SKEffectNode()
        second.shouldRasterize = true
        let sprite = SKSpriteNode(color: .blue, size: CGSize(width: 10, height: 10))
        let shader = SKShader(source: "void main() { gl_FragColor = vec4(u_value); }")
        shader.uniforms = [rig.uniform]
        sprite.shader = shader
        second.addChild(sprite)
        rig.scene.addChild(second)
        let before = keys(rig.scene)
        rig.uniform.floatValue = 0.8
        let after = keys(rig.scene)
        #expect(before.count == 2)
        #expect(zip(before, after).allSatisfy { $0 != $1 })
    }

    @Test("A uniform written inside a nested effect node redraws the outer cached one")
    func nestedUniform() {
        let rig = Rig()
        let inner = SKEffectNode()
        let sprite = SKSpriteNode(color: .blue, size: CGSize(width: 10, height: 10))
        let uniform = SKUniform(name: "u_inner", float: 0)
        let shader = SKShader(source: "void main() { gl_FragColor = vec4(u_inner); }")
        shader.uniforms = [uniform]
        sprite.shader = shader
        inner.addChild(sprite)
        rig.effect.addChild(inner)
        _ = keys(rig.scene)
        #expect(redraws(rig) { _ in uniform.floatValue = 1 })
    }

    @Test("A uniform on a shape's fill shader inside redraws")
    func shapeUniform() {
        let rig = Rig()
        let shape = SKShapeNode(rect: CGRect(x: 0, y: 0, width: 8, height: 8))
        let uniform = SKUniform(name: "u_fill", float: 0)
        let shader = SKShader(source: "void main() { gl_FragColor = vec4(u_fill); }")
        shader.uniforms = [uniform]
        shape.fillShader = shader
        rig.effect.addChild(shape)
        _ = keys(rig.scene)
        #expect(redraws(rig) { _ in uniform.floatValue = 1 })
    }

    @Test("What Apple keeps the cache through: attribute values, a uniforms array replaced or added to, a uniform outside")
    func keeps() {
        #expect(!redraws { $0.sprite.setValue(SKAttributeValue(float: 0.8), forAttribute: "a_value") })
        #expect(!redraws { $0.sprite.shader?.uniforms = [SKUniform(name: "u_value", float: 0.8)] })
        #expect(!redraws { $0.sprite.shader?.addUniform(SKUniform(name: "u_extra", float: 0.8)) })
        // A uniform written outside the node, once the scene has settled.
        let rig = Rig()
        let outside = SKSpriteNode(color: .blue, size: CGSize(width: 4, height: 4))
        let uniform = SKUniform(name: "u_out", float: 0)
        let shader = SKShader(source: "void main() { gl_FragColor = vec4(u_out); }")
        shader.uniforms = [uniform]
        outside.shader = shader
        rig.scene.addChild(outside)
        _ = keys(rig.scene)
        #expect(!redraws(rig) { _ in uniform.floatValue = 1 })
    }

    @Test("An ancestor moving only moves the cached picture")
    func ancestorMoves() {
        #expect(!redraws { $0.parent.position.x += 1 })
        #expect(!redraws { $0.parent.alpha = 0.5 })
    }

    @Test("The node's own position, scale, alpha or shader redraws it")
    func ownChanges() {
        #expect(redraws { $0.effect.position.x += 1 })
        #expect(redraws { $0.effect.xScale = 1.01 })
        #expect(redraws { $0.effect.alpha = 0.9 })
        #expect(redraws { $0.effect.shader = SKShader(source: "void main() { gl_FragColor = texture2D(u_texture, v_tex_coord); }") })
    }

    @Test("A child's change redraws, as does writing shouldRasterize")
    func childChanges() {
        #expect(redraws { $0.sprite.position.y += 8 })
        #expect(redraws { $0.sprite.color = .blue })
        #expect(redraws { $0.effect.addChild(SKSpriteNode(color: .green, size: CGSize(width: 2, height: 2))) })
        #expect(redraws { $0.effect.shouldRasterize = true })
    }

    @Test("A cached band redraws alone when only its own uniforms are written")
    func bandsCopyUniforms() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        var uniforms: [SKUniform] = []
        for index in 0..<4 {
            let band = SKEffectNode()
            band.shouldRasterize = true
            let sprite = SKSpriteNode(color: .red, size: CGSize(width: 100, height: 25))
            sprite.position = CGPoint(x: 50, y: 12.5 + CGFloat(index) * 25)
            let uniform = SKUniform(name: "u_time_band", float: 0)
            let shader = SKShader(source: "void main() { gl_FragColor = vec4(u_time_band); }")
            shader.uniforms = [uniform]
            sprite.shader = shader
            band.addChild(sprite)
            scene.addChild(band)
            uniforms.append(uniform)
        }
        let before = keys(scene)
        uniforms[2].floatValue = 1
        let after = keys(scene)
        #expect(zip(before, after).map { $0 != $1 } == [false, false, true, false])
    }
}
