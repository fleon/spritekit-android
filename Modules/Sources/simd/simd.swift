// On Android there is no Accelerate and so no `simd` module. The SIMD types
// themselves are Swift's own (`SIMD3<Float>` is stdlib and works everywhere);
// what Apple's module adds on top is the free-function spelling. A module of
// this name, with the functions games use, lets a file that writes
// `import simd` compile untouched.
//
// Deliberately not here: `simd_quatf`. It wants a real quaternion type,
// which the shim has (`Quaternion.swift`).
//
// The matrix types (`matrix_float4x4` and its kin) are not here either: they
// live in the shim, because `SKUniform(name:matrixFloat4x4:)` takes one and
// the shim cannot depend on this package. They are re-exported below, so a
// file that writes `import simd` gets them as it would on Apple, for a
// shader that packs its parameters into 4x4 matrices.
import Foundation
@_exported import SpriteKitShim

@inlinable public func simd_min<T: SIMD>(_ x: T, _ y: T) -> T where T.Scalar: Comparable {
    var out = x
    for i in 0..<out.scalarCount where y[i] < out[i] { out[i] = y[i] }
    return out
}

@inlinable public func simd_max<T: SIMD>(_ x: T, _ y: T) -> T where T.Scalar: Comparable {
    var out = x
    for i in 0..<out.scalarCount where y[i] > out[i] { out[i] = y[i] }
    return out
}

@inlinable public func simd_dot<T: SIMD>(_ x: T, _ y: T) -> Float where T.Scalar == Float {
    (x * y).sum()
}

@inlinable public func simd_length<T: SIMD>(_ x: T) -> Float where T.Scalar == Float {
    simd_dot(x, x).squareRoot()
}

/// Apple's returns a zero vector rather than NaNs for a zero-length input.
@inlinable public func simd_normalize<T: SIMD>(_ x: T) -> T where T.Scalar == Float {
    let length = simd_length(x)
    guard length > 0 else { return T() }
    return x / T(repeating: length)
}

@inlinable public func simd_mix<T: SIMD>(_ x: T, _ y: T, _ t: T) -> T where T.Scalar == Float {
    x + (y - x) * t
}

@inlinable public func simd_cross(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(x.y * y.z - x.z * y.y, x.z * y.x - x.x * y.z, x.x * y.y - x.y * y.x)
}
