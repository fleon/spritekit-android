import Foundation
import SpriteKitShim

/// A sprite carrying a triangle mesh (`SKTriangleMesh`, a skeletal rig's
/// meshes, say) draws its triangles rather than its quad: the same vertex
/// layout, so it batches with plain sprites of the same texture, shader and
/// blend mode, as a warp does. A rig's meshes and its shadow, all on one
/// texture, merge into one draw where nothing comes between them.
extension SpriteBatcher {
    func addMesh(_ mesh: SKTriangleMesh, _ sprite: DrawList.Sprite, to batch: inout Batch) {
        // The texture's own 0…1 onto what the batch samples: the page's
        // slice, or the image alone for a shaded sprite (`ownImage`).
        let uv = sprite.shader == nil ? sprite.textureRect : Self.ownImage(sprite.textureRect, of: sprite.texture)
        let u0 = Float(uv.minX), v0 = Float(uv.minY), du = Float(uv.width), dv = Float(uv.height)
        let t = sprite.transform
        let a = Float(t.a), b = Float(t.b), c = Float(t.c), d = Float(t.d), tx = Float(t.tx), ty = Float(t.ty)
        let colour = sprite.color
        let red = Float(colour.red), green = Float(colour.green), blue = Float(colour.blue)
        let alpha = Float(sprite.alpha), blend = Float(sprite.colorBlendFactor)

        let first = UInt16(batch.vertices.count / Self.floatsPerVertex)
        batch.vertices.reserveCapacity(batch.vertices.count + mesh.positions.count * Self.floatsPerVertex)
        for (p, tex) in zip(mesh.positions, mesh.texCoords) {
            batch.vertices.append(a * p.x + c * p.y + tx)
            batch.vertices.append(b * p.x + d * p.y + ty)
            batch.vertices.append(u0 + tex.x * du)
            batch.vertices.append(v0 + tex.y * dv)
            batch.vertices.append(red)
            batch.vertices.append(green)
            batch.vertices.append(blue)
            batch.vertices.append(alpha)
            batch.vertices.append(blend)
        }
        batch.indices.reserveCapacity(batch.indices.count + mesh.indices.count)
        for index in mesh.indices { batch.indices.append(first + index) }
    }
}

/// A shape's triangles (`ShapeMeshes`) draw as a colour sprite does: the
/// white texel tinted all the way to the colour, its alpha the colour's
/// times the node's times the vertex's coverage. So shapes merge with the
/// colour sprites and other shapes either side of them, in order.
extension SpriteBatcher {
    /// A still shape's kept vertices (`ShapeMeshes.kept`), appended whole
    /// without its meshes being fetched; false when it has none to give.
    func appendKeptShape(_ shape: DrawList.Shape, _ keys: ShapeMeshes.Keys, _ shapeMeshes: ShapeMeshes, to batches: inout [Batch]) -> Bool {
        guard !keys.textured else { return false }
        let colours = ShapeMeshes.colours(shape)
        guard let entry = shapeMeshes.kept(for: shape, keys, colours: colours) else { return false }
        let count = entry.vertices.count / Self.floatsPerVertex
        guard count > 0 else { return true }
        let index = colourBatch(for: count, in: &batches)
        let first = batches[index].vertices.count / Self.floatsPerVertex
        let kept = shapeMeshes.keep(entry, first: first)
        append(kept.vertices, kept.indices, to: &batches[index])
        return true
    }

    /// The open colour batch if `count` more vertices fit in it, else a new one.
    private func colourBatch(for count: Int, in batches: inout [Batch]) -> Int {
        if let last = batches.indices.last,
           batches[last].texture == nil, batches[last].shader == nil,
           batches[last].attributeValues.isEmpty, batches[last].blendMode == .alpha,
           batches[last].vertices.count / Self.floatsPerVertex + count <= Int(UInt16.max) + 1 {
            return last
        }
        batches.append(Batch(blendMode: .alpha))
        return batches.count - 1
    }

    /// Room for `floats` and `indices` more in `batch`: reserved at once to
    /// the largest a batch has been (`ShapeMeshes.noteBatch`), so a frame's
    /// shapes grow it once rather than doubling it, and copying it, as they
    /// come.
    private func reserve(_ floats: Int, _ indices: Int, in batch: inout Batch) {
        let hint = shapeMeshes
        if batch.vertices.capacity < batch.vertices.count + floats {
            batch.vertices.reserveCapacity(max(batch.vertices.count + floats, hint?.batchFloats ?? 0))
        }
        if batch.indices.capacity < batch.indices.count + indices {
            batch.indices.reserveCapacity(max(batch.indices.count + indices, hint?.batchIndices ?? 0))
        }
    }

    private func append(_ vertices: [Float], _ indices: [UInt16], to batch: inout Batch) {
        reserve(vertices.count, indices.count, in: &batch)
        batch.vertices.append(contentsOf: vertices)
        batch.indices.append(contentsOf: indices)
        shapeMeshes?.noteBatch(floats: batch.vertices.count, indices: batch.indices.count)
    }

    func appendShape(_ shape: DrawList.Shape, _ meshes: ShapeMeshes.Meshes, to batches: inout [Batch]) {
        let colours = ShapeMeshes.colours(shape)
        let fill = meshes.fill.flatMap { !$0.isEmpty && colours[3] > 0 ? $0 : nil }
        var stroke = meshes.stroke.flatMap { !$0.isEmpty && colours[7] > 0 ? $0 : nil }
        // A textured stroke draws in a batch of its own texture, after the
        // fill it sits on, as SpriteKit draws a shape's stroke over its fill.
        if let textured = stroke, !textured.texCoords.isEmpty, let texture = shape.strokeTexture {
            if let fill { appendShapeParts(fill: fill, stroke: nil, shape, colours: colours, to: &batches) }
            appendTexturedStroke(textured, texture: texture, shape, colours: colours, to: &batches)
            return
        }
        if stroke?.texCoords.isEmpty == false { stroke = nil }
        let count = (fill?.vertexCount ?? 0) + (stroke?.vertexCount ?? 0)
        guard count > 0 else { return }

        // Fill and stroke together, in one batch: past what one can index,
        // each goes on its own.
        guard count <= Int(UInt16.max) + 1 else {
            if let fill { appendShapeParts(fill: fill, stroke: nil, shape, colours: colours, to: &batches) }
            if let stroke { appendShapeParts(fill: nil, stroke: stroke, shape, colours: colours, to: &batches) }
            return
        }
        appendShapeParts(fill: fill, stroke: stroke, shape, colours: colours, meshes: meshes, to: &batches)
    }

    private func appendShapeParts(
        fill: ShapeTessellator.Mesh?,
        stroke: ShapeTessellator.Mesh?,
        _ shape: DrawList.Shape,
        colours: SIMD8<Float>,
        meshes: ShapeMeshes.Meshes? = nil,
        to batches: inout [Batch]
    ) {
        let count = (fill?.vertexCount ?? 0) + (stroke?.vertexCount ?? 0)
        let index = colourBatch(for: count, in: &batches)
        let first = batches[index].vertices.count / Self.floatsPerVertex

        // Both parts written after whatever `vertices` holds, indices
        // counting from where they land.
        func writeParts(into vertices: inout [Float], _ indices: inout [UInt16], firstIndex: Int) {
            if let fill {
                Self.write(fill, transform: shape.transform, rgb: SIMD3(colours[0], colours[1], colours[2]), alpha: colours[3], into: &vertices, indices: &indices, first: firstIndex)
            }
            if let stroke {
                let next = firstIndex + (fill?.vertexCount ?? 0)
                Self.write(stroke, transform: shape.transform, rgb: SIMD3(colours[4], colours[5], colours[6]), alpha: colours[7], into: &vertices, indices: &indices, first: next)
            }
        }

        // A node's finished vertices, kept while it holds still, copied in
        // whole; a part written on its own, or a shape no node owns, is
        // written straight into the batch.
        if let meshes, let shapeMeshes,
           let kept = shapeMeshes.placed(for: shape, meshes, colours: colours, first: first, make: {
               var vertices: [Float] = []
               var indices: [UInt16] = []
               vertices.reserveCapacity(count * Self.floatsPerVertex)
               indices.reserveCapacity((fill?.indices.count ?? 0) + (stroke?.indices.count ?? 0))
               writeParts(into: &vertices, &indices, firstIndex: 0)
               return (vertices, indices)
           }) {
            append(kept.vertices, kept.indices, to: &batches[index])
        } else {
            reserve(count * Self.floatsPerVertex, (fill?.indices.count ?? 0) + (stroke?.indices.count ?? 0), in: &batches[index])
            // Moved out and back rather than borrowed twice from one batch.
            var vertices: [Float] = [], indices: [UInt16] = []
            swap(&vertices, &batches[index].vertices)
            swap(&indices, &batches[index].indices)
            writeParts(into: &vertices, &indices, firstIndex: first)
            shapeMeshes?.noteBatch(floats: vertices.count, indices: indices.count)
            swap(&vertices, &batches[index].vertices)
            swap(&indices, &batches[index].indices)
        }
    }

    /// What a textured stroke draws with: its texture multiplied by the
    /// stroke's colour and alpha (a white stroke leaves it as it is), as a
    /// Mac's SpriteKit tints one (`StrokeTextureTests`). `v_color_mix` here
    /// is the colour unpremultiplied, its alpha the vertex's coverage too.
    static let strokeTextureShader = SKShader(source: """
    void main() {
        vec4 texel = texture2D(u_texture, v_tex_coord);
        gl_FragColor = texel * vec4(v_color_mix.rgb, 1.0) * v_color_mix.a;
    }
    """)

    /// A stroke whose texture runs along it: its own image, sampled
    /// repeating along (`Batch.repeatsAlong`), one repeat every `lineWidth`
    /// times the texture's aspect, 0 to 1 across from the right of travel
    /// to the left, as SpriteKit maps one.
    private func appendTexturedStroke(
        _ mesh: ShapeTessellator.Mesh,
        texture: SKTexture,
        _ shape: DrawList.Shape,
        colours: SIMD8<Float>,
        to batches: inout [Batch]
    ) {
        // A texture cut from another (`SKTexture(rect:in:)`) runs over the
        // whole image it was cut from, its rect ignored but for its aspect,
        // as a Mac's SpriteKit draws one (`StrokeTextureTests`): the stroke
        // samples that image, and repeats as often as the cut part's shape
        // says. A packed image is its own root, cut out of its page.
        let image = texture.root
        let size = texture.size()
        let repeatLength = Float(shape.lineWidth * size.width / max(size.height, 1e-6))
        guard repeatLength > 0, repeatLength.isFinite else { return }
        let index: Int
        if let last = batches.indices.last,
           batches[last].repeatsAlong, batches[last].texture === image,
           batches[last].vertices.count / Self.floatsPerVertex + mesh.vertexCount <= Int(UInt16.max) + 1 {
            index = last
        } else {
            var batch = Batch(texture: image, shader: Self.strokeTextureShader, blendMode: .alpha)
            batch.repeatsAlong = true
            batches.append(batch)
            index = batches.count - 1
        }
        let t = shape.transform
        let a = Float(t.a), b = Float(t.b), c = Float(t.c), d = Float(t.d), tx = Float(t.tx), ty = Float(t.ty)
        let stride = Self.floatsPerVertex
        let first = UInt16(batches[index].vertices.count / stride)
        // Made in a buffer of its own and appended whole: a nine-float array
        // a vertex was a heap allocation for every vertex of every ring.
        let made = [Float](unsafeUninitializedCapacity: mesh.vertexCount * stride) { out, count in
            mesh.positions.withUnsafeBufferPointer { positions in
                mesh.texCoords.withUnsafeBufferPointer { texCoords in
                    mesh.coverage.withUnsafeBufferPointer { coverage in
                        var o = 0
                        for i in 0 ..< positions.count {
                            let p = positions[i], uv = texCoords[i]
                            out[o] = a * p.x + c * p.y + tx
                            out[o + 1] = b * p.x + d * p.y + ty
                            out[o + 2] = uv.x / repeatLength
                            out[o + 3] = uv.y
                            out[o + 4] = colours[4]
                            out[o + 5] = colours[5]
                            out[o + 6] = colours[6]
                            out[o + 7] = colours[7] * coverage[i]
                            out[o + 8] = 0
                            o += stride
                        }
                    }
                }
            }
            count = mesh.vertexCount * stride
        }
        reserve(made.count, mesh.indices.count, in: &batches[index])
        batches[index].vertices.append(contentsOf: made)
        batches[index].indices.append(contentsOf: Self.offset(mesh.indices, by: first))
    }

    /// One mesh moved by `transform` and coloured, appended as the colour
    /// sprites' vertices are; its indices count from `vertices`' start.
    private static func write(
        _ mesh: ShapeTessellator.Mesh,
        transform t: CGAffineTransform,
        rgb: SIMD3<Float>,
        alpha: Float,
        into vertices: inout [Float],
        indices: inout [UInt16],
        first firstIndex: Int
    ) {
        let a = Float(t.a), b = Float(t.b), c = Float(t.c), d = Float(t.d), tx = Float(t.tx), ty = Float(t.ty)
        let stride = floatsPerVertex
        let first = UInt16(firstIndex)
        // Made in a buffer of its own and appended whole (a copy), rather
        // than the batch grown by zeros a float at a time first.
        let made = [Float](unsafeUninitializedCapacity: mesh.vertexCount * stride) { out, count in
            mesh.positions.withUnsafeBufferPointer { positions in
                mesh.coverage.withUnsafeBufferPointer { coverage in
                    var o = 0
                    for i in 0 ..< positions.count {
                        let p = positions[i]
                        out[o] = a * p.x + c * p.y + tx
                        out[o + 1] = b * p.x + d * p.y + ty
                        out[o + 2] = 0.5
                        out[o + 3] = 0.5
                        out[o + 4] = rgb.x
                        out[o + 5] = rgb.y
                        out[o + 6] = rgb.z
                        out[o + 7] = alpha * coverage[i]
                        out[o + 8] = 1
                        o += stride
                    }
                }
            }
            count = mesh.vertexCount * stride
        }
        vertices.append(contentsOf: made)
        indices.append(contentsOf: offset(mesh.indices, by: first))
    }

    /// `indices` each moved on by `first`, made at once.
    static func offset(_ indices: [UInt16], by first: UInt16) -> [UInt16] {
        guard first != 0 else { return indices }
        return [UInt16](unsafeUninitializedCapacity: indices.count) { out, count in
            indices.withUnsafeBufferPointer { source in
                for i in 0 ..< source.count { out[i] = source[i] &+ first }
            }
            count = indices.count
        }
    }
}
