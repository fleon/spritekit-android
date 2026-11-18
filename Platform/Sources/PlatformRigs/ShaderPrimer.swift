import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
#endif

/// SpriteKit turns each shader's GLSL into Metal the first time it draws,
/// on the main thread, a millisecond or so apiece: a screen that slides in
/// with dozens of shaders it has never drawn stalls the frame it first shows
/// in. So what's built ahead draws them a few a frame while it waits, unseen:
/// each on a point under something opaque, with the frame (drawn off screen,
/// `SKView.texture(from:)` would wait for the GPU to finish the frame first).
/// Shaders with attributes are primed their own way (`AttributeShaders`) and
/// left alone.
public enum ShaderPrimer {
    /// How much GLSL, in characters, a frame turns into Metal at most (one
    /// shader at least): turning it takes about as long as it is long.
    public static var sourceBudget = 32_000

    /// Shaders drawn once, here or wherever they first showed.
    private static let primed = NSHashTable<SKShader>.weakObjects()
    private static let proxyTexture = SKTexture(data: Data(repeating: 0, count: 4), size: CGSize(width: 1, height: 1))

    /// The shaders `roots` draw with that haven't been primed here (`showing`:
    /// only those drawn now, outside hidden subtrees).
    public static func unprimed(in roots: [SKNode], showing: Bool = false) -> [SKShader] {
        var found: [SKShader] = []
        var seen = Set<ObjectIdentifier>()
        func add(_ shader: SKShader?) {
            guard let shader, shader.attributes.isEmpty, !primed.contains(shader), seen.insert(ObjectIdentifier(shader)).inserted else { return }
            found.append(shader)
        }
        func walk(_ node: SKNode) {
            guard !showing || !node.isHidden else { return }
            switch node {
            case let sprite as SKSpriteNode: add(sprite.shader)
            case let effect as SKEffectNode: add(effect.shader)
            case let emitter as SKEmitterNode: add(emitter.shader)
            default: break
            }
            for child in node.children { walk(child) }
        }
        for root in roots { walk(root) }
        return found
    }

    /// Puts the first of `shaders` in `holder` in place of the last ones,
    /// each on a sprite a point across, to draw with the coming frame: as
    /// many as `sourceBudget` characters of GLSL make. Drops them from `shaders`.
    public static func stage(_ shaders: inout [SKShader], in holder: SKNode) {
        holder.removeAllChildren()
        var length = 0
        while length < sourceBudget, !shaders.isEmpty {
            let shader = shaders.removeFirst()
            guard !primed.contains(shader) else { continue }
            primed.add(shader)
            length += shader.source?.utf16.count ?? sourceBudget
            let proxy = SKSpriteNode(texture: proxyTexture, size: CGSize(width: 1, height: 1))
            proxy.shader = shader
            holder.addChild(proxy)
        }
    }
}
