import Foundation
import Macros
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
#endif

/// Draws one of a rig's attachments (a mesh, or a region as its quad) as its
/// own triangles, in the order Spine draws them.
///
/// SpriteKit has no meshes, so on Apple's every run of `trianglesPerSprite`
/// triangles is a sprite over their bounds whose shader tests each pixel
/// against them and samples the rig's texture where it lands (after the mesh
/// renderer of github.com/maxgribov/Spine, MIT). Each triangle travels as
/// three per-node attributes in the sprite's own 0…1 space, so it draws the
/// same under crops, effects and snapshots. On the shim the mesh is one
/// sprite carrying its triangles as they are (`SKTriangleMesh`), which the
/// renderer draws as geometry in the sprite's batch.
///
/// A shader with attributes must be primed before it draws
/// (`AttributeShaders`), so a mesh stays hidden until its shader is: the rig
/// that holds it calls `prepare(in:)` each frame it waits.
@NSCodingUnsupported
public final class RigMeshNode: SKNode {
    /// How a mesh's pixels are shaded, by a game's own light or look; meshes
    /// with the same `key` share one shader.
    public struct Shading: @unchecked Sendable {
        public let key: String
        #if SPRITEKIT_SHIM
        /// The sprite's shader, or nil for a plain sprite's own.
        let shader: () -> SKShader?

        public init(key: String, shader: @escaping () -> SKShader?) {
            self.key = key
            self.shader = shader
        }

        public static let plain = Shading(key: "plain") { nil }
        #else
        /// GLSL ahead of `main` (functions, constants).
        let declarations: String
        /// GLSL run on each texel a triangle covers: `color` (premultiplied,
        /// tinted) and `uv` are in scope, and `a_tN_0`, `a_tN_1`, `a_tN_2` name
        /// the triangle's planes (`(l1, u.x)`, `(l2, u.y)`, `(v, u.z)`, each
        /// over the sprite's 0…1 space), whose texture slopes turn a normal map.
        let texel: String
        /// GLSL run on the composited `result` before it's written.
        let finish: String
        let uniforms: () -> [SKUniform]

        public init(key: String, declarations: String = "", texel: String = "", finish: String = "", uniforms: @escaping () -> [SKUniform] = { [] }) {
            self.key = key
            self.declarations = declarations
            self.texel = texel
            self.finish = finish
            self.uniforms = uniforms
        }

        public static let plain = Shading(key: "plain")
        #endif
    }

    /// Triangles a sprite tests each pixel against (Apple's). Set it before the first mesh.
    public static var trianglesPerSprite = 4
    /// Points a run's sprite reaches past its triangles, so edges aren't cut.
    public static var padding: CGFloat = 0.5
    /// Whether a mesh may prepare its shader in `scene` now (a game may hold
    /// it while a scene fades out and the next builds off the main thread).
    public static var mayPrepare: ((SKScene?) -> Bool)?
    /// Whether shaders may prime now: priming waits for the GPU, so a game
    /// may hold it while something slides (meshes wait hidden).
    public static var primingGate: (() -> Bool)?

    private struct ShaderState {
        /// Every shader made, by key, each the first time a mesh needs it.
        var shaders: [String: SKShader?] = [:]
        /// Shaders made but not yet primed (`primePending`).
        var pending: [SKShader] = []
        var primed = Set<ObjectIdentifier>()
    }

    // Locked: meshes are made off the main thread as scenes load.
    nonisolated private static let shaderState = Locked(ShaderState())

    /// The shader for `shading` (tinted per vertex or not), made and queued
    /// for priming the first time a mesh needs it.
    private static func shader(_ shading: Shading, tinted: Bool) -> SKShader? {
        let key = tinted ? "\(shading.key) tinted" : shading.key
        if let shader = shaderState.withLock({ $0.shaders[key] }) { return shader }
        let made = make(shading, tinted: tinted)
        return shaderState.withLock { state in
            if let raced = state.shaders[key] { return raced }
            state.shaders[key] = made
            if let made { state.pending.append(made) }
            return made
        }
    }

    private static func isPrimed(_ shader: SKShader?) -> Bool {
        guard let shader else { return true }
        return shaderState.withLock { $0.primed.contains(ObjectIdentifier(shader)) }
    }

    /// Forgets the shaders whose shading keys `forget` picks: each primed
    /// shader holds megabytes of buffers. Meshes still showing keep theirs;
    /// the next mesh to need one makes and primes it again.
    public nonisolated static func forgetShaders(where forget: (String) -> Bool) {
        shaderState.withLock { state in
            let dropped = state.shaders.filter { forget($0.key.hasSuffix(" tinted") ? String($0.key.dropLast(7)) : $0.key) }
            for key in dropped.keys { state.shaders[key] = nil }
            let ids = Set(dropped.values.compactMap { $0.map(ObjectIdentifier.init) })
            state.primed.subtract(ids)
            state.pending.removeAll { ids.contains(ObjectIdentifier($0)) }
        }
    }

    /// Whether shaders made wait to be primed.
    public static var hasPendingShaders: Bool {
        shaderState.withLock { !$0.pending.isEmpty }
    }

    /// Primes the shaders made since last time (`AttributeShaders`), `limit`
    /// at a time: each costs a frame its translation into Metal. Call it on
    /// the main thread.
    public static func primePending(in view: SKView, limit: Int = .max) {
        guard hasPendingShaders, primingGate?() ?? true else { return }
        let shaders = shaderState.withLock { state in
            let shaders = Array(state.pending.prefix(limit))
            state.pending.removeFirst(shaders.count)
            return shaders
        }
        guard !shaders.isEmpty else { return }
        AttributeShaders.prime(shaders, in: view)
        shaderState.withLock { $0.primed.formUnion(shaders.map(ObjectIdentifier.init)) }
    }

    /// How it's shaded; changing it hides it until the new shader is primed.
    public var shading: Shading {
        didSet {
            guard shading.key != oldValue.key else { return }
            useShader()
        }
    }

    /// Whether its colour carries red, green and blue as well as alpha.
    public let tinted: Bool
    /// The shader it draws with now.
    private var shader: SKShader? { Self.shader(shading, tinted: tinted) }
    /// Holds the sprites, hidden until their shader is primed and attached
    /// on the main thread: the rig shows and hides the mesh itself.
    private let holder = SKNode()

    /// Whether its shader still waits to be primed or attached before it shows.
    public var needsPriming: Bool { holder.isHidden }

    /// Primes whatever shaders wait (its own among them) and shows it.
    public func prepare(in view: SKView) {
        guard holder.isHidden, Self.mayPrepare?(scene) ?? true else { return }
        let shader = self.shader
        Self.primePending(in: view)
        guard Self.isPrimed(shader) else { return }
        attach(shader)
        holder.isHidden = false
    }

    /// Draws with its shader, primed at once if the mesh is on screen (it has
    /// never drawn, so its buffers can grow), else hidden until it's primed.
    private func useShader() {
        // Attaching a shared shader off the main thread races SpriteKit's
        // rendering and priming: meshes built there wait for `prepare`.
        _ = shader
        holder.isHidden = true
        if let view = scene?.view { prepare(in: view) }
    }

    /// The vertices it was last laid on.
    private var last: [CGPoint] = []
    private var lastTint = SIMD4<Float>(repeating: -1)

    #if SPRITEKIT_SHIM
    /// The shim tints by the sprite's colour: alpha as its alpha, and a
    /// tinted mesh with no shading of its own red, green and blue through `tint`.
    private static let tint = SKShader(source: """
        void main() {
            vec4 color = texture2D(u_texture, v_tex_coord);
            gl_FragColor = vec4(color.rgb * v_color_mix.rgb, color.a) * v_color_mix.a;
        }
        """)

    private static func make(_ shading: Shading, tinted: Bool) -> SKShader? {
        shading.shader() ?? (tinted ? tint : nil)
    }

    /// The mesh, drawn as triangles.
    private let sprite: SKSpriteNode

    private func attach(_ shader: SKShader?) {
        sprite.shader = shader
    }

    /// `uvs` place each vertex in `texture` (0…1, y down), which the sprite
    /// samples whole; its triangles draw in one sprite, in order.
    public init(uvs: [CGPoint], triangles: [Int], texture: SKTexture, shading: Shading = .plain, tinted: Bool = false, slotZ: CGFloat = 0) {
        self.shading = shading
        self.tinted = tinted
        let count = uvs.count
        var indices: [UInt16] = []
        if count <= Int(UInt16.max) + 1 {
            for k in stride(from: 0, to: triangles.count - 2, by: 3) {
                let corners = triangles[k..<k + 3]
                if corners.allSatisfy({ $0 >= 0 && $0 < count }) { indices.append(contentsOf: corners.map { UInt16($0) }) }
            }
        }
        sprite = SKSpriteNode(texture: texture, size: CGSize(width: 1, height: 1))
        sprite.anchorPoint = .zero
        sprite.triangleMesh = SKTriangleMesh(
            positions: Array(repeating: .zero, count: count),
            texCoords: uvs.map { SIMD2(Float($0.x), Float(1 - $0.y)) },
            indices: indices
        )
        // Nothing laid yet.
        sprite.isHidden = true
        super.init()
        addChild(holder)
        holder.addChild(sprite)
        // Plain, it draws as a plain sprite does, with nothing to prime.
        holder.isHidden = !Self.isPrimed(shader)
    }

    /// Tints the part (straight r, g, b, a, 0…1).
    public func setColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) {
        let tint = SIMD4(Float(r), Float(g), Float(b), Float(a))
        guard tint != lastTint else { return }
        lastTint = tint
        sprite.alpha = a
        if tinted { sprite.color = SKColor(red: r, green: g, blue: b, alpha: 1) }
    }

    /// Lays the triangles on `points`, the part's vertices in the rig's units,
    /// at `unit` points each.
    public func update(_ points: [CGPoint], unit: CGFloat = 1) {
        if last.count != points.count { last = Array(repeating: CGPoint(x: CGFloat.nan, y: CGFloat.nan), count: points.count) }
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
            low = pointwiseMin(low, at)
            high = pointwiseMax(high, at)
        }
        mesh.touch()
        sprite.triangleMesh = mesh
        guard low.x.isFinite, low.y.isFinite, high.x.isFinite, high.y.isFinite else {
            sprite.isHidden = true
            return
        }
        // The frame only bounds the mesh, for culling.
        let size = pointwiseMax(high - low, SIMD2(repeating: Float(Self.padding)))
        sprite.isHidden = false
        sprite.size = CGSize(width: CGFloat(size.x), height: CGFloat(size.y))
        sprite.anchorPoint = CGPoint(x: CGFloat(-low.x / size.x), y: CGFloat(-low.y / size.y))
    }
    #else
    /// Apple's tints a tinted mesh per sprite, by an attribute.
    private static let tintName = "a_tint"
    private static let perSprite = trianglesPerSprite
    private static let names: [String] = (0..<perSprite).flatMap { t in (0..<3).map { "a_t\(t)_\($0)" } }
    /// How far past its edges (in barycentric terms) a triangle still covers
    /// a pixel, so neighbours drawn by different sprites leave no cracks.
    private static let overlap: Float = 1e-4
    /// A triangle no pixel falls in: its first barycentric is always -1.
    private static let none = SIMD4<Float>(0, 0, -1, 0)

    private static func make(_ shading: Shading, tinted: Bool) -> SKShader? {
        let triangles = (0..<perSprite).map { t in
            let texel = shading.texel.isEmpty ? "" : shading.texel.replacingOccurrences(of: "a_tN_", with: "a_t\(t)_")
            return """
                {
                    float l1 = dot(a_t\(t)_0.xyz, p), l2 = dot(a_t\(t)_1.xyz, p);
                    if (l1 >= -edge && l2 >= -edge && 1.0 - l1 - l2 >= -edge) {
                        vec2 uv = vec2(dot(vec3(a_t\(t)_0.w, a_t\(t)_1.w, a_t\(t)_2.w), p), dot(a_t\(t)_2.xyz, p));
                        vec4 color = texture2D(u_texture, uv)\(tinted ? " * \(tintName)" : "") * v_color_mix.a;
            \(texel)
                        result = color + result * (1.0 - color.a);
                    }
                }
            """
        }.joined(separator: "\n")
        let shader = SKShader(source: """
            \(shading.declarations)
            void main() {
                float edge = \(overlap);
                vec3 p = vec3(v_tex_coord, 1.0);
                vec4 result = vec4(0.0);
            \(triangles)
                if (result.a <= 0.0) discard;
            \(shading.finish)
                gl_FragColor = result;
            }
            """, uniforms: shading.uniforms())
        shader.attributes = (names + (tinted ? [tintName] : [])).map { SKAttribute(name: $0, type: .vectorFloat4) }
        return shader
    }

    private let triangles: [Int]
    /// Each vertex's place in the whole texture (0…1, y up).
    private let uvs: [SIMD2<Float>]
    private var sprites: [SKSpriteNode] = []
    private var values: [[SKAttributeValue]] = []
    private var tints: [SKAttributeValue] = []

    private func attach(_ shader: SKShader?) {
        for sprite in sprites { sprite.shader = shader }
    }

    /// `uvs` place each vertex in `texture` (0…1, y down), which every sprite
    /// samples whole; its runs share `slotZ`, its slot's depth. A `tinted`
    /// mesh takes red, green and blue from `setColor` too.
    public init(uvs: [CGPoint], triangles: [Int], texture: SKTexture, shading: Shading = .plain, tinted: Bool = false, slotZ: CGFloat = 0) {
        self.shading = shading
        self.tinted = tinted
        self.uvs = uvs.map { SIMD2(Float($0.x), Float(1 - $0.y)) }
        let count = uvs.count
        var valid: [Int] = []
        for k in stride(from: 0, to: triangles.count - 2, by: 3) {
            let corners = triangles[k..<k + 3]
            if corners.allSatisfy({ $0 >= 0 && $0 < count }) { valid.append(contentsOf: corners) }
        }
        self.triangles = valid
        super.init()
        _ = shader
        holder.isHidden = true
        addChild(holder)

        let runs = (valid.count / 3 + Self.perSprite - 1) / Self.perSprite
        for run in 0..<runs {
            let sprite = SKSpriteNode(texture: texture)
            sprite.anchorPoint = .zero
            // In Spine's order where they overlap (a part folding over itself).
            sprite.zPosition = CGFloat(run) * slotZ / CGFloat(runs + 1)
            let row = Self.names.map { _ in SKAttributeValue(vectorFloat4: Self.none) }
            for (name, value) in zip(Self.names, row) { sprite.setValue(value, forAttribute: name) }
            if tinted {
                let tint = SKAttributeValue(vectorFloat4: SIMD4(1, 1, 1, 1))
                sprite.setValue(tint, forAttribute: Self.tintName)
                tints.append(tint)
            }
            holder.addChild(sprite)
            sprites.append(sprite)
            values.append(row)
        }
    }

    /// Tints the part (straight r, g, b, a, 0…1): untinted, by its alpha
    /// alone; tinted, premultiplied per sprite.
    public func setColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) {
        let tint = SIMD4(Float(r), Float(g), Float(b), Float(a))
        guard tint != lastTint else { return }
        lastTint = tint
        guard tinted else {
            alpha = a
            return
        }
        let premultiplied = SIMD4(tint.x * tint.w, tint.y * tint.w, tint.z * tint.w, tint.w)
        for (sprite, value) in zip(sprites, tints) {
            value.vectorFloat4Value = premultiplied
            sprite.setValue(value, forAttribute: Self.tintName)
        }
    }

    /// Lays the triangles on `points`, the part's vertices in the rig's units,
    /// at `unit` points each.
    public func update(_ points: [CGPoint], unit: CGFloat = 1) {
        guard points.count >= uvs.count else { return }
        if last.count != points.count { last = Array(repeating: CGPoint(x: CGFloat.nan, y: CGFloat.nan), count: points.count) }
        guard last.indices.contains(where: { last[$0] != points[$0] }) else { return }
        for i in points.indices { last[i] = points[i] }
        let pad = Float(Self.padding)
        let scale = Float(unit)
        let count = triangles.count / 3
        for (run, sprite) in sprites.enumerated() {
            let first = run * Self.perSprite, end = min(first + Self.perSprite, count)
            var low = SIMD2<Float>(repeating: .infinity), high = SIMD2<Float>(repeating: -.infinity)
            for k in first * 3..<end * 3 {
                let at = position(points[triangles[k]], scale)
                low = pointwiseMin(low, at)
                high = pointwiseMax(high, at)
            }
            guard low.x.isFinite, low.y.isFinite, high.x.isFinite, high.y.isFinite else {
                sprite.isHidden = true
                continue
            }
            low -= pad
            high += pad
            let size = high - low
            sprite.isHidden = false
            sprite.position = CGPoint(x: CGFloat(low.x), y: CGFloat(low.y))
            sprite.size = CGSize(width: CGFloat(size.x), height: CGFloat(size.y))
            for slot in 0..<Self.perSprite {
                let triangle = first + slot
                let row = triangle < end ? coefficients(triangle, points, scale, low, size) : nil
                set(row?.0 ?? Self.none, run, slot * 3, sprite)
                set(row?.1 ?? Self.none, run, slot * 3 + 1, sprite)
                set(row?.2 ?? Self.none, run, slot * 3 + 2, sprite)
            }
        }
    }

    private func set(_ value: SIMD4<Float>, _ run: Int, _ index: Int, _ sprite: SKSpriteNode) {
        values[run][index].vectorFloat4Value = value
        sprite.setValue(values[run][index], forAttribute: Self.names[index])
    }

    private func position(_ point: CGPoint, _ scale: Float) -> SIMD2<Float> {
        SIMD2(Float(point.x) * scale, Float(point.y) * scale)
    }

    /// The triangle's barycentrics and texture coordinates as planes over its
    /// sprite's 0…1 space `s`: l1, l2, u and v are each `dot(_, (s, 1))`,
    /// packed as (l1, u.x), (l2, u.y), (v, u.z).
    private func coefficients(
        _ triangle: Int, _ points: [CGPoint], _ scale: Float, _ low: SIMD2<Float>, _ size: SIMD2<Float>
    ) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)? {
        let i0 = triangles[triangle * 3], i1 = triangles[triangle * 3 + 1], i2 = triangles[triangle * 3 + 2]
        let q0 = position(points[i0], scale)
        let e1 = position(points[i1], scale) - q0, e2 = position(points[i2], scale) - q0
        let det = e1.x * e2.y - e1.y * e2.x
        guard abs(det) > .ulpOfOne else { return nil }
        // p = low + s * size, and p - q0 = l1 * e1 + l2 * e2.
        let o = low - q0
        let l1 = SIMD3(size.x * e2.y, -size.y * e2.x, o.x * e2.y - o.y * e2.x) / det
        let l2 = SIMD3(-size.x * e1.y, size.y * e1.x, e1.x * o.y - e1.y * o.x) / det
        let uv0 = uvs[i0], du1 = uvs[i1] - uv0, du2 = uvs[i2] - uv0
        let u = l1 * du1.x + l2 * du2.x + SIMD3(0, 0, uv0.x)
        let v = l1 * du1.y + l2 * du2.y + SIMD3(0, 0, uv0.y)
        return (SIMD4(l1, u.x), SIMD4(l2, u.y), SIMD4(v, u.z))
    }
    #endif
}
