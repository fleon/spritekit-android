import Foundation
import SpriteKitShim
import simd

// Stand-ins for the backdrop ring, beside the ones in `Stubs.swift`.
//
// What is *real* in this target is `NightSkyNode.swift`, `BandedLayerNode.swift`,
// `Theme.swift` and `WorldTheme.swift`, symlinked out of `Source/` and
// compiled unmodified — 2,151 lines, the sky's whole shader among them. What
// is here is the three seams that would otherwise drag in the other seven
// backdrops and the whole light stack, each one a later ring's job.

// MARK: The live-backdrop protocol
//
// `Source/Common/Components/LiveBackdrop.swift` declares this, and would be
// the file to symlink — but it also holds `LiveBackdrops.make`, which names
// all eight backdrop classes, and `LiveBackdrops.bakeNormals`, which reaches
// into `SceneLighting`. Restating the protocol is the smaller seam: a
// declaration with no behaviour, and `NightSkyNode` stops compiling the
// moment the real one changes shape, which is the point.

protocol LiveBackdrop: SKNode {
    var ownsAmbient: Bool { get }
    func layout(_ area: CGRect, drawing drawn: CGRect)
    func planScenery()
    func bake(in view: SKView, pointsPerUnit: CGFloat)
    func focus(on board: CGRect)
    func keepClear(_ rects: [CGRect], safe: CGRect, variant: Int, animated: Bool)
    var reaches: [CGRect] { get }
    func pan(_ offset: CGFloat)
    func outlineBoard(_ silhouette: [CGRect])
    var screenLayers: [(sprite: SKSpriteNode, frame: CGRect)] { get }
    var overlay: SKNode? { get }
    var fliers: SKNode? { get }
    func touch(at point: CGPoint) -> Bool
}

extension LiveBackdrop {
    var ownsAmbient: Bool { false }
    func planScenery() {}
    var screenLayers: [(sprite: SKSpriteNode, frame: CGRect)] { [] }
    func keepClear(_ rects: [CGRect], safe: CGRect, variant: Int, animated: Bool) {}
    var reaches: [CGRect] { [] }
    func pan(_ offset: CGFloat) {}
    func outlineBoard(_ silhouette: [CGRect]) {}
    var overlay: SKNode? { nil }
    var fliers: SKNode? { nil }
    func touch(at point: CGPoint) -> Bool { false }
}

struct BackdropPlanInputs: Equatable {
    let area: CGRect
    let silhouette: [CGRect]
    let keptClear: [CGRect]
    var variant = 0
}

// MARK: The sky's share of the world light
//
// `Source/Utils/WorldLight.swift` is one enum over all seven lights, and its
// `function` switches over every case, so compiling it means compiling
// Castle's cloud shadows, the lawns' daylight, Kitchen's window, Ruins' dusk,
// Toy Box's room and the Mainframe's circuit, and `SceneLighting` under all
// of them. That is the lighting ring, not this one.
//
// The type itself is declared in `RigStubs.swift`, where the rigs need its
// instance side (`of(rig:)`, `call`, `uniforms()`) answering "unlit". These
// four are the sky's share, added to that same stand-in, copied verbatim
// from the real file (lines 389–396 and 443–456) because `NightSkyNode`
// calls `planetLight(turned:)` to light its planets, and they must turn with
// the starlight or the planets are lit from somewhere the sky is not. Copied
// rather than rewritten so the diff against the real file is empty when the
// lighting ring symlinks it and deletes both stand-ins.

extension WorldLight {
    /// A direction on the screen (x right, y up, z out of it, as a round
    /// thing's shading takes it) in the world (x right, y into the scene,
    /// z up), seen at the art's 45°.
    static func world(_ screen: SIMD3<Float>) -> SIMD3<Float> {
        let half = Float(0.5).squareRoot()
        return SIMD3(screen.x, (screen.y - screen.z) * half, (screen.y + screen.z) * half)
    }

    /// A direction in the world on the screen (the inverse of `world`).
    static func screen(_ world: SIMD3<Float>) -> SIMD3<Float> {
        let half = Float(0.5).squareRoot()
        return SIMD3(world.x, (world.y + world.z) * half, (world.z - world.y) * half)
    }

    /// The starlight's way in the world once the field has turned `angle`
    /// (radians, anticlockwise) from where the planets have their light:
    /// as high as that light, going round the board with the stars.
    static func starlight(turned angle: Float) -> SIMD3<Float> {
        let start = world(simd_normalize(DesignSystem.planetLight))
        let c = Float(Foundation.cos(Double(angle))), s = Float(Foundation.sin(Double(angle)))
        return simd_normalize(SIMD3(c * start.x - s * start.y, s * start.x + c * start.y, start.z))
    }

    /// The light the planets shade from, on the screen, once the field has
    /// turned `angle`: the starlight's.
    static func planetLight(turned angle: CGFloat) -> SIMD3<Float> {
        simd_normalize(screen(starlight(turned: Float(angle))))
    }
}
