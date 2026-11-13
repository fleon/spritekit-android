// On Android there is no Accelerate and so no `simd` module. The SIMD types
// themselves are Swift's own (`SIMD3<Float>` is stdlib and works everywhere);
// what Apple's module adds on top is the free-function spelling, and that is
// all the game uses. Eleven files `import simd`, between them for eight
// functions, so a module of this name lets each compile untouched.
//
// Deliberately not here: `simd_quatf`. It is BlockNode's alone (Starry Sky's
// tumbling planet) and wants a real quaternion type, which belongs with the
// board ring that will exercise it rather than with a rig that will not.
import Foundation

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
