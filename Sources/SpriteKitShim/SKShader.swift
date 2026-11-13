#if SPRITEKIT_SHIM
import Foundation

/// A fragment shader attached to a node.
///
/// SpriteKit takes GLSL ES 1.0 with its own preamble (`u_time`, `v_tex_coord`,
/// `u_texture`, `SKDefaultShading()`). The game has 65 of these and 71
/// `gl_FragColor` sites, so the shim keeps the source verbatim and the
/// renderer rewrites the preamble to GLSL ES 3.0 at upload — the dialect
/// change is textual and belongs in one place, not in 31 files.
public final class SKShader: @unchecked Sendable {
    public var source: String
    public var uniforms: [SKUniform]
    public var attributes: [SKAttribute] = []

    /// Set by the renderer once compiled and linked.
    public var glProgram: UInt32 = 0

    public init(source: String) {
        self.source = source
        uniforms = []
    }

    public init(source: String, uniforms: [SKUniform]) {
        self.source = source
        self.uniforms = uniforms
    }

    public convenience init(fileNamed name: String) {
        self.init(source: "")
        self.name = name
    }

    public var name: String?

    public func addUniform(_ uniform: SKUniform) {
        uniforms.append(uniform)
    }

    public func uniformNamed(_ name: String) -> SKUniform? {
        uniforms.first { $0.name == name }
    }

    public func removeUniformNamed(_ name: String) {
        uniforms.removeAll { $0.name == name }
    }
}

/// A shader uniform — 378 uses, by far the busiest type after the nodes
/// themselves, because the lit worlds push their light into every shader.
public final class SKUniform: @unchecked Sendable {
    public enum Value {
        case float(CGFloat)
        case vector2(SIMD2<Float>)
        case vector3(SIMD3<Float>)
        case vector4(SIMD4<Float>)
        case texture(SKTexture?)
    }

    public let name: String
    public var value: Value

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

    public var textureValue: SKTexture? {
        get { if case let .texture(v) = value { return v } else { return nil } }
        set { value = .texture(newValue); generation &+= 1 }
    }
}

public enum SKAttributeType: Int, Sendable {
    case none, float, vectorFloat2, vectorFloat3, vectorFloat4
    case halfFloat, vectorHalfFloat2, vectorHalfFloat3, vectorHalfFloat4
}

/// A per-node shader input. Only 3 declarations in the game, but they carry
/// the rig meshes' triangle runs, so they matter.
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

    public var vectorFloat4Value: SIMD4<Float> {
        get { if case let .vector4(v) = value { return v } else { return .zero } }
        set { value = .vector4(newValue) }
    }
}

#endif
