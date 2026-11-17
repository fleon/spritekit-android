#if SPRITEKIT_SHIM
import Foundation

// Apple's `simd` matrix types, as the game uses them.
//
// `SIMD2`/`SIMD3`/`SIMD4` are the Swift standard library's and come for free;
// the matrices are Apple's. They live here rather than in
// `Compat/Sources/simd` because `SKUniform(name:matrixFloat4x4:)` takes one,
// and the shim cannot depend on that package. That module re-exports these,
// and holds the free `simd_…` functions itself — keeping the functions in one
// place only, since a copy here as well would make every call ambiguous.
//
// `NightSkyNode` is why these are load-bearing: Metal gives a shader 31
// buffers and a uniform takes one each, so the sky packs its nebula tints,
// its fold tints and the planets' places, poses and rings into four 4×4
// matrices. The names and the column-major layout are Apple's, so `Source/`
// compiles against this unchanged.

/// A 4×4 matrix of floats, column-major as both simd and GL keep them.
public struct simd_float4x4: Equatable, Sendable {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    public init() {
        columns = (SIMD4<Float>(), SIMD4<Float>(), SIMD4<Float>(), SIMD4<Float>())
    }

    public init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        columns = (c0, c1, c2, c3)
    }

    public init(columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) {
        self.columns = columns
    }

    /// `simd_float4x4(diagonal)` and `init(1)` both appear in Apple code; the
    /// scalar form is the identity scaled, which is what a `1` means.
    public init(_ scalar: Float) {
        self.init(
            SIMD4(scalar, 0, 0, 0),
            SIMD4(0, scalar, 0, 0),
            SIMD4(0, 0, scalar, 0),
            SIMD4(0, 0, 0, scalar)
        )
    }

    public subscript(column: Int) -> SIMD4<Float> {
        get {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            default: return columns.3
            }
        }
        set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            default: columns.3 = newValue
            }
        }
    }

    /// The 16 floats in the order GL's `glUniformMatrix4fv` reads them.
    public var flattened: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z, columns.0.w,
            columns.1.x, columns.1.y, columns.1.z, columns.1.w,
            columns.2.x, columns.2.y, columns.2.z, columns.2.w,
            columns.3.x, columns.3.y, columns.3.z, columns.3.w,
        ]
    }

    public static func == (lhs: simd_float4x4, rhs: simd_float4x4) -> Bool {
        lhs.columns.0 == rhs.columns.0 && lhs.columns.1 == rhs.columns.1
            && lhs.columns.2 == rhs.columns.2 && lhs.columns.3 == rhs.columns.3
    }
}

public struct simd_float3x3: Equatable, Sendable {
    public var columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    public init() {
        columns = (SIMD3<Float>(), SIMD3<Float>(), SIMD3<Float>())
    }

    public init(_ c0: SIMD3<Float>, _ c1: SIMD3<Float>, _ c2: SIMD3<Float>) {
        columns = (c0, c1, c2)
    }

    public init(columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) {
        self.columns = columns
    }

    public var flattened: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z,
            columns.1.x, columns.1.y, columns.1.z,
            columns.2.x, columns.2.y, columns.2.z,
        ]
    }

    public static func == (lhs: simd_float3x3, rhs: simd_float3x3) -> Bool {
        lhs.columns.0 == rhs.columns.0 && lhs.columns.1 == rhs.columns.1 && lhs.columns.2 == rhs.columns.2
    }
}

public struct simd_float2x2: Equatable, Sendable {
    public var columns: (SIMD2<Float>, SIMD2<Float>)

    public init() {
        columns = (SIMD2<Float>(), SIMD2<Float>())
    }

    public init(_ c0: SIMD2<Float>, _ c1: SIMD2<Float>) {
        columns = (c0, c1)
    }

    public init(columns: (SIMD2<Float>, SIMD2<Float>)) {
        self.columns = columns
    }

    public var flattened: [Float] {
        [columns.0.x, columns.0.y, columns.1.x, columns.1.y]
    }

    public static func == (lhs: simd_float2x2, rhs: simd_float2x2) -> Bool {
        lhs.columns.0 == rhs.columns.0 && lhs.columns.1 == rhs.columns.1
    }
}

public typealias matrix_float4x4 = simd_float4x4
public typealias matrix_float3x3 = simd_float3x3
public typealias matrix_float2x2 = simd_float2x2

// The vector types' C spellings, which Apple's simd module names Swift's
// own SIMD types by (`vector_float2` is beside `SKWarpGeometryGrid`, its
// first user). Zyl's `ColorHelpers` hands shaders a `vector_float3`.
public typealias simd_float2 = SIMD2<Float>
public typealias simd_float3 = SIMD3<Float>
public typealias simd_float4 = SIMD4<Float>
public typealias vector_float3 = SIMD3<Float>
public typealias vector_float4 = SIMD4<Float>

#endif
