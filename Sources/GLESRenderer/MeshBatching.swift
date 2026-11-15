import Foundation
import SpriteKitShim

/// A sprite carrying a triangle mesh (`SKTriangleMesh`, the port's rig
/// meshes) draws its triangles rather than its quad: the same vertex layout,
/// so it batches with plain sprites of the same texture, shader and blend
/// mode, as a warp does. A Switchling's meshes and its shadow, all on its
/// rig's texture, merge into one draw where nothing comes between them.
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
