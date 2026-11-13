#if SPRITEKIT_SHIM
import Foundation

/// Renders its subtree into an offscreen texture, then draws that through
/// `shader`.
///
/// Only 11 uses, but they carry the live edge blur and the banded backdrop
/// layers, and the game depends on behaviour that is specific rather than
/// obvious (documented in AGENTS.md):
///
///   - the texture spans children that are off screen, not just the visible
///     part, so the blur band finds its buttons wherever they sit;
///   - it renders at the scene's density, not the node's, so magnifying
///     inside it does not resample;
///   - `gl_FragCoord` inside the shader is in the *texture's* space, which is
///     why a crop node around an effect node moves the band;
///   - `v_color_mix.a` carries alpha.
///
/// The renderer must reproduce those, not whatever its render-target
/// abstraction does by default.
open class SKEffectNode: SKNode {
    open var shader: SKShader?

    /// Keeps the rendered texture instead of drawing the subtree again.
    ///
    /// `BandedLayerNode` redraws one band a frame by writing `false` and
    /// then `true` here, so every write counts as "those pixels are stale"
    /// whichever way it goes — which is why the generation moves on a set
    /// rather than on a change.
    open var shouldRasterize: Bool = false {
        didSet { rasterGeneration &+= 1 }
    }

    /// Bumped on every write to `shouldRasterize`. The renderer holds a kept
    /// render target against the node and redraws it when this moves.
    public private(set) var rasterGeneration: UInt64 = 0

    open var shouldEnableEffects: Bool = true
    open var shouldCenterFilter: Bool = true
    open var blendMode: SKBlendMode = .alpha

    public override init() {
        super.init()
    }

    /// The bounds the offscreen texture must cover: the whole subtree,
    /// including children outside the viewport.
    open var effectBounds: CGRect {
        calculateAccumulatedFrame()
    }
}

/// Clips its children to `maskNode`'s shape. The collection's lists and the
/// settings card use these; never wrap a backdrop in one, which is what moves
/// an effect node's `gl_FragCoord`.
open class SKCropNode: SKNode {
    open var maskNode: SKNode?

    public override init() {
        super.init()
    }
}

#endif
