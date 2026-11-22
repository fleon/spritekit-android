#if SPRITEKIT_SHIM
import Foundation

/// Renders its subtree into an offscreen texture, then draws that through
/// `shader`.
///
/// Games depend on behaviour that is specific rather than obvious (a blur of
/// bands of the screen, a layer cached in bands):
///
///   - the texture spans children that are off screen, not just the visible
///     part, so a shader placing bands on the screen finds them wherever
///     they sit;
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
    /// A layer cached in bands redraws one band a frame by writing `false` and
    /// then `true` here, so every write counts as "those pixels are stale"
    /// whichever way it goes — which is why the generation moves on a set
    /// rather than on a change.
    open var shouldRasterize: Bool = false {
        didSet { rasterGeneration &+= 1 }
    }

    /// Bumped on every write to `shouldRasterize`, and when a uniform inside
    /// the node is written (`noteUniformWrite`). The renderer holds a kept
    /// render target against the node and redraws it when this moves.
    public private(set) var rasterGeneration: UInt64 = 0

    /// The latest uniform write inside this node the renderer has seen.
    private var seenUniformWrite: UInt64 = 0

    /// Called as the draw list is built, with the latest `SKUniform` write
    /// in this node's shaders and its subtree's. A later one than last time
    /// stales the cached pixels, as Apple's SpriteKit does: a uniform set
    /// (even to the value it had) redraws a rasterized node that uses it,
    /// while `u_time` running on, attribute values, or a shader's uniforms
    /// array replaced do not.
    func noteUniformWrite(_ stamp: UInt64) {
        guard stamp > seenUniformWrite else { return }
        seenUniformWrite = stamp
        rasterGeneration &+= 1
    }

    open var shouldEnableEffects: Bool = true
    /// SpriteKit's Core Image filter on the node's picture. A
    /// `CIGaussianBlur` is drawn (`blurSigma`); any other filter is kept,
    /// and the picture composites unfiltered.
    open var filter: CIFilter?
    open var shouldCenterFilter: Bool = true
    open var blendMode: SKBlendMode = .alpha

    public override init() {
        super.init()
    }

    /// The bounds the offscreen texture must cover: the whole subtree,
    /// including children outside the viewport, and as far again as a blur
    /// spreads it (`blurSigma`), so the blur is never clipped.
    open var effectBounds: CGRect {
        let contents = accumulatedContents(includingHidden: false)
        let reach = Self.blurReach(sigma: blurSigma)
        guard reach > 0, !contents.isEmpty else { return contents }
        return contents.insetBy(dx: -reach, dy: -reach)
    }

    /// The Gaussian blur's sigma, in the node's own points, that its
    /// `CIGaussianBlur` spreads the picture by (0 for none). SpriteKit
    /// blurs by half the filter's `inputRadius` in points at every display
    /// scale: sigma 6 px for a radius of 6 on a 2x Mac and 9 px on a 3x
    /// iPhone (measured, `EffectBlurTests`).
    package var blurSigma: CGFloat {
        guard shouldEnableEffects, let radius = filter?.gaussianBlurRadius else { return 0 }
        return radius / 2
    }

    /// How far past its contents a blur of `sigma` spreads a picture, and
    /// how far SpriteKit's texture reaches past them: three sigmas, past
    /// which nothing is left of a pixel at 8 bits.
    package static func blurReach(sigma: CGFloat) -> CGFloat {
        sigma > 0 ? 3 * sigma : 0
    }

    /// SKWarpable's, carried for the API: the game warps sprites only, so
    /// the renderer does not bend an effect's texture yet.
    open var warpGeometry: SKWarpGeometry?
    open var subdivisionLevels: Int = 2
}

/// Clips its children to `maskNode`'s shape. A crop node round an effect
/// node moves the effect's `gl_FragCoord`, as on Apple.
open class SKCropNode: SKNode {
    open var maskNode: SKNode?

    public override init() {
        super.init()
    }
}

#endif
