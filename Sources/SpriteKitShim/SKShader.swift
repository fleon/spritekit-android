#if SPRITEKIT_SHIM
import Foundation
import PlatformServices

/// A fragment shader attached to a node.
///
/// SpriteKit takes GLSL ES 1.0 with its own preamble (`u_time`, `v_tex_coord`,
/// `u_texture`, `SKDefaultShading()`). A game may have dozens of these, so
/// the shim keeps the source verbatim and the renderer rewrites the preamble
/// to GLSL ES 3.0 at upload — the dialect change is textual and belongs in
/// one place, not in every shader file.
///
/// Open, as SpriteKit's is: a game may subclass it to wrap one shader and its
/// uniforms in a type, calling `super.init(source:uniforms:)` and setting the
/// uniforms from properties.
open class SKShader: @unchecked Sendable {
    open var source: String? { didSet { revision &+= 1 } }
    open var uniforms: [SKUniform] { didSet { revision &+= 1 } }
    open var attributes: [SKAttribute] = [] { didSet { revision &+= 1 } }

    /// Set by the renderer once compiled and linked.
    public var glProgram: UInt32 = 0
    /// Counts changes to what the program is built from (its source, which
    /// uniforms and attributes it declares), so a program built ahead of the
    /// first draw is built again if they change before it.
    public private(set) var revision = 0
    /// `revision` as it stood when `glProgram` was built.
    public var glProgramRevision = 0

    // The designated initialisers are main-actor isolated (and
    // `@preconcurrency`, so a shader may still be made on a building thread,
    // as below). A game builds main-actor by default, and a subclass in it
    // that has initialisers of its own gets Swift's stubs for these two,
    // isolated as the subclass is: a nonisolated original here makes those
    // stubs an isolation mismatch and the subclass fails to compile.
    // SpriteKit's own, Objective-C, has no stubs to disagree.
    @preconcurrency @MainActor
    public init(source: String) {
        self.source = source
        uniforms = []
        Self.noteMade(self)
    }

    @preconcurrency @MainActor
    public init(source: String, uniforms: [SKUniform]) {
        self.source = source
        self.uniforms = uniforms
        Self.noteMade(self)
    }

    // MARK: Shaders a build made, for their programs ahead of the first draw
    //
    // SpriteKit compiles a shader the first time it draws, as the renderer
    // here does; a phone's driver takes up to a fifth of a second a program
    // the first time, so a scene's dozens stalled its warm-up draw for
    // seconds. A scene built on a thread of its own that preloads its
    // textures there once it's built has finished the shaders made on that
    // thread by then: `SKTexture.preload` hands them to the renderer
    // (`programWarmer`), which builds their programs a few a frame while a
    // loading screen still shows.

    private static let made = Locked([UInt: [Weak]]())
    /// What one thread may hold before its oldest are let go: a thread that
    /// makes shaders and never preloads mustn't keep them all.
    static let madeLimit = 4096

    private struct Weak { weak var shader: SKShader? }

    private static func noteMade(_ shader: SKShader) {
        guard !Thread.isMainThread else { return }
        let thread = UInt(bitPattern: pthread_self())
        made.withLock { made in
            var list = made[thread] ?? []
            if list.count >= madeLimit { list.removeAll { $0.shader == nil } }
            if list.count >= madeLimit { list.removeFirst(list.count - madeLimit + 1) }
            list.append(Weak(shader: shader))
            made[thread] = list
        }
    }

    /// The shaders made on the calling thread since it last asked, still alive.
    public static func takeMadeOnThisThread() -> [SKShader] {
        let thread = UInt(bitPattern: pthread_self())
        let list = made.withLock { $0.removeValue(forKey: thread) ?? [] }
        return list.compactMap(\.shader)
    }

    /// Builds the programs of shaders a build made, ahead of their first
    /// draw; the renderer installs it. Called on the building thread.
    public nonisolated(unsafe) static var programWarmer: (([SKShader]) -> Void)?

    public convenience init(fileNamed name: String) {
        self.init(source: "")
        self.name = name
    }

    public var name: String?

    open func addUniform(_ uniform: SKUniform) {
        uniforms.append(uniform)
    }

    open func uniformNamed(_ name: String) -> SKUniform? {
        uniforms.first { $0.name == name }
    }

    open func removeUniformNamed(_ name: String) {
        uniforms.removeAll { $0.name == name }
    }
}

/// A shader uniform — often the busiest type after the nodes themselves,
/// since a scene lit in its shaders pushes its light into every one.
public final class SKUniform: @unchecked Sendable {
    public enum Value {
        case float(CGFloat)
        case vector2(SIMD2<Float>)
        case vector3(SIMD3<Float>)
        case vector4(SIMD4<Float>)
        /// Column-major, as GL and simd both keep them. Metal gives a shader
        /// 31 buffers and every uniform takes one, so a game may pack sets of
        /// colours or several objects' places and poses into a matrix a
        /// column each — which makes these load-bearing rather than exotic.
        case matrix2([Float])
        case matrix3([Float])
        case matrix4([Float])
        case texture(SKTexture?)
    }

    public let name: String
    public var value: Value {
        didSet { writeStamp = Self.nextWriteStamp() }
    }

    /// When this uniform was last written, on a clock every uniform shares
    /// (0: never since it was made). A rasterized `SKEffectNode` draws its
    /// cached pixels again once a uniform inside it was written after it last
    /// looked, as Apple's does: on every write, the same value too.
    public private(set) var writeStamp: UInt64 = 0

    // Uniforms are written on whichever thread builds or updates a scene,
    // so the shared clock ticks under a lock: no two writes share a stamp.
    private static let writeClock = Locked<UInt64>(0)

    private static func nextWriteStamp() -> UInt64 {
        writeClock.withLock { clock in
            clock &+= 1
            return clock
        }
    }

    /// What kind of value this holds, as SpriteKit reports it. A game may
    /// switch over it to copy a uniform (per cached band, say, so a band
    /// keeps the values it was drawn with).
    public var uniformType: SKUniformType {
        switch value {
        case .float: return .float
        case .vector2: return .floatVector2
        case .vector3: return .floatVector3
        case .vector4: return .floatVector4
        case .matrix2: return .floatMatrix2
        case .matrix3: return .floatMatrix3
        case .matrix4: return .floatMatrix4
        case .texture: return .texture
        }
    }

    /// Bumped on every write, so the renderer can skip uniforms that have not
    /// changed since the last frame.
    public private(set) var generation: UInt32 = 0

    public init(name: String) {
        self.name = name
        value = .float(0)
    }

    public init(name: String, float: Float) {
        self.name = name
        value = .float(CGFloat(float))
    }

    public init(name: String, vectorFloat2 vector: SIMD2<Float>) {
        self.name = name
        value = .vector2(vector)
    }

    public init(name: String, vectorFloat3 vector: SIMD3<Float>) {
        self.name = name
        value = .vector3(vector)
    }

    public init(name: String, vectorFloat4 vector: SIMD4<Float>) {
        self.name = name
        value = .vector4(vector)
    }

    public init(name: String, matrixFloat2x2 matrix: simd_float2x2) {
        self.name = name
        value = .matrix2(matrix.flattened)
    }

    public init(name: String, matrixFloat3x3 matrix: simd_float3x3) {
        self.name = name
        value = .matrix3(matrix.flattened)
    }

    public init(name: String, matrixFloat4x4 matrix: simd_float4x4) {
        self.name = name
        value = .matrix4(matrix.flattened)
    }

    public init(name: String, texture: SKTexture?) {
        self.name = name
        value = .texture(texture)
    }

    public var floatValue: Float {
        get { if case let .float(v) = value { return Float(v) } else { return 0 } }
        set { value = .float(CGFloat(newValue)); generation &+= 1 }
    }

    public var vectorFloat2Value: SIMD2<Float> {
        get { if case let .vector2(v) = value { return v } else { return .zero } }
        set { value = .vector2(newValue); generation &+= 1 }
    }

    public var vectorFloat3Value: SIMD3<Float> {
        get { if case let .vector3(v) = value { return v } else { return .zero } }
        set { value = .vector3(newValue); generation &+= 1 }
    }

    public var vectorFloat4Value: SIMD4<Float> {
        get { if case let .vector4(v) = value { return v } else { return .zero } }
        set { value = .vector4(newValue); generation &+= 1 }
    }

    public var matrixFloat2x2Value: simd_float2x2 {
        get {
            guard case let .matrix2(v) = value, v.count == 4 else { return simd_float2x2() }
            return simd_float2x2(SIMD2(v[0], v[1]), SIMD2(v[2], v[3]))
        }
        set { value = .matrix2(newValue.flattened); generation &+= 1 }
    }

    public var matrixFloat3x3Value: simd_float3x3 {
        get {
            guard case let .matrix3(v) = value, v.count == 9 else { return simd_float3x3() }
            return simd_float3x3(SIMD3(v[0], v[1], v[2]), SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8]))
        }
        set { value = .matrix3(newValue.flattened); generation &+= 1 }
    }

    public var matrixFloat4x4Value: simd_float4x4 {
        get {
            guard case let .matrix4(v) = value, v.count == 16 else { return simd_float4x4() }
            return simd_float4x4(
                SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15])
            )
        }
        set { value = .matrix4(newValue.flattened); generation &+= 1 }
    }

    public var textureValue: SKTexture? {
        get { if case let .texture(v) = value { return v } else { return nil } }
        set { value = .texture(newValue); generation &+= 1 }
    }
}

/// What kind of value an `SKUniform` holds, with SpriteKit's own spelling —
/// a game copying uniforms switches over every case.
public enum SKUniformType: Int, Sendable {
    case none
    case float
    case floatVector2
    case floatVector3
    case floatVector4
    case floatMatrix2
    case floatMatrix3
    case floatMatrix4
    case texture
}

public enum SKAttributeType: Int, Sendable {
    case none, float, vectorFloat2, vectorFloat3, vectorFloat4
    case halfFloat, vectorHalfFloat2, vectorHalfFloat3, vectorHalfFloat4
}

/// A per-node shader input, the way a mesh sprite's triangle runs reach its
/// shader.
public final class SKAttribute: @unchecked Sendable {
    public let name: String
    public let type: SKAttributeType

    public init(name: String, type: SKAttributeType) {
        self.name = name
        self.type = type
    }
}

public final class SKAttributeValue: @unchecked Sendable {
    public var value: SKUniform.Value

    public init(float: Float) { value = .float(CGFloat(float)) }
    public init(vectorFloat2 vector: SIMD2<Float>) { value = .vector2(vector) }
    public init(vectorFloat3 vector: SIMD3<Float>) { value = .vector3(vector) }
    public init(vectorFloat4 vector: SIMD4<Float>) { value = .vector4(vector) }

    public var floatValue: Float {
        get { if case let .float(v) = value { return Float(v) } else { return 0 } }
        set { value = .float(CGFloat(newValue)) }
    }

    public var vectorFloat2Value: SIMD2<Float> {
        get { if case let .vector2(v) = value { return v } else { return .zero } }
        set { value = .vector2(newValue) }
    }

    public var vectorFloat3Value: SIMD3<Float> {
        get { if case let .vector3(v) = value { return v } else { return .zero } }
        set { value = .vector3(newValue) }
    }

    public var vectorFloat4Value: SIMD4<Float> {
        get { if case let .vector4(v) = value { return v } else { return .zero } }
        set { value = .vector4(newValue) }
    }
}

#endif
