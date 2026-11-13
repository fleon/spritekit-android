import Foundation
import SpriteKitShim

// The lighting ring, stood in for.
//
// The rig files reach outside themselves for exactly one thing: how a lit
// world's light is spliced into a shader. `RigMeshNode` composes its GLSL
// out of `SceneLighting`/`WorldLight` snippets, and `RigNode.light(theme:)`
// hands a mechanism's sprites to `SceneLighting`. Everything else they need
// is here for real.
//
// The real files are `Source/Utils/SceneLighting.swift` (465 lines) and
// `Source/Utils/WorldLight.swift` (717), and between them they pull in
// `LawnLight`, `DuskLight`, `CircuitLight`, `RoomLight`, `WindowLight`,
// `Theme`, `SceneLayout`, `MediaClock` and `BuildGate` — the whole lighting
// and layout rings, which belong with the backdrops rather than with a rig.
//
// So this stands in, and the shape of the stand-in is chosen so the rigs
// take a path that is entirely their own real code: `WorldLight.of(rig:)`
// answers nil and no `Rig<Name>Normal.png` is packed, so every rig resolves
// to `RigMeshNode.Look.unlit` — the branch where no lighting GLSL is spliced
// in at all. What a rig draws on Android today is therefore `RigMeshNode`'s
// own shader, unmodified, not a lit shader with fake light in it.
//
// `Pose.rest` and `decode` are copied verbatim from the real file, since
// they are pure one-line GLSL and copying them keeps the two honest.
enum SceneLighting {
    enum Pose {
        case floor
        case upright

        var rest: String { self == .floor ? "vec3(0.0, 0.0, 1.0)" : "vec3(0.0, -1.0, 0.0)" }
    }

    static func decode(_ sample: String) -> String {
        "vec3 n = \(sample).rgb / max(\(sample).a, 0.004) * 2.0 - 1.0; float z = (\(sample).a - 0.75) * 4.0;"
    }

    /// Unreachable while no rig is lit; neutral rather than plausible, so a
    /// shader that somehow reaches it draws the art as painted instead of
    /// quietly inventing a light.
    static let function = """
    vec3 sceneLight(vec3 rgb, float alpha) { return rgb; }
    """

    static func call(_ rgb: String, _ alpha: String, at: String = "gl_FragCoord.xy") -> String {
        "sceneLight(\(rgb), \(alpha))"
    }

    static func uniforms() -> [SKUniform] { [] }

    /// The real one gives a mechanism's sprites a lit shader. Nothing here
    /// has a normal page, and `RigNode.light(theme:)` returns before this is
    /// reached anyway.
    static func light(_ sprite: SKSpriteNode, normal: SKTexture, key: String, theme: WorldTheme, pose: Pose = .floor) {}

    /// The board's own spelling of it: the real one relights a painted piece
    /// from its asset's normal map, and only ever within ±15% of the light it
    /// was painted with (`DesignSystem.lightRelativeRange`). Left out, the
    /// piece shows the light it was painted with, which is why the board
    /// reads correctly unlit.
    static func light(_ node: SKSpriteNode, asset: String, theme: WorldTheme) {}

    /// Drops the lit shaders holding an asset's normal map. None is held.
    static func forgetShaders(where forget: (String) -> Bool) {}
}

extension SKSpriteNode {
    /// Real one hands the sprite the normal map `SceneLighting` lights it from.
    func takesNormals(of asset: String) {}
}

/// A world's own light. The real one is an enum of seven, each with its own
/// GLSL; none is wired on Android yet, so `of(rig:)` answers nil and the
/// rigs light themselves plainly.
enum WorldLight: Hashable {
    case unlit

    static func of(rig name: String) -> WorldLight? { nil }

    /// By world, which is how the board asks. Nil means "no light of its
    /// own" — the real answer for Sunny Garden and the other worlds whose
    /// board takes the light it was painted with.
    static func of(_ theme: WorldTheme) -> WorldLight? { nil }

    var function: String { SceneLighting.function }

    func call(_ rgb: String, _ alpha: String, at: String = "gl_FragCoord.xy") -> String {
        SceneLighting.call(rgb, alpha, at: at)
    }

    func uniforms() -> [SKUniform] { [] }
}
