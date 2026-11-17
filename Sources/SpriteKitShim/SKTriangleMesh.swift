#if SPRITEKIT_SHIM
import Foundation

/// Triangles a sprite draws instead of its quad (`SKSpriteNode.triangleMesh`).
/// The shim's own, not SpriteKit's: SpriteKit has no meshes, which is why a
/// skeletal rig on Apple may test every pixel of a quad against its
/// triangles in a shader. On Android a game can hand its triangles over as
/// they are, so the renderer draws them in the sprite's batch: a rig's
/// meshes and regions, all on one texture, merge into a draw or two.
///
/// The sprite's texture, colour, alpha, blend mode and shader apply as they
/// do to its quad. Its frame (size and anchor point) only bounds the mesh,
/// for culling; the mesh draws where its positions say.
public struct SKTriangleMesh {
    /// Each vertex in the sprite's own space, in points.
    public var positions: [SIMD2<Float>]
    /// Each vertex's place in the sprite's texture, in its own 0…1 (y up).
    public var texCoords: [SIMD2<Float>]
    /// Three a triangle, into `positions`, in the order they draw.
    public var indices: [UInt16]
    /// Changes whenever the mesh does (`touch()`), so a rasterized effect
    /// node holding it knows its kept pixels are stale (`DrawList.digest`).
    public private(set) var generation: UInt64

    public init(positions: [SIMD2<Float>], texCoords: [SIMD2<Float>], indices: [UInt16]) {
        precondition(positions.count == texCoords.count, "SKTriangleMesh: one texture coordinate a vertex")
        precondition(indices.allSatisfy { Int($0) < positions.count }, "SKTriangleMesh: indices past the vertices")
        self.positions = positions
        self.texCoords = texCoords
        self.indices = indices
        generation = Self.nextGeneration()
    }

    /// Marks the mesh changed after its positions were written in place.
    public mutating func touch() {
        generation = Self.nextGeneration()
    }

    // Meshes change on the game's thread alone.
    nonisolated(unsafe) private static var generations: UInt64 = 0
    private static func nextGeneration() -> UInt64 {
        generations &+= 1
        return generations
    }
}

#endif
