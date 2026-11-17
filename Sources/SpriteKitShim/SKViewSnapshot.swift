#if SPRITEKIT_SHIM
import Foundation

/// `SKView.texture(from:)` — drawing a node tree off screen into a texture.
///
/// The game asks for this in 15 places and for two different reasons, and the
/// shim keeps them apart because only one of them needs real pixels:
///
/// - **Baking.** A scene draws a static layer once into a texture and then
///   shows that. These need a render target, which is the renderer's to
///   provide — it installs `SKView.snapshot`.
/// - **Priming.** A game may draw off screen for the side effect alone and
///   throw the texture away (`_ = view.texture(…)`), working round
///   SpriteKit's own buffer management: SpriteKit compiles a shader to Metal
///   on its first draw, on the main thread, and it grows an attribute buffer
///   while the GPU may still be reading it, which overruns. **Neither
///   failure mode exists here.**
///   The GLES backend owns its programs and its attribute buffers, so with no
///   `snapshot` installed these calls cost one nil and change nothing — which
///   is the correct behaviour, not a gap.
///
/// So a renderer that never installs `snapshot` still runs a scene
/// correctly; what it loses is baked layers.
extension SKView {
    /// Installed by the renderer: draws `node`'s tree, optionally cropped to
    /// `crop` in the node's own coordinates, and returns it as a texture.
    public nonisolated(unsafe) static var snapshot: ((SKView, SKNode, CGRect?) -> SKTexture?)?

    public func texture(from node: SKNode) -> SKTexture? {
        Self.snapshot?(self, node, nil)
    }

    public func texture(from node: SKNode, crop: CGRect) -> SKTexture? {
        Self.snapshot?(self, node, crop)
    }
}
#endif
