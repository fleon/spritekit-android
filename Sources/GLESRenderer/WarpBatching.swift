import Foundation
import SpriteKitShim

/// A warped sprite (SKWarpGeometry) draws as its grid's triangles rather than
/// one quad: the same vertex layout, so it batches with plain sprites of the
/// same texture.
extension SpriteBatcher {
    /// Vertices a sprite adds to a batch, so a batch never outgrows its
    /// 16-bit indices.
    static func vertexCount(of sprite: DrawList.Sprite) -> Int {
        guard let grid = sprite.warp else { return 4 }
        let split = 1 << min(max(sprite.subdivisionLevels, 0), WarpMesh.deepestLevel)
        return (grid.numberOfColumns * split + 1) * (grid.numberOfRows * split + 1)
    }

    func addWarp(_ grid: SKWarpGeometryGrid, _ sprite: DrawList.Sprite, to batch: inout Batch) {
        let mesh = WarpMesh(grid: grid, subdivisionLevels: sprite.subdivisionLevels)
        // Unit space is the sprite's frame, placed by its anchor point.
        let origin = CGPoint(x: -sprite.size.width * sprite.anchorPoint.x,
                             y: -sprite.size.height * sprite.anchorPoint.y)
        let uv = sprite.textureRect
        let colour = sprite.color
        let base: [Float] = [
            Float(colour.red), Float(colour.green), Float(colour.blue),
            Float(sprite.alpha),
            Float(sprite.colorBlendFactor),
        ]
        let first = UInt16(batch.vertices.count / Self.floatsPerVertex)
        batch.vertices.reserveCapacity(batch.vertices.count + mesh.vertexCount * Self.floatsPerVertex)
        for i in 0..<mesh.vertexCount {
            let unit = mesh.positions[i]
            let point = CGPoint(
                x: origin.x + CGFloat(unit.x) * sprite.size.width,
                y: origin.y + CGFloat(unit.y) * sprite.size.height
            ).applying(sprite.transform)
            let tex = mesh.texCoords[i]
            batch.vertices.append(Float(point.x))
            batch.vertices.append(Float(point.y))
            batch.vertices.append(Float(uv.minX + CGFloat(tex.x) * uv.width))
            batch.vertices.append(Float(uv.minY + CGFloat(tex.y) * uv.height))
            batch.vertices.append(contentsOf: base)
        }
        batch.indices.append(contentsOf: mesh.indices.map { $0 + first })
    }
}
