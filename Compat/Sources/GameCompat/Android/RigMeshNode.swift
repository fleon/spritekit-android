import Macros
import SpriteKit

// The port's own `RigMeshNode`, standing where `Source/Game/Components/Rig/
// RigMeshNode.swift` does, with the same shape: `RigNode`, `SceneLighting`,
// the films and the scenes that prime shaders call it as they call the
// game's. The game's cuts each mesh into sprites of four triangles whose
// shader tests every pixel of their quad against them, as SpriteKit has no
// meshes; here each mesh is one sprite carrying its triangles as they are
// (`SKTriangleMesh`), which the renderer draws as geometry in the sprite's
// batch. A rig's meshes and regions share its texture, so a Switchling draws
// in a call or two instead of a call for every four triangles, each setting
// twelve uniforms over a quad of pixels it mostly discards.
//
// What each pixel shows is the game's: the texture times the node's alpha
// (`SKDefaultShading` with no tint), drawn in Spine's order, premultiplied;
// dimmed while asleep by `RigNode`'s regions' sums; flat-lit by a world's
// light (`lightFlat`) with `WorldLight.flatShader(.floor)`, the very shader
// the game's mesh writes out for it. A rig lit by its normal page isn't
// ported: `android-art.js` leaves the pages behind, so the game's
// `look(of:)` finds none here either and every Switchling's mesh is unlit.
// Keep the two in step.

/// Draws one of a rig's mesh attachments as its own triangles.
@NSCodingUnsupported
final class RigMeshNode: SKNode {
    /// Dims a sleeper as `RigNode`'s regions are dimmed (its `sleepShader`).
    nonisolated private static let dimShader = SKShader(
        source: """
        void main() {
            vec4 color = SKDefaultShading();
            float luma = dot(color.rgb, vec3(0.213, 0.715, 0.072));
            gl_FragColor = vec4(mix(vec3(luma), color.rgb, u_saturation) * u_brightness, color.a);
        }
        """,
        uniforms: [
            SKUniform(name: "u_saturation", float: DesignSystem.rigSleepSaturation),
            SKUniform(name: "u_brightness", float: DesignSystem.rigSleepBrightness),
        ]
    )

    /// How a rig's meshes are lit: plainly, or flat by a world's own light.
    private enum Look {
        case unlit
        case flat(WorldLight)
    }

    // Guarded by `lock`: meshes are made off the main thread as scenes load.
    nonisolated private static let lock = NSLock()
    /// Shaders a mesh drew with, not yet primed (`primePending`).
    nonisolated(unsafe) private static var pending: [SKShader] = []
    nonisolated(unsafe) private static var primed = Set<ObjectIdentifier>()

    /// The shader for `look`, or nil for the plain sprite's own, queued for
    /// priming the first time a mesh needs it. A flat light dims nothing.
    private static func shader(_ look: Look, dimmed: Bool) -> SKShader? {
        let made: SKShader
        switch look {
        case .unlit:
            guard dimmed else { return nil }
            made = dimShader
        case let .flat(world):
            made = world.flatShader(.floor)
        }
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(made)
        if !primed.contains(id), !pending.contains(where: { $0 === made }) { pending.append(made) }
        return made
    }

    private static func isPrimed(_ shader: SKShader?) -> Bool {
        guard let shader else { return true }
        lock.lock()
        defer { lock.unlock() }
        return primed.contains(ObjectIdentifier(shader))
    }

    /// The game's forgets its lit shaders and normal pages; here there are
    /// none (the dim shader is one, the flat ones `WorldLight`'s own).
    nonisolated static func forgetShaders(where forget: (String) -> Bool) {}

    /// Whether shaders may prime now: priming waits for the GPU, so the
    /// world list holds it while its pages slide (meshes wait hidden).
    static var primingGate: (() -> Bool)?

    /// Whether shaders made wait to be primed.
    static var hasPendingShaders: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    /// Builds the shaders meshes asked for since last time ahead of their
    /// first draw (`AttributeShaders`). Call it on the main thread. A scene
    /// that spreads its readying over frames (the title's tour) primes
    /// `limit` at a time.
    static func primePending(in view: SKView, limit: Int = .max) {
        guard hasPendingShaders, primingGate?() ?? true else { return }
        lock.lock()
        let shaders = Array(pending.prefix(limit))
        pending.removeFirst(shaders.count)
        lock.unlock()
        guard !shaders.isEmpty else { return }
        AttributeShaders.prime(shaders, in: view)
        lock.lock()
        primed.formUnion(shaders.map(ObjectIdentifier.init))
        lock.unlock()
    }

    /// Dimmed while asleep.
    var isDimmed = false {
        didSet {
            guard isDimmed != oldValue else { return }
            useShader()
        }
    }

    private var look = Look.unlit
    /// The shader it draws with now, by its look and whether it's dimmed.
    private var shader: SKShader? { Self.shader(look, dimmed: isDimmed) }
    /// Holds the sprite, hidden until its shader is primed and attached on
    /// the main thread: the rig's drawing shows and hides the mesh itself.
    private let holder = SKNode()
    /// The mesh, drawn as triangles (`SKTriangleMesh`).
    private let sprite: SKSpriteNode

    /// Whether its shader still waits to be primed or attached before it shows.
    var needsPriming: Bool { holder.isHidden }

    /// Primes whatever shaders wait (its own among them) and shows it. The
    /// rig calls it each frame it waits, before the frame draws; not in a
    /// scene fading out, as the game's doesn't.
    func prepare(in view: SKView) {
        guard holder.isHidden, !TransitionManager.isLeaving(scene) else { return }
        precondition(Thread.isMainThread)
        let shader = self.shader
        Self.primePending(in: view)
        guard Self.isPrimed(shader) else { return }
        sprite.shader = shader
        holder.isHidden = false
    }

    /// Draws with its shader, primed at once if the mesh is on screen, else
    /// hidden until it's primed.
    private func useShader() {
        _ = shader
        holder.isHidden = true
        if let view = scene?.view { prepare(in: view) }
    }

    /// Lights a mechanism's rig, which has no normal page, flat by `world`'s light.
    func lightFlat(_ world: WorldLight) {
        guard case .unlit = look else { return }
        look = .flat(world)
        useShader()
    }

    /// The vertices it was last laid on.
    private var last: [CGPoint] = []

    /// `mesh`'s image lies at `frame` (in pixels, y down) in `texture`, which
    /// the sprite samples whole. `rig` and `slotZ` are the game's: its
    /// triangles draw in one sprite, in order, at its slot's own depth.
    init(mesh: RigData.Mesh, frame: CGRect, texture: SKTexture, rig: String, slotZ: CGFloat = DesignSystem.rigSlotZ) {
        let size = texture.size()
        let width = max(size.width, 1), height = max(size.height, 1)
        let uvs = mesh.uvs.map { uv in
            SIMD2(Float((frame.minX + uv.x * frame.width) / width), Float(1 - (frame.minY + uv.y * frame.height) / height))
        }
        let count = mesh.uvs.count
        var indices: [UInt16] = []
        if count <= Int(UInt16.max) + 1 {
            for k in stride(from: 0, to: mesh.triangles.count - 2, by: 3) {
                let corners = mesh.triangles[k..<k + 3]
                if corners.allSatisfy({ $0 >= 0 && $0 < count }) { indices.append(contentsOf: corners.map { UInt16($0) }) }
            }
        }
        sprite = SKSpriteNode(texture: texture, size: sz(1, 1))
        sprite.anchorPoint = .zero
        sprite.triangleMesh = SKTriangleMesh(positions: Array(repeating: .zero, count: count), texCoords: uvs, indices: indices)
        // Nothing laid yet.
        sprite.isHidden = true
        super.init()
        addChild(holder)
        holder.addChild(sprite)
        // Unlit and awake, it draws as a plain sprite does, with nothing to prime.
        holder.isHidden = !Self.isPrimed(shader)
    }

    /// Lays the triangles on `points`, the mesh's vertices in the rig's units,
    /// at `unit` points each.
    func update(_ points: [CGPoint], unit: CGFloat) {
        if last.count != points.count { last = Array(repeating: pt(CGFloat.nan, CGFloat.nan), count: points.count) }
        guard last.indices.contains(where: { last[$0] != points[$0] }) else { return }
        for i in points.indices { last[i] = points[i] }
        guard var mesh = sprite.triangleMesh, mesh.positions.count == points.count else { return }
        // Let go of the sprite's copy, so the positions are written in place.
        sprite.triangleMesh = nil
        let scale = Float(unit)
        var low = SIMD2<Float>(repeating: .infinity), high = SIMD2<Float>(repeating: -.infinity)
        for i in points.indices {
            let at = SIMD2(Float(points[i].x) * scale, Float(points[i].y) * scale)
            mesh.positions[i] = at
            low = simd_min(low, at)
            high = simd_max(high, at)
        }
        mesh.touch()
        sprite.triangleMesh = mesh
        guard low.x.isFinite, low.y.isFinite, high.x.isFinite, high.y.isFinite else {
            sprite.isHidden = true
            return
        }
        // The frame only bounds the mesh, for culling.
        let size = simd_max(high - low, SIMD2(repeating: Float(DesignSystem.rigMeshPadding)))
        sprite.isHidden = false
        sprite.size = sz(CGFloat(size.x), CGFloat(size.y))
        sprite.anchorPoint = pt(CGFloat(-low.x / size.x), CGFloat(-low.y / size.y))
    }
}
