import Foundation
import SpriteKitShim

/// An offscreen colour target: a framebuffer, the texture it draws into, and
/// an optional stencil attachment.
///
/// The renderer needs these for two things the game cannot do without —
/// `SKEffectNode`, which draws its subtree into a texture and composites that
/// through a shader, and `SKView.texture(from:)`, which the live backdrops
/// call to bake their floors.
public struct RenderTargetHandle: Equatable {
    public var framebuffer: UInt32
    public var texture: UInt32
    /// 0 when the target was made without one.
    public var stencil: UInt32
    public var width: Int
    public var height: Int

    public init(framebuffer: UInt32, texture: UInt32, stencil: UInt32, width: Int, height: Int) {
        self.framebuffer = framebuffer
        self.texture = texture
        self.stencil = stencil
        self.width = width
        self.height = height
    }

    public static let none = RenderTargetHandle(framebuffer: 0, texture: 0, stencil: 0, width: 0, height: 0)
    public var isValid: Bool { framebuffer != 0 && texture != 0 }
}

/// How a draw maps GL's `gl_FragCoord` to the one the game's shaders are
/// written against.
///
/// Two things differ, and both matter:
///
///  1. **Which way up.** SpriteKit runs on Metal, where the fragment
///     coordinate counts *down from the top left*. The game relies on it:
///     `WorldLight.fragment` is `u_fragment.xy + gl_FragCoord.xy *
///     u_fragment.zw` with `SceneLighting.view = (visible.minX, visible.maxY,
///     pixels, 0)` — a scene point only comes out of that if y runs down —
///     and `EdgeShade.Blur` writes `vec2(gl_FragCoord.x, -gl_FragCoord.y)`.
///     GLES counts up from the bottom left, so every lit shader and the edge
///     blur would be mirrored. The flip is `(0, height, 1, -1)`.
///
///  2. **Whose pixels.** Inside an `SKEffectNode` the coordinate counts the
///     *effect texture's* pixels, not the screen's — which is why AGENTS.md
///     warns that a crop node round an effect node moves the blur band, and
///     why `SceneLighting.screen` exists at all. A composite therefore draws
///     with the mapping that lands in the texture it came from, not the one
///     belonging to the framebuffer it is being drawn into.
///
/// Both are one affine map per draw, pushed as `u_sk_frag`:
///
///     sk_fragCoord.xy = offset + gl_FragCoord.xy * scale
public struct FragCoordSpace: Equatable {
    public var offsetX: Float
    public var offsetY: Float
    public var scaleX: Float
    public var scaleY: Float

    public init(offsetX: Float, offsetY: Float, scaleX: Float, scaleY: Float) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scaleX = scaleX
        self.scaleY = scaleY
    }

    public var packed: (Float, Float, Float, Float) { (offsetX, offsetY, scaleX, scaleY) }

    /// The plain case: a draw into a target `heightInPixels` tall reports its
    /// own pixels, counted down from the top left.
    public static func target(heightInPixels: Int) -> FragCoordSpace {
        FragCoordSpace(offsetX: 0, offsetY: Float(heightInPixels), scaleX: 1, scaleY: -1)
    }

    /// Where a fragment lands, for checking the maths without a context.
    public func apply(_ x: Float, _ y: Float) -> (x: Float, y: Float) {
        (offsetX + x * scaleX, offsetY + y * scaleY)
    }
}

/// The offscreen texture an `SKEffectNode`'s subtree is drawn into: how big
/// it is, what it covers, and the two coordinate mappings that go with it.
///
/// Three of the four documented `SKEffectNode` behaviours are decided here
/// rather than inherited from the framebuffer:
///
///  - **It spans children that are off screen.** `bounds` is the subtree's
///    accumulated frame, which the shim computes over every child whether or
///    not the viewport shows it — so the live edge blur finds its buttons
///    wherever they sit. Nothing clips it to the visible rect.
///  - **It renders at the scene's density, not the node's.** `density` is the
///    view's pixels per scene point, so magnifying inside the node (which is
///    exactly what `BandedLayerNode` does — a band is scaled up by
///    `pointsPerUnit` inside a cache scaled back down) does not resample.
///  - **`gl_FragCoord` is the texture's.** `composite(into:)` hands the
///    compositing draw a mapping into this texture's pixels.
public struct EffectTexture: Equatable {
    /// The subtree's frame, in the effect node's own coordinates.
    public let bounds: CGRect
    /// Pixels per scene point — the scene's, never the node's.
    public let density: CGFloat
    public let widthInPixels: Int
    public let heightInPixels: Int
    /// True when `maximumSide` forced the texture smaller than the bounds and
    /// the density asked for. The picture is then softer than SpriteKit's,
    /// which is worth saying out loud rather than letting it pass as correct.
    public let isClamped: Bool

    public init(bounds: CGRect, density: CGFloat, maximumSide: Int) {
        self.bounds = bounds
        let wanted = CGSize(
            width: (bounds.width * density).rounded(.up),
            height: (bounds.height * density).rounded(.up)
        )
        let longest = max(wanted.width, wanted.height)
        let limit = CGFloat(max(1, maximumSide))
        let shrink = longest > limit ? limit / longest : 1
        self.density = density * shrink
        isClamped = shrink < 1
        widthInPixels = max(1, Int((wanted.width * shrink).rounded(.up)))
        heightInPixels = max(1, Int((wanted.height * shrink).rounded(.up)))
    }

    /// Scene points to clip space for drawing the subtree *into* this
    /// texture. The subtree is flattened in the effect node's own
    /// coordinates, so this is just `bounds` filling the target.
    public var projection: [Float] {
        guard bounds.width > 0, bounds.height > 0 else { return Viewport.identity }
        let sx = 2 / Float(bounds.width)
        let sy = 2 / Float(bounds.height)
        return [
            sx, 0, 0, 0,
            0, sy, 0, 0,
            0, 0, -1, 0,
            -1 - Float(bounds.minX) * sx, -1 - Float(bounds.minY) * sy, 0, 1,
        ]
    }

    /// What a draw *into* this texture reports as `gl_FragCoord`.
    public var contentsSpace: FragCoordSpace {
        .target(heightInPixels: heightInPixels)
    }

    /// The mapping the compositing draw uses, so that the effect's own shader
    /// sees this texture's pixels although it is drawing into `parent`.
    ///
    /// SpriteKit gets this by running the filter pass into a second target
    /// the size of the texture and then blitting the result. Doing the same
    /// would cost a second full-texture fill and two more target switches per
    /// effect node per frame, which on a tiler is the expensive part. The
    /// composite is instead drawn straight into the parent with the
    /// coordinate remapped, which gives the same fragment values whenever the
    /// node-to-parent transform is a translation and a scale.
    ///
    /// **Where it diverges from SpriteKit**, and this is the honest list:
    ///
    ///  - A *rotated or skewed* effect node cannot be expressed by this
    ///    diagonal map. `supports(_:)` says so, and the renderer falls back
    ///    to the parent's own space with a log rather than drawing something
    ///    plausible but wrong. No effect node in this game rotates.
    ///  - A *magnified* effect node is shaded once per screen pixel here and
    ///    once per texel on SpriteKit, so it comes out sharper rather than
    ///    resampled. `BandedLayerNode` scales its cache back to 1:1, so every
    ///    effect node in this game composites at 1:1 and the two agree.
    ///
    /// - Parameters:
    ///   - transform: the effect node's transform into scene coordinates.
    ///   - visible: the scene rect the parent target shows.
    ///   - parentHeight: the parent target's height in pixels.
    public func composite(
        transform: CGAffineTransform,
        visible: CGRect,
        parentHeightInPixels: Int
    ) -> FragCoordSpace? {
        guard Self.supports(transform) else { return nil }
        guard visible.width > 0, visible.height > 0, parentHeightInPixels > 0 else { return nil }

        let scaleX = transform.a
        let scaleY = transform.d
        guard scaleX != 0, scaleY != 0 else { return nil }

        // gl_FragCoord in the parent -> scene point -> node point -> texel:
        //   sceneX = visible.minX + glx / perPoint
        //   nodeX  = (sceneX - transform.tx) / transform.a
        //   texelX = (nodeX - bounds.minX) * density
        //
        // The viewport keeps one scale for both axes in every mode but
        // `.fill`, which no scene here uses, so the height ratio is exact and
        // taking x from the same number means a non-square parent cannot
        // silently skew it.
        let perPoint = CGFloat(parentHeightInPixels) / visible.height

        let texelPerParentX = density / (scaleX * perPoint)
        let texelPerParentY = density / (scaleY * perPoint)

        let nodeOriginX = (visible.minX - transform.tx) / scaleX
        let nodeOriginY = (visible.minY - transform.ty) / scaleY

        let offsetX = Float((nodeOriginX - bounds.minX) * density)
        // The texture's own y runs down from its top, so the parent's y (up)
        // is negated on top of the offset.
        let originTexelY = (nodeOriginY - bounds.minY) * density
        let offsetY = Float(CGFloat(heightInPixels) - originTexelY)

        return FragCoordSpace(
            offsetX: offsetX,
            offsetY: offsetY,
            scaleX: Float(texelPerParentX),
            scaleY: Float(-texelPerParentY)
        )
    }

    /// Whether a transform is a translation and an axis-aligned scale, which
    /// is what `composite(transform:visible:parentHeightInPixels:)` can map.
    public static func supports(_ transform: CGAffineTransform) -> Bool {
        abs(transform.b) < 1e-6 && abs(transform.c) < 1e-6
    }
}

/// Keeps offscreen targets alive between frames.
///
/// Two kinds, and the difference is the whole reason `BandedLayerNode` works:
///
///  - **Transient.** An effect node that re-renders every frame wants a
///    target of the right size and does not care which one. These are pooled
///    by size and handed back at the end of the frame.
///  - **Kept.** An effect node with `shouldRasterize` keeps its pixels until
///    something invalidates them, so its target is held against the node's
///    identity and its contents are drawn again only when the generation or
///    the size changes. `BandedLayerNode` redraws one band a frame by
///    toggling `shouldRasterize` off and on, which bumps that generation.
public final class RenderTargetPool {
    public struct Key: Hashable {
        public var owner: ObjectIdentifier
        public init(owner: ObjectIdentifier) { self.owner = owner }
    }

    private struct Kept {
        var target: RenderTargetHandle
        var generation: UInt64
        var contents: UInt64
    }

    private let device: RenderDevice
    /// Free transient targets, by (width, height).
    private var free: [Int: [RenderTargetHandle]] = [:]
    /// Transient targets lent out this frame.
    private var lent: [RenderTargetHandle] = []
    private var kept: [Key: Kept] = [:]

    /// Targets created since the pool was made, for the frame report.
    public private(set) var createdCount = 0
    /// Targets bound this frame, which is the number that matters on a
    /// tiler: each one ends a render pass and starts another.
    public internal(set) var bindsThisFrame = 0

    public init(device: RenderDevice) {
        self.device = device
    }

    private static func sizeKey(_ width: Int, _ height: Int) -> Int {
        width << 16 | (height & 0xFFFF)
    }

    /// A target for a node that redraws every frame. Returned to the pool by
    /// `endFrame()`.
    public func transient(width: Int, height: Int, stencil: Bool) -> RenderTargetHandle? {
        let key = Self.sizeKey(width, height)
        if var bucket = free[key], let target = bucket.popLast() {
            free[key] = bucket
            lent.append(target)
            return target
        }
        guard let target = device.createRenderTarget(width: width, height: height, stencil: stencil) else {
            return nil
        }
        createdCount += 1
        lent.append(target)
        return target
    }

    /// The kept target for a rasterizing node.
    ///
    /// Returns the handle and whether its pixels are already good. A caller
    /// that is told `needsRedraw` must render into it and then call
    /// `markDrawn(_:generation:contents:)`.
    public func kept(
        for key: Key,
        width: Int,
        height: Int,
        generation: UInt64,
        contents: UInt64,
        stencil: Bool
    ) -> (target: RenderTargetHandle, needsRedraw: Bool)? {
        if let existing = kept[key] {
            if existing.target.width == width, existing.target.height == height {
                let fresh = existing.generation == generation && existing.contents == contents
                return (existing.target, !fresh)
            }
            device.deleteRenderTarget(existing.target)
            kept[key] = nil
        }
        guard let target = device.createRenderTarget(width: width, height: height, stencil: stencil) else {
            return nil
        }
        createdCount += 1
        kept[key] = Kept(target: target, generation: generation, contents: contents)
        return (target, true)
    }

    public func markDrawn(_ key: Key, generation: UInt64, contents: UInt64) {
        guard var existing = kept[key] else { return }
        existing.generation = generation
        existing.contents = contents
        kept[key] = existing
    }

    /// Hands every transient target back. Kept ones stay.
    public func endFrame() {
        for target in lent {
            free[Self.sizeKey(target.width, target.height), default: []].append(target)
        }
        lent.removeAll(keepingCapacity: true)
        bindsThisFrame = 0
    }

    /// Drops kept targets whose node was not drawn this frame, so a scene
    /// that rebuilds its bands does not leak one texture per rebuild.
    public func evictKept(except live: Set<Key>) {
        for (key, value) in kept where !live.contains(key) {
            device.deleteRenderTarget(value.target)
            kept[key] = nil
        }
    }

    public func removeAll() {
        for bucket in free.values {
            for target in bucket { device.deleteRenderTarget(target) }
        }
        for target in lent { device.deleteRenderTarget(target) }
        for value in kept.values { device.deleteRenderTarget(value.target) }
        free.removeAll()
        lent.removeAll()
        kept.removeAll()
    }

    /// Targets the pool is holding, live and free, for the frame report.
    public var residentCount: Int {
        kept.count + lent.count + free.values.reduce(0) { $0 + $1.count }
    }
}
