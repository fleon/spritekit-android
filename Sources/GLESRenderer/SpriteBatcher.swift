import Foundation
import SpriteKitShim

/// Turns a `DrawList` into batched draw calls.
///
/// This is the half of the renderer that needs no GL context, so it is
/// testable on the Mac: batching decisions, vertex maths and draw order are
/// all pure. The GL half only uploads what comes out of here.
///
/// Batching rule: consecutive commands that share texture, shader and blend
/// mode merge into one buffer. Order is never reordered to merge more — the
/// draw list is already in the order SpriteKit would composite, and swapping
/// two overlapping quads would change the picture.
public struct SpriteBatcher {
    /// A sprite's alpha as its tint carries it: the node's, times its
    /// colour's alpha mixed in from 1 by the blend factor, as SpriteKit
    /// fades a sprite tinted toward a clear colour (Tools/TintProbe). An
    /// untextured one's already has its colour's in it (`DrawList`).
    static func tintAlpha(_ sprite: DrawList.Sprite) -> Float {
        guard sprite.texture != nil else { return Float(sprite.alpha) }
        let factor = min(1, max(0, sprite.colorBlendFactor))
        return Float(sprite.alpha * (1 + (sprite.color.alpha - 1) * factor))
    }


    /// Floats per vertex: x, y, u, v, r, g, b, a, blend.
    public static let floatsPerVertex = 9

    public struct Batch {
        /// Interleaved vertices, `floatsPerVertex` each, two triangles a quad.
        public var vertices: [Float] = []
        /// Triangle indices into `vertices`.
        public var indices: [UInt16] = []
        public var texture: SKTexture?
        public var shader: SKShader?
        public var blendMode: SKBlendMode
        /// Set when the batch is a single node carrying its own SKAttribute
        /// values, which cannot be merged with anything else.
        public var attributeValues: [String: SKAttributeValue]
        /// A textured stroke's batch (`appendTexturedStroke`): its texture
        /// repeats along the stroke and is clamped across it, sampled so
        /// without touching how the texture itself wraps for its sprites.
        public var repeatsAlong = false
        /// The batch has a shader of its own, so its UVs are in its image's
        /// own 0…1 (`ownImage(_:)`) and the renderer binds that image alone
        /// (`ResourceCache.imageName(for:)`) rather than its packed page.
        public var ownImage: Bool { shader != nil }
        /// Where the batch's indices start in the frame's stream once the
        /// renderer has written it there with the rest of the frame
        /// (`SceneRenderer.stage`), in indices; -1 until then.
        public var streamFirstIndex: Int = -1
        /// Where its vertices start in that stream, in vertices.
        public var streamFirstVertex: Int = 0

        public var quadCount: Int { indices.count / 6 }

        public init(
            vertices: [Float] = [],
            indices: [UInt16] = [],
            texture: SKTexture? = nil,
            shader: SKShader? = nil,
            blendMode: SKBlendMode,
            attributeValues: [String: SKAttributeValue] = [:]
        ) {
            self.vertices = vertices
            self.indices = indices
            self.texture = texture
            self.shader = shader
            self.blendMode = blendMode
            self.attributeValues = attributeValues
        }
    }

    /// One pass of drawing. Effect and crop nodes nest, so a frame is a tree
    /// of passes rather than a flat list.
    public enum Pass {
        case batches([Batch])
        /// Render `contents` to an offscreen texture covering `bounds`, then
        /// composite it through `shader`. `rasterize` keeps the texture
        /// between frames, and `owner`/`generation`/`digest` are what decide
        /// whether the kept pixels are still good — the mechanism
        /// a layer cached in bands is built on.
        case effect(
            bounds: CGRect,
            transform: CGAffineTransform,
            shader: SKShader?,
            alpha: CGFloat,
            blendMode: SKBlendMode,
            rasterize: Bool,
            owner: ObjectIdentifier,
            generation: UInt64,
            digest: UInt64,
            contents: [Pass]
        )
        /// Draw `contents` clipped to `mask`.
        case crop(transform: CGAffineTransform, mask: [Pass], contents: [Pass])
        /// Text, once the shaping stack is in. Carried through so the draw
        /// order is right even while it draws nothing.
        case label(DrawList.Label)
        /// Vector shapes, once there is a path rasteriser.
        case shape(DrawList.Shape)
        /// A label or shape as the renderer made it into coverage quads, so
        /// they're written with the frame's stream (`SceneRenderer.stage`).
        case coverage(CoverageGeometry.Staged)
    }

    public init() {}

    /// Whether a rasterizing effect node's kept pixels are still good for
    /// this generation and digest (the renderer's `RenderTargetPool`). Its
    /// contents are then left out of the passes: they would only be batched
    /// and thrown away, as the renderer composites what it kept.
    public var rasterIsFresh: ((_ owner: ObjectIdentifier, _ generation: UInt64, _ digest: UInt64) -> Bool)?

    /// Shapes as triangles (`ShapeTessellator`), merged into the colour
    /// batches around them. Nil, or a shape it can't take, and the shape is
    /// a pass of its own, drawn through its mask.
    public var shapeMeshes: ShapeMeshes?

    public func passes(for list: DrawList) -> [Pass] {
        passes(for: list, tessellatingShapes: true)
    }

    /// `tessellatingShapes` false for a crop's mask: a shape there cuts by
    /// its coverage alone, which its mask pass keeps.
    func passes(for list: DrawList, tessellatingShapes: Bool) -> [Pass] {
        var passes: [Pass] = []
        var current: [Batch] = []
        add(list.commands, through: .identity, tessellating: tessellatingShapes, to: &passes, current: &current)
        if !current.isEmpty { passes.append(.batches(current)) }
        return passes
    }

    /// Whether an effect node composites to exactly what drawing its
    /// children in place does: no shader, no cache and no fade. Its
    /// contents then join the batches around them (`add`), as the renderer
    /// would draw them in place anyway.
    public static func passesThrough(_ effect: DrawList.Effect) -> Bool {
        effect.shader == nil && !effect.shouldRasterize && effect.alpha >= 0.999
    }

    /// `commands`, carried by `transform`, onto `passes`, merging sprites
    /// into `current` where they can. A crop with no mask clips nothing, and
    /// an effect that passes through draws nothing of its own, so their
    /// contents go on in the same order, merging with what's either side
    /// rather than breaking the batch.
    private func add(
        _ commands: [DrawList.Command],
        through transform: CGAffineTransform,
        tessellating: Bool,
        to passes: inout [Pass],
        current: inout [Batch]
    ) {
        func flush() {
            guard !current.isEmpty else { return }
            passes.append(.batches(current))
            current = []
        }

        // Moved first, all at once, where they need moving: rebinding each
        // command on the way through copied it for every sprite.
        guard transform.isIdentity else {
            add(commands.map { Self.moved($0, by: transform) }, through: .identity, tessellating: tessellating, to: &passes, current: &current)
            return
        }
        for command in commands {
            switch command {
            case let .sprite(sprite):
                append(sprite, to: &current)

            case let .effect(effect) where Self.passesThrough(effect):
                // Its contents are in its own space (`DrawList`).
                add(effect.contents.commands, through: effect.transform, tessellating: tessellating, to: &passes, current: &current)

            case let .crop(crop) where crop.mask.commands.isEmpty:
                // Its contents are in its parent's space already.
                add(crop.contents.commands, through: .identity, tessellating: tessellating, to: &passes, current: &current)

            case let .effect(effect):
                flush()
                passes.append(.effect(
                    bounds: effect.bounds,
                    transform: effect.transform,
                    shader: effect.shader,
                    alpha: effect.alpha,
                    blendMode: effect.blendMode,
                    rasterize: effect.shouldRasterize,
                    owner: effect.owner,
                    generation: effect.rasterGeneration,
                    digest: effect.contentsDigest,
                    contents: effect.shouldRasterize && rasterIsFresh?(effect.owner, effect.rasterGeneration, effect.contentsDigest) == true
                        ? []
                        : self.passes(for: effect.contents, tessellatingShapes: tessellating)
                ))

            case let .crop(crop):
                flush()
                passes.append(.crop(
                    transform: crop.transform,
                    mask: self.passes(for: crop.mask, tessellatingShapes: false),
                    contents: self.passes(for: crop.contents, tessellatingShapes: tessellating)
                ))

            case let .label(label):
                flush()
                passes.append(.label(label))

            case let .shape(shape):
                guard tessellating, let shapeMeshes else {
                    flush()
                    passes.append(.shape(shape))
                    continue
                }
                switch shapeMeshes.plan(for: shape) {
                case .mask:
                    flush()
                    passes.append(.shape(shape))
                case .nothing:
                    break
                case let .meshes(keys):
                    // A node that holds still: its kept vertices, copied in.
                    if appendKeptShape(shape, keys, shapeMeshes, to: &current) { continue }
                    if let meshes = shapeMeshes.meshes(for: shape, keys) {
                        appendShape(shape, meshes, to: &current)
                    } else {
                        flush()
                        passes.append(.shape(shape))
                    }
                }
            }
        }
    }

    /// A command carried by `transform`, nested contents included where
    /// they are in the parent's space (a crop's mask and contents); an
    /// effect's contents are in its own, which its transform carries.
    static func moved(_ command: DrawList.Command, by transform: CGAffineTransform) -> DrawList.Command {
        switch command {
        case var .sprite(sprite):
            sprite.transform = sprite.transform.concatenating(transform)
            return .sprite(sprite)
        case var .shape(shape):
            shape.transform = shape.transform.concatenating(transform)
            return .shape(shape)
        case var .label(label):
            label.transform = label.transform.concatenating(transform)
            return .label(label)
        case var .effect(effect):
            effect.transform = effect.transform.concatenating(transform)
            return .effect(effect)
        case var .crop(crop):
            crop.transform = crop.transform.concatenating(transform)
            crop.mask.commands = crop.mask.commands.map { moved($0, by: transform) }
            crop.contents.commands = crop.contents.commands.map { moved($0, by: transform) }
            return .crop(crop)
        }
    }

    /// Adds one sprite, merging into the open batch where it can.
    private func append(_ sprite: DrawList.Sprite, to batches: inout [Batch]) {
        let mergeable = sprite.attributeValues.isEmpty

        // Merged in place: a copy of the open batch, written back, copied
        // its whole vertex array for every sprite added.
        if mergeable, let last = batches.indices.last,
           batches[last].vertices.count / Self.floatsPerVertex + Self.vertexCount(of: sprite) <= Int(UInt16.max) + 1,
           batches[last].attributeValues.isEmpty,
           batches[last].shader === sprite.shader,
           sprite.shader == nil ? sameTexture(batches[last].texture, sprite.texture) : sameImage(batches[last].texture, sprite.texture),
           batches[last].blendMode == sprite.blendMode
        {
            addQuad(sprite, to: &batches[last])
            return
        }

        var batch = Batch(
            texture: sprite.texture,
            shader: sprite.shader,
            blendMode: sprite.blendMode,
            attributeValues: sprite.attributeValues
        )
        addQuad(sprite, to: &batch)
        batches.append(batch)
    }

    /// Two shaded sprites share a texture when they show the same image: each
    /// is bound alone, not as its page.
    private func sameImage(_ a: SKTexture?, _ b: SKTexture?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            if let nameA = a.root.asset?.name, let nameB = b.root.asset?.name { return nameA == nameB }
            return a.root === b.root
        default: return false
        }
    }

    /// Where a shaded sprite's `textureRect` (a rect on its packed page) lies
    /// in its image's own 0…1.
    ///
    /// SpriteKit hands a custom shader `v_tex_coord` in the texture's own
    /// space, and the game's images are each a texture of their own there:
    /// 0…1 across the image, through its 9-slice when it's sliced, and a
    /// slice of it (`SKTexture(rect:in:)`) within that. Every shader that
    /// works out where it is from `v_tex_coord` depends on it. Given the
    /// page's coordinates instead, a shader that drew cracks across its
    /// sprite struck them far off it (a plain sprite) and read their colour
    /// from a row of the page (streaks of whatever art sat there).
    static func ownImage(_ rect: CGRect, of texture: SKTexture?) -> CGRect {
        guard let image = texture?.root.textureRect(), image.width > 0, image.height > 0 else { return rect }
        return CGRect(
            x: (rect.minX - image.minX) / image.width,
            y: (rect.minY - image.minY) / image.height,
            width: rect.width / image.width,
            height: rect.height / image.height
        )
    }

    /// Two sprites share a texture when the renderer would bind the same
    /// one for both.
    ///
    /// That is the **packed page**, not the `SKTexture` object: every
    /// `SKTexture(imageNamed:)` makes a fresh instance, so comparing identity
    /// would put thirty tiles of the same image in thirty draw calls although they
    /// all sit on one page — which is exactly what packing them was for.
    /// A texture the index does not back (raw data, a solid colour, a baked
    /// render target) has no page, and falls back to the object that owns
    /// the upload.
    private func sameTexture(_ a: SKTexture?, _ b: SKTexture?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            if let pageA = a.page, let pageB = b.page { return pageA == pageB }
            return a.page == nil && b.page == nil && a.root === b.root
        default: return false
        }
    }

    private func addQuad(_ sprite: DrawList.Sprite, to batch: inout Batch) {
        if let grid = sprite.warp {
            addWarp(grid, sprite, to: &batch)
            return
        }
        if let mesh = sprite.mesh {
            addMesh(mesh, sprite, to: &batch)
            return
        }
        let frame = CGRect(
            x: -sprite.size.width * sprite.anchorPoint.x,
            y: -sprite.size.height * sprite.anchorPoint.y,
            width: sprite.size.width,
            height: sprite.size.height
        )

        // Corners in the node's own space, then into the scene's.
        let t = sprite.transform
        func corner(_ x: CGFloat, _ y: CGFloat) -> (Float, Float) {
            (Float(t.a * x + t.c * y + t.tx), Float(t.b * x + t.d * y + t.ty))
        }
        let c0 = corner(frame.minX, frame.minY), c1 = corner(frame.maxX, frame.minY)
        let c2 = corner(frame.maxX, frame.maxY), c3 = corner(frame.minX, frame.maxY)

        let uv = sprite.shader == nil ? sprite.textureRect : Self.ownImage(sprite.textureRect, of: sprite.texture)
        let u0 = Float(uv.minX), u1 = Float(uv.maxX), v0 = Float(uv.minY), v1 = Float(uv.maxY)

        // The vertex carries the tint's colour, the node's alpha with the
        // colour's own mixed in by the blend factor (`tintAlpha`), and the
        // factor, which rides as its own attribute because it varies per
        // node and batches merge nodes; the vertex shader makes SpriteKit's
        // `v_color_mix` of them, whose alpha a shader reads as the fade.
        let colour = sprite.color
        let r = Float(colour.red), g = Float(colour.green), b = Float(colour.blue)
        let blend = Float(sprite.colorBlendFactor), a = Self.tintAlpha(sprite)

        let first = UInt16(batch.vertices.count / Self.floatsPerVertex)
        batch.vertices.reserveCapacity(batch.vertices.count + 4 * Self.floatsPerVertex)
        func vertex(_ c: (Float, Float), _ u: Float, _ v: Float) {
            batch.vertices.append(c.0)
            batch.vertices.append(c.1)
            batch.vertices.append(u)
            batch.vertices.append(v)
            batch.vertices.append(r)
            batch.vertices.append(g)
            batch.vertices.append(b)
            batch.vertices.append(a)
            batch.vertices.append(blend)
        }
        vertex(c0, u0, v0)
        vertex(c1, u1, v0)
        vertex(c2, u1, v1)
        vertex(c3, u0, v1)
        batch.indices.append(first)
        batch.indices.append(first + 1)
        batch.indices.append(first + 2)
        batch.indices.append(first)
        batch.indices.append(first + 2)
        batch.indices.append(first + 3)
    }
}

public extension SpriteBatcher.Pass {
    /// Quads drawn by this pass and everything nested inside it.
    var quadCount: Int {
        switch self {
        case let .batches(batches): return batches.reduce(0) { $0 + $1.quadCount }
        case let .effect(_, _, _, _, _, _, _, _, _, contents): return contents.reduce(0) { $0 + $1.quadCount }
        case let .crop(_, _, contents): return contents.reduce(0) { $0 + $1.quadCount }
        case .label, .shape: return 0
        case let .coverage(staged): return staged.parts.reduce(0) { $0 + $1.run.quadCount }
        }
    }
}
