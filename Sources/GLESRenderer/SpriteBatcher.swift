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

        public var quadCount: Int { indices.count / 6 }
    }

    /// One pass of drawing. Effect and crop nodes nest, so a frame is a tree
    /// of passes rather than a flat list.
    public enum Pass {
        case batches([Batch])
        /// Render `contents` to an offscreen texture covering `bounds`, then
        /// composite it through `shader`.
        case effect(bounds: CGRect, transform: CGAffineTransform, shader: SKShader?, alpha: CGFloat, contents: [Pass])
        /// Draw `contents` clipped to `mask`.
        case crop(transform: CGAffineTransform, mask: [Pass], contents: [Pass])
        /// Text, once the shaping stack is in. Carried through so the draw
        /// order is right even while it draws nothing.
        case label(DrawList.Label)
        /// Vector shapes, once there is a path rasteriser.
        case shape(DrawList.Shape)
    }

    public init() {}

    public func passes(for list: DrawList) -> [Pass] {
        var passes: [Pass] = []
        var current: [Batch] = []

        func flush() {
            guard !current.isEmpty else { return }
            passes.append(.batches(current))
            current = []
        }

        for command in list.commands {
            switch command {
            case let .sprite(sprite):
                append(sprite, to: &current)

            case let .effect(effect):
                flush()
                passes.append(.effect(
                    bounds: effect.bounds,
                    transform: effect.transform,
                    shader: effect.shader,
                    alpha: effect.alpha,
                    contents: self.passes(for: effect.contents)
                ))

            case let .crop(crop):
                flush()
                passes.append(.crop(
                    transform: crop.transform,
                    mask: self.passes(for: crop.mask),
                    contents: self.passes(for: crop.contents)
                ))

            case let .label(label):
                flush()
                passes.append(.label(label))

            case let .shape(shape):
                flush()
                passes.append(.shape(shape))
            }
        }

        flush()
        return passes
    }

    /// Adds one sprite, merging into the open batch where it can.
    private func append(_ sprite: DrawList.Sprite, to batches: inout [Batch]) {
        let mergeable = sprite.attributeValues.isEmpty

        if var last = batches.last,
           mergeable,
           last.attributeValues.isEmpty,
           sameTexture(last.texture, sprite.texture),
           last.shader === sprite.shader,
           last.blendMode == sprite.blendMode
        {
            addQuad(sprite, to: &last)
            batches[batches.count - 1] = last
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

    /// Two sprites share a texture when they sample the same image, even if
    /// they are different slices of one atlas — the UVs differ, the binding
    /// does not.
    private func sameTexture(_ a: SKTexture?, _ b: SKTexture?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.root === b.root
        default: return false
        }
    }

    private func addQuad(_ sprite: DrawList.Sprite, to batch: inout Batch) {
        let frame = CGRect(
            x: -sprite.size.width * sprite.anchorPoint.x,
            y: -sprite.size.height * sprite.anchorPoint.y,
            width: sprite.size.width,
            height: sprite.size.height
        )

        // Corners in the node's own space, then into the scene's.
        let corners = [
            CGPoint(x: frame.minX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.maxY),
        ].map { $0.applying(sprite.transform) }

        let uv = sprite.textureRect
        let uvs = [
            CGPoint(x: uv.minX, y: uv.minY),
            CGPoint(x: uv.maxX, y: uv.minY),
            CGPoint(x: uv.maxX, y: uv.maxY),
            CGPoint(x: uv.minX, y: uv.maxY),
        ]

        // v_color_mix carries the tint in rgb and the node's alpha in a.
        // The game reads `v_color_mix.a` as a fade multiplier in 12 places
        // (`gl_FragColor = color * fade * v_color_mix.a;`), so that is the
        // contract here. colorBlendFactor rides as its own attribute because
        // it varies per node and batches merge nodes.
        let colour = sprite.color
        let base: [Float] = [
            Float(colour.red), Float(colour.green), Float(colour.blue),
            Float(sprite.alpha),
            Float(sprite.colorBlendFactor),
        ]

        let first = UInt16(batch.vertices.count / Self.floatsPerVertex)
        for i in 0 ..< 4 {
            batch.vertices.append(Float(corners[i].x))
            batch.vertices.append(Float(corners[i].y))
            batch.vertices.append(Float(uvs[i].x))
            batch.vertices.append(Float(uvs[i].y))
            batch.vertices.append(contentsOf: base)
        }
        batch.indices.append(contentsOf: [
            first, first + 1, first + 2,
            first, first + 2, first + 3,
        ])
    }
}

public extension SpriteBatcher.Pass {
    /// Quads drawn by this pass and everything nested inside it.
    var quadCount: Int {
        switch self {
        case let .batches(batches): return batches.reduce(0) { $0 + $1.quadCount }
        case let .effect(_, _, _, _, contents): return contents.reduce(0) { $0 + $1.quadCount }
        case let .crop(_, _, contents): return contents.reduce(0) { $0 + $1.quadCount }
        case .label, .shape: return 0
        }
    }
}
