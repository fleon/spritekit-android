import Foundation
import SpriteKitShim

// Stand-ins for the lighting and rasterising the board's own component nodes
// reach for. Each is a seam that belongs to a ring of its own; naming them
// here is what lets `TileNode`, `GoalNode`, `BoardFrameNode`,
// `LiftControlNode` and `SpriteHelpers` be the real, unmodified files.
//
// None of them changes what the board *is*, only how it is shaded:
//
//   - `LiveBackdrops` is named by `forgetTextures` alone, to drop the
//     shaders that hold a backdrop's bake. With none held there is nothing
//     to forget. (`SceneLighting`, `WorldLight` and `RigMeshNode` stood in
//     here too until the rig ring brought real ones; the board's spellings
//     of the first two are folded into `RigStubs.swift` now.)

enum LiveBackdrops {
    static func forgetBakeShaders(where forget: (String) -> Bool) {}
}

// `CGContext`, `CGColor`, `UIColor.cgColor`, `SurfaceTexture` and
// `UIColor.cacheKey` stood in here until the CGContext ring brought real
// ones: the first three are the shim's (`BitmapContext`,
// `CoreGraphicsCompat.swift`), the last two are Source/Utils/SurfaceTexture.swift
// itself. So `TileNode`'s height dots are drawn now, not handed back empty.

/// A cracked brick. The real one is a shader that splits the brick into six
/// pieces from a point struck near its middle and breaks them away one by
/// one; it is drawn in code, not painted, so it comes with the shader ring
/// along with the currents, the hedges and the swap pads. Until then a
/// crumbling floor shows its own brick, uncracked, and simply goes when it
/// crumbles.
final class CrumbleNode: SKSpriteNode {
    init(brick: String, cell: CGFloat, seed: Float, light: WorldLight?) {
        super.init(texture: txtr(brick), size: sz(cell))
        slice(brick)
    }

    func setGone(_ gone: Bool, animated: Bool) {
        alpha = gone ? 0 : 1
    }

    func setStood(_ stood: Bool, animated: Bool) {}
}
