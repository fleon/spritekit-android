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
    func appendShape(_ shape: DrawList.Shape, _ meshes: ShapeMeshes.Meshes, to batches: inout [Batch]) {
        let colours = ShapeMeshes.colours(shape)
        let fill = meshes.fill.flatMap { !$0.isEmpty && colours[3] > 0 ? $0 : nil }
        let stroke = meshes.stroke.flatMap { !$0.isEmpty && colours[7] > 0 ? $0 : nil }
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
        let index: Int
        if let last = batches.indices.last,
           batches[last].texture == nil, batches[last].shader == nil,
           batches[last].attributeValues.isEmpty, batches[last].blendMode == .alpha,
           batches[last].vertices.count / Self.floatsPerVertex + count <= Int(UInt16.max) + 1 {
            index = last
        } else {
            batches.append(Batch(blendMode: .alpha))
            index = batches.count - 1
        }
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
            batches[index].vertices.append(contentsOf: kept.vertices)
            batches[index].indices.append(contentsOf: kept.indices)
        } else {
            // Moved out and back rather than borrowed twice from one batch.
            var vertices: [Float] = [], indices: [UInt16] = []
            swap(&vertices, &batches[index].vertices)
            swap(&indices, &batches[index].indices)
            writeParts(into: &vertices, &indices, firstIndex: first)
            swap(&vertices, &batches[index].vertices)
            swap(&indices, &batches[index].indices)
        }
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
        let start = vertices.count
        let first = UInt16(firstIndex)
        vertices.append(contentsOf: repeatElement(0, count: mesh.vertexCount * stride))
        vertices.withUnsafeMutableBufferPointer { out in
            mesh.positions.withUnsafeBufferPointer { positions in
                mesh.coverage.withUnsafeBufferPointer { coverage in
                    var o = start
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
        }
        indices.append(contentsOf: mesh.indices.lazy.map { first &+ $0 })
    }
}
