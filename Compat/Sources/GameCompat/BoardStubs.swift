import Foundation
import SpriteKitShim

// Stand-ins for the lighting and rasterising the board's own component nodes
// reach for. Each is a seam that belongs to a ring of its own; naming them
// here is what lets `TileNode`, `GoalNode`, `BoardFrameNode`,
// `LiftControlNode` and `SpriteHelpers` be the real, unmodified files.
//
// None of them changes what the board *is*, only how it is shaded:
//
//   - `SurfaceTexture` rasterises CoreGraphics into a texture. `CGContext`
//     records but does not fill yet (see Android/README.md), so this hands
//     back nothing to draw. The only caller on this slice is `TileNode`'s
//     height dots, which only a raised tile shows.
//   - `LiveBackdrops` is named by `forgetTextures` alone, to drop the
//     shaders that hold a backdrop's bake. With none held there is nothing
//     to forget. (`SceneLighting`, `WorldLight` and `RigMeshNode` stood in
//     here too until the rig ring brought real ones; the board's spellings
//     of the first two are folded into `RigStubs.swift` now.)

enum LiveBackdrops {
    static func forgetBakeShaders(where forget: (String) -> Bool) {}
}

/// The CoreGraphics drawing surface `SurfaceTexture` hands its callers.
/// `CGPath` records in the shim and nothing fills or strokes it yet (see
/// "What is deliberately unfinished" in Android/README.md), so this records
/// nothing either — it exists so the drawing closures in the files compiled
/// here are real code rather than something edited out. It covers only what
/// those closures call, and goes when the rasteriser lands.
final class CGContext {
    func setFillColor(_ color: CGColor) {}
    func fillEllipse(in rect: CGRect) {}
}

/// `UIColor.cgColor`'s type. Opaque: nothing on this slice reads it.
final class CGColor {}

extension UIColor {
    var cgColor: CGColor { CGColor() }
}

enum SurfaceTexture {
    static func texture(
        size: CGSize,
        padding: CGFloat = 0,
        scale: CGFloat? = nil,
        key: String? = nil,
        data: Bool = false,
        draw: (CGContext, CGRect) -> Void
    ) -> SKTexture {
        SKTexture(color: .clear, size: size)
    }
}

extension UIColor {
    /// Real one lives in SurfaceTexture.swift, where it keys the cache.
    var cacheKey: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.3f-%.3f-%.3f-%.3f", Double(r), Double(g), Double(b), Double(a))
    }
}

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
