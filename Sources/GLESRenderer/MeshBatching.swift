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
        if let fill = meshes.fill { appendShapeMesh(fill, colour: shape.fillColor, shape, to: &batches) }
        if let stroke = meshes.stroke { appendShapeMesh(stroke, colour: shape.strokeColor, shape, to: &batches) }
    }

    private func appendShapeMesh(_ mesh: ShapeTessellator.Mesh, colour: SKColor, _ shape: DrawList.Shape, to batches: inout [Batch]) {
        let alpha = Float(colour.alpha * shape.alpha)
        guard !mesh.isEmpty, alpha > 0 else { return }

        let index: Int
        if let last = batches.indices.last,
           batches[last].texture == nil, batches[last].shader == nil,
           batches[last].attributeValues.isEmpty, batches[last].blendMode == .alpha,
           batches[last].vertices.count / Self.floatsPerVertex + mesh.vertexCount <= Int(UInt16.max) + 1 {
            index = last
        } else {
            batches.append(Batch(blendMode: .alpha))
            index = batches.count - 1
        }

        let t = shape.transform
        let a = Float(t.a), b = Float(t.b), c = Float(t.c), d = Float(t.d), tx = Float(t.tx), ty = Float(t.ty)
        let red = Float(colour.red), green = Float(colour.green), blue = Float(colour.blue)
        let stride = Self.floatsPerVertex
        let start = batches[index].vertices.count
        let first = UInt16(start / stride)
        // Grown once and written through a pointer: appended a float at a
        // time, a panel's few hundred vertices cost more than everything
        // else the batcher does for it.
        batches[index].vertices.append(contentsOf: repeatElement(0, count: mesh.vertexCount * stride))
        batches[index].vertices.withUnsafeMutableBufferPointer { out in
            mesh.positions.withUnsafeBufferPointer { positions in
                mesh.coverage.withUnsafeBufferPointer { coverage in
                    var o = start
                    for i in 0 ..< positions.count {
                        let p = positions[i]
                        out[o] = a * p.x + c * p.y + tx
                        out[o + 1] = b * p.x + d * p.y + ty
                        out[o + 2] = 0.5
                        out[o + 3] = 0.5
                        out[o + 4] = red
                        out[o + 5] = green
                        out[o + 6] = blue
                        out[o + 7] = alpha * coverage[i]
                        out[o + 8] = 1
                        o += stride
                    }
                }
            }
        }
        batches[index].indices.append(contentsOf: mesh.indices.lazy.map { first + $0 })
    }
}
