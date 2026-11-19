import Foundation
import SpriteKitShim

/// A warped sprite (SKWarpGeometry) draws as its grid's triangles rather than
/// one quad: the same vertex layout, so it batches with plain sprites of the
/// same texture.
extension SpriteBatcher {
    /// Vertices a sprite adds to a batch, so a batch never outgrows its
    /// 16-bit indices.
    static func vertexCount(of sprite: DrawList.Sprite) -> Int {
        if let mesh = sprite.mesh { return mesh.positions.count }
        guard let grid = sprite.warp else { return 4 }
        let split = 1 << min(max(sprite.subdivisionLevels, 0), WarpMesh.deepestLevel)
        return (grid.numberOfColumns * split + 1) * (grid.numberOfRows * split + 1)
    }

    /// Writes the grid's mesh (`WarpMesh`: the same vertices, in the same
    /// order, and the same triangles) straight into the batch, through the
    /// sprite's frame and transform in one affine step, so a frame builds no
    /// mesh of its own for each warped sprite: a scene of swaying plants may
    /// draw a new pose for each every frame.
    func addWarp(_ grid: SKWarpGeometryGrid, _ sprite: DrawList.Sprite, to batch: inout Batch) {
        let columns = grid.numberOfColumns, rows = grid.numberOfRows
        let level = WarpMesh.isUntouched(grid) ? 0 : min(max(sprite.subdivisionLevels, 0), WarpMesh.deepestLevel)
        let split = 1 << level
        let across = columns * split + 1, down = rows * split + 1
        let stride = columns + 1

        // Unit space is the sprite's frame, placed by its anchor point, then
        // carried by its transform: x = a·u·w + c·v·h + (a·x0 + c·y0 + tx).
        let t = sprite.transform
        let w = sprite.size.width, h = sprite.size.height
        let x0 = -w * sprite.anchorPoint.x, y0 = -h * sprite.anchorPoint.y
        let ux = Float(t.a * w), uy = Float(t.b * w), vx = Float(t.c * h), vy = Float(t.d * h)
        let ox = Float(t.a * x0 + t.c * y0 + t.tx), oy = Float(t.b * x0 + t.d * y0 + t.ty)
        let uv = sprite.shader == nil ? sprite.textureRect : Self.ownImage(sprite.textureRect, of: sprite.texture)
        let u0 = Float(uv.minX), v0 = Float(uv.minY), du = Float(uv.width), dv = Float(uv.height)
        let colour = sprite.color
        let red = Float(colour.red), green = Float(colour.green), blue = Float(colour.blue)
        let alpha = SpriteBatcher.tintAlpha(sprite), blend = Float(sprite.colorBlendFactor)

        let first = UInt16(batch.vertices.count / Self.floatsPerVertex)
        batch.vertices.reserveCapacity(batch.vertices.count + across * down * Self.floatsPerVertex)
        let step = 1 / Float(split)
        grid.destinationPositions.withUnsafeBufferPointer { destination in
            grid.sourcePositions.withUnsafeBufferPointer { source in
                for y in 0..<down {
                    let row = min(y / split, rows - 1)
                    let v = Float(y - row * split) * step
                    let below = row * stride, above = below + stride
                    for x in 0..<across {
                        let column = min(x / split, columns - 1)
                        let u = Float(x - column * split) * step
                        let i = below + column, j = above + column
                        let p = (destination[i] * (1 - u) + destination[i + 1] * u) * (1 - v)
                            + (destination[j] * (1 - u) + destination[j + 1] * u) * v
                        let s = (source[i] * (1 - u) + source[i + 1] * u) * (1 - v)
                            + (source[j] * (1 - u) + source[j + 1] * u) * v
                        batch.vertices.append(ux * p.x + vx * p.y + ox)
                        batch.vertices.append(uy * p.x + vy * p.y + oy)
                        batch.vertices.append(u0 + s.x * du)
                        batch.vertices.append(v0 + s.y * dv)
                        batch.vertices.append(red)
                        batch.vertices.append(green)
                        batch.vertices.append(blue)
                        batch.vertices.append(alpha)
                        batch.vertices.append(blend)
                    }
                }
            }
        }
        batch.indices.reserveCapacity(batch.indices.count + (across - 1) * (down - 1) * 6)
        for y in 0..<(down - 1) {
            for x in 0..<(across - 1) {
                let a = first + UInt16(y * across + x), b = a + 1
                let c = a + UInt16(across), d = c + 1
                // Bottom left to top right: (a, b, d) and (a, d, c).
                batch.indices.append(a); batch.indices.append(b); batch.indices.append(d)
                batch.indices.append(a); batch.indices.append(d); batch.indices.append(c)
            }
        }
    }
}
