import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
#endif

/// SpriteKit keeps each attribute's values in one buffer per shader, at each
/// node's place among all the vertices a frame draws, and grows it when a
/// node lands past its end; but while the GPU still reads the buffer it only
/// notes the new size, and the copy runs off the end
/// (`-[SKAttributeValue copyValueTo:type:count:]`, or a corrupt heap). A
/// node drawn behind more than ever stood in front of it before (a scene
/// fading in, a busier scene) sets that off. So every shader with attributes
/// is primed before anything draws with it (`RigMeshNode.primePending` primes
/// the rigs' as they first need them).
public enum AttributeShaders {
    /// How many sprites a shader is drawn behind: enough to grow its buffers
    /// to SpriteKit's cap (1.5 times the need, at most 43,690 vertices), which
    /// no frame can pass. Set it before the first `prime`.
    public static var primingSprites = 8000

    private static let texture = SKTexture(data: Data(repeating: 0, count: 4), size: CGSize(width: 1, height: 1))
    /// The sprites the shaders draw behind, made once and kept: making and
    /// freeing thousands of them took longer than drawing them.
    private static let fillers: SKNode = {
        let root = SKNode()
        for _ in 0..<primingSprites {
            root.addChild(SKSpriteNode(texture: texture, size: CGSize(width: 1, height: 1)))
        }
        return root
    }()

    /// Draws each of `shaders` once behind `primingSprites` sprites, so their
    /// buffers never grow again. Call it on the main thread.
    public static func prime(_ shaders: [SKShader], in view: SKView) {
        guard !shaders.isEmpty else { return }
        let primed = SKNode()
        primed.zPosition = 1
        for shader in shaders {
            let sprite = SKSpriteNode(texture: texture, size: CGSize(width: 1, height: 1))
            sprite.shader = shader
            for attribute in shader.attributes {
                sprite.setValue(zero(attribute.type), forAttribute: attribute.name)
            }
            primed.addChild(sprite)
        }
        #if SPRITEKIT_SHIM
        // The shim's renderer has no such buffers: drawn alone, the shaders
        // are still built ahead, without flattening thousands of sprites.
        _ = view.texture(from: primed)
        #else
        fillers.addChild(primed)
        _ = view.texture(from: fillers)
        primed.removeFromParent()
        #endif
    }

    private static func zero(_ type: SKAttributeType) -> SKAttributeValue {
        switch type {
        case .vectorFloat2, .vectorHalfFloat2: SKAttributeValue(vectorFloat2: .zero)
        case .vectorFloat3, .vectorHalfFloat3: SKAttributeValue(vectorFloat3: .zero)
        case .vectorFloat4, .vectorHalfFloat4: SKAttributeValue(vectorFloat4: .zero)
        default: SKAttributeValue(float: 0)
        }
    }
}
