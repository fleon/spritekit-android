import Foundation

/// simd's `simd_quatf`, as much as the game asks of one: Starry Sky's
/// planet block keeps its orientation as a quaternion, built from axis-angle
/// turns, multiplied, normalised and handed to its shader as a `vector`
/// (ix, iy, iz, r). Named apart so the tests can check it against the real
/// one on the Mac; on Android it takes simd's name.
public struct Quaternion: Equatable, Sendable {
    /// (ix, iy, iz, r), simd's order.
    public var vector: SIMD4<Float>

    public init(vector: SIMD4<Float>) { self.vector = vector }

    public init(ix: Float, iy: Float, iz: Float, r: Float) {
        vector = SIMD4(ix, iy, iz, r)
    }

    /// A turn of `angle` radians about `axis`, which simd normalises first.
    public init(angle: Float, axis: SIMD3<Float>) {
        let length = (axis * axis).sum().squareRoot()
        let unit = length > 0 ? axis / length : SIMD3<Float>(0, 0, 0)
        let half = angle / 2
        let s = Float(Foundation.sin(Double(half)))
        vector = SIMD4(unit.x * s, unit.y * s, unit.z * s, Float(Foundation.cos(Double(half))))
    }

    public var imag: SIMD3<Float> { SIMD3(vector.x, vector.y, vector.z) }
    public var real: Float { vector.w }

    public var normalized: Quaternion {
        let length = (vector * vector).sum().squareRoot()
        return length > 0 ? Quaternion(vector: vector / length) : self
    }

    public static func * (a: Quaternion, b: Quaternion) -> Quaternion {
        let (x1, y1, z1, w1) = (a.vector.x, a.vector.y, a.vector.z, a.vector.w)
        let (x2, y2, z2, w2) = (b.vector.x, b.vector.y, b.vector.z, b.vector.w)
        return Quaternion(
            ix: w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
            iy: w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
            iz: w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2,
            r: w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2
        )
    }

    /// `v` turned by this quaternion (simd's `act`).
    public func act(_ v: SIMD3<Float>) -> SIMD3<Float> {
        (self * Quaternion(ix: v.x, iy: v.y, iz: v.z, r: 0) * Quaternion(ix: -imag.x, iy: -imag.y, iz: -imag.z, r: real)).imag
    }
}

#if !canImport(Darwin)
public typealias simd_quatf = Quaternion

public func simd_normalize(_ q: Quaternion) -> Quaternion { q.normalized }
public func simd_mul(_ a: Quaternion, _ b: Quaternion) -> Quaternion { a * b }
public func simd_act(_ q: Quaternion, _ v: SIMD3<Float>) -> SIMD3<Float> { q.act(v) }
#endif
