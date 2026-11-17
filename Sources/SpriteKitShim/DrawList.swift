#if SPRITEKIT_SHIM
import Foundation

/// What one frame of a scene graph flattens to: the handover between the
/// shim and the GLES 3 renderer.
///
/// Keeping this a plain value — rather than having nodes issue GL calls —
/// means the whole scene graph, the action system and the draw order are
/// testable on the host with no device, no context and no window, which is
/// how this layer can be built before the Android app shell exists.
public struct DrawList {
    public enum Command {
        case sprite(Sprite)
        case shape(Shape)
        case label(Label)
        /// Draw `contents` into an offscreen texture covering `bounds`, then
        /// composite it through `shader`.
        case effect(Effect)
        /// Draw `contents` clipped to `mask`.
        case crop(Crop)
    }

    public struct Sprite {
        public var transform: CGAffineTransform
        public var size: CGSize
        public var anchorPoint: CGPoint
        public var texture: SKTexture?
        public var textureRect: CGRect
        public var color: SKColor
        public var colorBlendFactor: CGFloat
        public var alpha: CGFloat
        public var blendMode: SKBlendMode
        public var shader: SKShader?
        public var attributeValues: [String: SKAttributeValue]

        public init(
            transform: CGAffineTransform,
            size: CGSize,
            anchorPoint: CGPoint,
            texture: SKTexture?,
            textureRect: CGRect,
            color: SKColor,
            colorBlendFactor: CGFloat,
            alpha: CGFloat,
            blendMode: SKBlendMode,
            shader: SKShader?,
            attributeValues: [String: SKAttributeValue]
        ) {
            self.transform = transform
            self.size = size
            self.anchorPoint = anchorPoint
            self.texture = texture
            self.textureRect = textureRect
            self.color = color
            self.colorBlendFactor = colorBlendFactor
            self.alpha = alpha
            self.blendMode = blendMode
            self.shader = shader
            self.attributeValues = attributeValues
        }
        /// The node's warp grid, if it bends its picture (SKWarpGeometry):
        /// the renderer draws it as `WarpMesh` rather than one quad.
        public var warp: SKWarpGeometryGrid? = nil
        public var subdivisionLevels: Int = 2
        /// The node's triangles, if it draws a mesh rather than its quad
        /// (`SKSpriteNode.triangleMesh`).
        public var mesh: SKTriangleMesh? = nil
    }

    public struct Shape {
        public var transform: CGAffineTransform
        public var path: CGPath?
        public var fillColor: SKColor
        public var strokeColor: SKColor
        public var lineWidth: CGFloat
        public var lineCap: CGLineCap
        public var lineJoin: CGLineJoin
        public var alpha: CGFloat
        /// The fill's and the stroke's textures, each stretched over the
        /// path's bounds and tinted by its colour.
        public var fillTexture: SKTexture? = nil
        public var strokeTexture: SKTexture? = nil
    }

    public struct Label {
        public var transform: CGAffineTransform
        public var text: String
        public var fontName: String?
        public var fontSize: CGFloat
        public var color: SKColor
        public var horizontal: SKLabelHorizontalAlignmentMode
        public var vertical: SKLabelVerticalAlignmentMode
        public var alpha: CGFloat
        /// The lines as the node broke and placed them, so the renderer
        /// draws exactly what was measured. Nil when no `TextProvider` is
        /// registered, which is the renderer's cue that there is nothing to
        /// draw rather than a reason to measure the string itself.
        public var layout: TextLayout?
        /// Extra space after each character, in points (an attributed
        /// label's `.kern`), which `layout` has already counted.
        public var kern: CGFloat = 0
    }

    public struct Effect {
        public var bounds: CGRect
        public var transform: CGAffineTransform
        public var shader: SKShader?
        public var alpha: CGFloat
        public var blendMode: SKBlendMode
        /// The node keeps its rendered pixels until something invalidates
        /// them. A layer cached in bands is built on it: twelve bands, one
        /// redrawn a frame, so a frame pays for a twelfth of the shader.
        public var shouldRasterize: Bool
        /// Which node this is, so the renderer can hold a kept target
        /// against it across frames. Identity, never a strong reference.
        public var owner: ObjectIdentifier
        /// Bumped whenever `shouldRasterize` is written — which is exactly
        /// how a game asks for a redraw (`false` then `true`).
        public var rasterGeneration: UInt64
        /// A digest of what the subtree draws this frame: transforms, sizes,
        /// colours, alphas, texture and shader identity. A rasterized node
        /// whose children moved redraws; one whose shader uniforms merely
        /// changed does not, which is what keeps a band cached while
        /// `u_time` runs on.
        public var contentsDigest: UInt64
        public var contents: DrawList
    }

    public struct Crop {
        public var transform: CGAffineTransform
        public var mask: DrawList
        public var contents: DrawList
    }

    public var commands: [Command] = []

    public init() {}

    /// Flattens a subtree in SpriteKit's draw order, as the game's view sets
    /// it: `ignoresSiblingOrder = true`.
    ///
    /// That orders **every** node in the scene by its accumulated zPosition,
    /// globally — a grandchild can draw between two of a cousin's
    /// descendants. A tile map may depend on it: walls in one layer and
    /// tiles in another, both at z 0, and only their own row-based z puts a
    /// wall in front over the tiles behind it. Sorting each subtree as a
    /// block would draw every wall under every tile.
    ///
    /// Ties are nondeterministic in SpriteKit, which is why the game sets
    /// explicit z for overlapping siblings. This sorts stably, so ties fall
    /// in tree order: strictly more deterministic than SpriteKit, never less.
    ///
    /// Effect and crop nodes are the exception, as they are in SpriteKit:
    /// each composites its subtree as one picture, so it is one command at
    /// its own depth, with its contents ordered the same way inside it.
    @MainActor public init(scene: SKNode) {
        self.init(scene: scene, transform: .identity)
    }

    /// The same, drawn through `transform`: how the view puts a scene behind
    /// its camera (`SKScene.cameraTransform`).
    ///
    /// With `culling`, the rect the view shows in the list's coordinates
    /// (`SKView.shouldCullNonVisibleNodes`), a sprite whose quad lies wholly
    /// outside it is left out: its fragments would all be clipped, so the
    /// picture can't change. Quads are culled by their frame, warped sprites
    /// by where their grid reaches (which can be past their frame); effect
    /// and crop nodes, labels and shapes are kept whole.
    @MainActor public init(scene: SKNode, transform: CGAffineTransform, culling: CGRect? = nil) {
        var entries: [(CGFloat, Command)] = []
        let cull = culling.map { $0.insetBy(dx: -Self.cullMargin, dy: -Self.cullMargin) }
        DrawList.collect(scene, parentTransform: transform, parentAlpha: 1, parentZ: 0, cull: cull, into: &entries)
        commands = DrawList.ordered(entries)
    }

    /// Points kept round the culling rect, so rounding never drops a quad
    /// that touches its edge.
    static let cullMargin: CGFloat = 2

    /// Whether a quad of `size` anchored at `anchor`, carried by `transform`,
    /// lies wholly outside `cull`.
    static func isCulled(size: CGSize, anchor: CGPoint, transform t: CGAffineTransform, by cull: CGRect) -> Bool {
        let x0 = -size.width * anchor.x, y0 = -size.height * anchor.y
        let x1 = x0 + size.width, y1 = y0 + size.height
        let xs = (t.a * x0 + t.c * y0, t.a * x1 + t.c * y0, t.a * x1 + t.c * y1, t.a * x0 + t.c * y1)
        let ys = (t.b * x0 + t.d * y0, t.b * x1 + t.d * y0, t.b * x1 + t.d * y1, t.b * x0 + t.d * y1)
        let minX = min(min(xs.0, xs.1), min(xs.2, xs.3)) + t.tx
        let maxX = max(max(xs.0, xs.1), max(xs.2, xs.3)) + t.tx
        let minY = min(min(ys.0, ys.1), min(ys.2, ys.3)) + t.ty
        let maxY = max(max(ys.0, ys.1), max(ys.2, ys.3)) + t.ty
        return maxX < cull.minX || minX > cull.maxX || maxY < cull.minY || minY > cull.maxY
    }

    /// A sprite command the cull rect leaves out.
    static func isCulled(_ sprite: Sprite, by cull: CGRect?) -> Bool {
        guard let cull else { return false }
        guard let grid = sprite.warp else {
            return isCulled(size: sprite.size, anchor: sprite.anchorPoint, transform: sprite.transform, by: cull)
        }
        // The grid's reach as a quad of its own in the sprite's space.
        let (low, high) = WarpMesh.bounds(of: grid)
        let size = CGSize(width: sprite.size.width * CGFloat(high.x - low.x), height: sprite.size.height * CGFloat(high.y - low.y))
        let origin = CGPoint(x: sprite.size.width * (CGFloat(low.x) - sprite.anchorPoint.x),
                             y: sprite.size.height * (CGFloat(low.y) - sprite.anchorPoint.y))
        return isCulled(size: size, anchor: .zero, transform: sprite.transform.translatedBy(x: origin.x, y: origin.y), by: cull)
    }

    /// Stable sort by accumulated z: ties keep tree order.
    /// The commands are big, so their places are sorted rather than they
    /// are, and not at all when the depths already rise in tree order.
    private static func ordered(_ entries: [(CGFloat, Command)]) -> [Command] {
        var inOrder = true
        var index = 1
        while index < entries.count {
            if entries[index].0 < entries[index - 1].0 {
                inOrder = false
                break
            }
            index += 1
        }
        if inOrder { return entries.map(\.1) }
        var places = [(z: CGFloat, offset: Int)]()
        places.reserveCapacity(entries.count)
        for (offset, entry) in entries.enumerated() { places.append((entry.0, offset)) }
        places.sort { $0.z == $1.z ? $0.offset < $1.offset : $0.z < $1.z }
        return places.map { entries[$0.offset].1 }
    }

    /// Every command under `node`, each with its **own** accumulated z, in
    /// tree order and unsorted — sorting happens once, over the whole list.
    /// Appended to one list for the whole walk: returning a list from each
    /// node copied every command once for each level above it.
    @MainActor private static func collect(
        _ node: SKNode,
        parentTransform: CGAffineTransform,
        parentAlpha: CGFloat,
        parentZ: CGFloat,
        cull: CGRect? = nil,
        into entries: inout [(CGFloat, Command)]
    ) {
        guard !node.isHidden, node.alpha > 0 else { return }

        let transform = node.localTransform.concatenating(parentTransform)
        let alpha = node.alpha * parentAlpha
        let z = parentZ + node.zPosition

        // An effect or crop node composites its whole subtree, so it is one
        // command at its own depth rather than a set of siblings.
        if let effect = node as? SKEffectNode, effect.shouldEnableEffects {
            // Ordered before it is digested: draw order is part of what a
            // rasterized node's cached pixels depend on.
            // One that composites to its children drawn in place (no shader,
            // cache or fade) has no texture of its own to fill, so its
            // contents cull as the rest of the scene does, by the view's
            // rect in its own space. One that does fill a texture keeps
            // every child: its texture spans the off-screen ones too.
            var inner: CGRect?
            if let cull, effect.shader == nil, !effect.shouldRasterize, alpha >= 0.999,
               transform.a * transform.d - transform.b * transform.c != 0 {
                inner = cull.applying(transform.inverted())
            }
            let contents = wrap(ordered(children(of: node, transform: .identity, alpha: 1, z: 0, cull: inner)))
            entries.append((z, Command.effect(Effect(
                bounds: effect.effectBounds,
                transform: transform,
                shader: effect.shader,
                alpha: alpha,
                blendMode: effect.blendMode,
                shouldRasterize: effect.shouldRasterize,
                owner: ObjectIdentifier(effect),
                rasterGeneration: effect.rasterGeneration,
                contentsDigest: effect.shouldRasterize ? contents.digest : 0,
                contents: contents
            ))))
            return
        }

        if let crop = node as? SKCropNode {
            // The mask node itself draws the shape, so collect it, not just
            // its children — a solid sprite mask has none.
            // Both in the crop node's own space, carried by its transform:
            // the renderer draws a crop's mask and contents where they
            // stand, through the stencil, with no composite of its own to
            // put them back in place.
            var mask: [(CGFloat, Command)] = []
            if let maskNode = crop.maskNode {
                collect(maskNode, parentTransform: transform, parentAlpha: 1, parentZ: 0, into: &mask)
            }
            let contents = children(of: node, transform: transform, alpha: alpha, z: 0, cull: cull)
            entries.append((z, Command.crop(Crop(
                transform: transform,
                mask: wrap(ordered(mask)),
                contents: wrap(ordered(contents))
            ))))
            return
        }

        if let sprite = node as? SKSpriteNode, sprite.size != .zero {
            // A 9-sliced sprite becomes nine ordinary sprite commands, each
            // with its own frame and sub-rect, so corners keep their size
            // while the edges and middle stretch (see NineSlice.swift).
            // SpriteKit slices for the node's scale too: a 9-sliced fill
            // scaled down to a sliver keeps its round caps (a meter showing
            // a small fraction). So the node's own scale goes into the
            // patches' sizes rather than the transform (unrotated nodes; a
            // rotated one keeps its scale in the transform).
            let foldsScale = sprite.isSliced && sprite.zRotation == 0 && (sprite.xScale != 1 || sprite.yScale != 1)
            let pieces = slices(of: sprite, scale: foldsScale ? CGSize(width: abs(sprite.xScale), height: abs(sprite.yScale)) : CGSize(width: 1, height: 1))
            let pieceTransform = foldsScale
                ? CGAffineTransform(scaleX: sprite.xScale < 0 ? -1 : 1, y: sprite.yScale < 0 ? -1 : 1)
                    .concatenating(CGAffineTransform(translationX: sprite.position.x, y: sprite.position.y))
                    .concatenating(parentTransform)
                : transform
            for piece in pieces {
                var command = Sprite(
                    transform: pieceTransform,
                    size: piece.size,
                    anchorPoint: piece.anchorPoint,
                    texture: sprite.texture,
                    textureRect: piece.textureRect,
                    color: sprite.color,
                    // SpriteKit draws an untextured sprite in its colour
                    // whatever its blend factor says.
                    colorBlendFactor: sprite.texture == nil ? 1 : sprite.colorBlendFactor,
                    // ...and its colour's alpha with it (a clear one draws
                    // nothing), which a textured sprite's tint never carries.
                    alpha: sprite.texture == nil ? alpha * sprite.color.alpha : alpha,
                    blendMode: sprite.blendMode,
                    shader: sprite.shader,
                    attributeValues: sprite.attributeValues
                )
                if pieces.count == 1, let grid = sprite.warpGeometry as? SKWarpGeometryGrid {
                    command.warp = grid
                    command.subdivisionLevels = sprite.subdivisionLevels
                }
                // A mesh's frame bounds it (`SKTriangleMesh`), so it culls as a quad.
                if pieces.count == 1, let mesh = sprite.triangleMesh { command.mesh = mesh }
                if isCulled(command, by: cull) { continue }
                entries.append((z, .sprite(command)))
            }
        } else if let shape = node as? SKShapeNode {
            entries.append((z, .shape(Shape(
                transform: transform,
                path: shape.path,
                fillColor: shape.fillColor,
                strokeColor: shape.strokeColor,
                lineWidth: shape.lineWidth,
                lineCap: shape.lineCap,
                lineJoin: shape.lineJoin,
                alpha: alpha,
                fillTexture: shape.fillTexture,
                strokeTexture: shape.strokeTexture
            ))))
        } else if let label = node as? SKLabelNode, let layout = label.layout, let runs = label.laidOutRuns,
                  layout.lines.count == runs.count {
            // An attributed label in several styles: each run a label of its
            // own, placed where the line's layout put it.
            for (run, placed) in zip(runs, layout.lines) {
                entries.append((z, .label(Label(
                    transform: transform,
                    text: run.text,
                    fontName: run.fontName,
                    fontSize: run.fontSize,
                    color: run.color ?? .white,
                    horizontal: .left,
                    vertical: .baseline,
                    alpha: alpha,
                    layout: TextLayout(lines: [placed], bounds: layout.bounds),
                    kern: run.kern
                ))))
            }
        } else if let label = node as? SKLabelNode, let text = label.text, !text.isEmpty {
            entries.append((z, .label(Label(
                transform: transform,
                text: text,
                fontName: label.fontName,
                fontSize: label.fontSize,
                color: label.fontColor ?? .white,
                horizontal: label.horizontalAlignmentMode,
                vertical: label.verticalAlignmentMode,
                alpha: alpha,
                layout: label.layout,
                kern: label.kern
            ))))
        } else if let emitter = node as? SKEmitterNode {
            // Its particles, one sprite each, at its own depth.
            for entry in emitter.particleCommands(transform: transform, alpha: alpha, z: z) {
                if cull != nil, case let .sprite(particle) = entry.1, isCulled(particle, by: cull) { continue }
                entries.append(entry)
            }
        } else if let tileMap = node as? SKTileMapNode {
            // Its filled cells, one sprite each, at its own depth.
            entries.append(contentsOf: tileMap.tileCommands(transform: transform, alpha: alpha, z: z, cull: cull))
        }

        // Each descendant keeps its own accumulated z. Re-keying a whole
        // subtree by the child's z here is what used to keep it in one block.
        for child in node.children {
            collect(child, parentTransform: transform, parentAlpha: alpha, parentZ: z, cull: cull, into: &entries)
        }
    }

    /// One sprite's quads: just itself, or the nine a sliced one draws as.
    /// Each carries the anchor point that puts its own frame where the whole
    /// sprite would have put that part of itself.
    @MainActor private static func slices(
        of sprite: SKSpriteNode,
        scale: CGSize = CGSize(width: 1, height: 1)
    ) -> [(size: CGSize, anchorPoint: CGPoint, textureRect: CGRect)] {
        let textureRect = sprite.texture?.textureRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        guard sprite.isSliced, let art = sprite.texture?.size(), art.width > 0, art.height > 0 else {
            return [(sprite.size, sprite.anchorPoint, textureRect)]
        }
        let own = sprite.contentFrame
        let frame = CGRect(x: own.minX * scale.width, y: own.minY * scale.height,
                           width: own.width * scale.width, height: own.height * scale.height)
        let patches = NineSlice.patches(frame: frame, textureSize: art, center: sprite.centerRect, base: own.size)
        guard patches.count > 1 else { return [(sprite.size, sprite.anchorPoint, textureRect)] }
        return patches.map { patch in
            // The transform is the node's, so a patch is placed by giving it
            // an anchor point that lands its own rect where the patch sits.
            (
                patch.frame.size,
                CGPoint(
                    x: patch.frame.width == 0 ? 0 : -patch.frame.minX / patch.frame.width,
                    y: patch.frame.height == 0 ? 0 : -patch.frame.minY / patch.frame.height
                ),
                NineSlice.within(textureRect, patch.unit)
            )
        }
    }

    @MainActor private static func children(
        of node: SKNode,
        transform: CGAffineTransform,
        alpha: CGFloat,
        z: CGFloat,
        cull: CGRect? = nil
    ) -> [(CGFloat, Command)] {
        var entries: [(CGFloat, Command)] = []
        for child in node.children {
            collect(child, parentTransform: transform, parentAlpha: alpha, parentZ: z, cull: cull, into: &entries)
        }
        return entries
    }

    private static func wrap(_ commands: [Command]) -> DrawList {
        var list = DrawList()
        list.commands = commands
        return list
    }

    /// A digest of everything in this list that changes what it draws.
    ///
    /// Used for one thing only: deciding whether a rasterizing
    /// `SKEffectNode` may keep last frame's pixels. So it covers what the
    /// renderer would put in a vertex buffer — transforms, sizes, anchors,
    /// colours, alphas, blend modes, which texture and which shader — and
    /// deliberately **not** shader uniform values. A cached band must
    /// survive `u_time` running on and a light moving, or the cache would never hold for a single frame and the
    /// whole mechanism would be a loss rather than a saving. The game asks
    /// for those redraws explicitly, by toggling `shouldRasterize`.
    public var digest: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) {
            hash = (hash ^ value) &* 0x100_0000_01b3
        }
        func mix(_ value: CGFloat) {
            // Quantised to a thousandth of a point: finer than any motion
            // that would show, and immune to the last bit of a float.
            mix(UInt64(bitPattern: Int64((value * 1000).rounded())))
        }
        func mix(_ value: CGPoint) { mix(value.x); mix(value.y) }
        func mix(_ value: CGSize) { mix(value.width); mix(value.height) }
        func mix(_ value: CGRect) { mix(value.origin); mix(value.size) }
        func mix(_ value: CGAffineTransform) {
            mix(value.a); mix(value.b); mix(value.c)
            mix(value.d); mix(value.tx); mix(value.ty)
        }
        func mix(_ value: SKColor) {
            mix(value.red); mix(value.green); mix(value.blue); mix(value.alpha)
        }
        func mix(_ object: AnyObject?) {
            mix(UInt64(UInt(bitPattern: object.map { ObjectIdentifier($0).hashValue } ?? 0)))
        }

        for command in commands {
            switch command {
            case let .sprite(sprite):
                mix(UInt64(1))
                mix(sprite.transform); mix(sprite.size); mix(sprite.anchorPoint)
                mix(sprite.textureRect); mix(sprite.color)
                mix(sprite.colorBlendFactor); mix(sprite.alpha)
                mix(UInt64(sprite.blendMode.rawValue))
                mix(sprite.texture); mix(sprite.shader)
                // A warp pose is a new grid each time it changes.
                mix(sprite.warp); mix(UInt64(sprite.subdivisionLevels))
                mix(sprite.mesh?.generation ?? 0)
            case let .shape(shape):
                mix(UInt64(2))
                mix(shape.transform); mix(shape.fillColor); mix(shape.strokeColor)
                mix(shape.lineWidth); mix(shape.alpha)
                mix(UInt64(shape.lineCap.rawValue)); mix(UInt64(shape.lineJoin.rawValue))
                // The outline itself, element by element: a path can be added
                // to in place, so its identity alone would keep a cached
                // node's pixels after its shape had changed.
                #if canImport(Darwin)
                // CoreGraphics' own path, on the host the tests run on.
                shape.path?.applyWithBlock { element in
                    let e = element.pointee
                    mix(UInt64(10 + Int(e.type.rawValue)))
                    let count: Int
                    switch e.type {
                    case .moveToPoint, .addLineToPoint: count = 1
                    case .addQuadCurveToPoint: count = 2
                    case .addCurveToPoint: count = 3
                    default: count = 0
                    }
                    for i in 0 ..< count { mix(e.points[i]) }
                }
                #else
                for element in shape.path?.elements ?? [] {
                    switch element {
                    case let .move(p): mix(UInt64(10)); mix(p)
                    case let .line(p): mix(UInt64(11)); mix(p)
                    case let .quadCurve(to, control): mix(UInt64(12)); mix(to); mix(control)
                    case let .curve(to, c1, c2): mix(UInt64(13)); mix(to); mix(c1); mix(c2)
                    case let .arc(centre, radius, start, end, clockwise):
                        mix(UInt64(14)); mix(centre); mix(radius); mix(start); mix(end)
                        mix(UInt64(clockwise ? 1 : 0))
                    case .close: mix(UInt64(15))
                    }
                }
                #endif
            case let .label(label):
                mix(UInt64(3))
                mix(label.transform); mix(label.color); mix(label.alpha)
                mix(label.fontSize)
                mix(UInt64(truncatingIfNeeded: label.text.hashValue))
                mix(UInt64(truncatingIfNeeded: (label.fontName ?? "").hashValue))
            case let .effect(effect):
                mix(UInt64(4))
                mix(effect.transform); mix(effect.bounds); mix(effect.alpha)
                mix(effect.rasterGeneration)
                mix(effect.contents.digest)
            case let .crop(crop):
                mix(UInt64(5))
                mix(crop.transform)
                mix(crop.mask.digest)
                mix(crop.contents.digest)
            }
        }
        return hash
    }

    /// Sprite commands anywhere in the list, nested ones included.
    public var spriteCount: Int {
        commands.reduce(0) { total, command in
            switch command {
            case .sprite: return total + 1
            case .shape, .label: return total
            case let .effect(effect): return total + effect.contents.spriteCount
            case let .crop(crop): return total + crop.contents.spriteCount
            }
        }
    }
}

#endif
