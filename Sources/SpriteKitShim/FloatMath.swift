#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

// Darwin's overlay gives `sin`, `sqrt` and the rest of libm a `Float`
// overload; Android's gives only `Double` (and Foundation adds `CGFloat`).
// Without these, a game expression mixing `SIMD2<Float>` arithmetic with
// `sin(angle)` on a `Float` has no answer, and the type checker searches every
// operator until it gives up ("unable to type-check this expression in
// reasonable time") — `BackdropWarp.crown` was the first to hit it.

@_transparent public func sin(_ x: Float) -> Float { sinf(x) }
@_transparent public func cos(_ x: Float) -> Float { cosf(x) }
@_transparent public func tan(_ x: Float) -> Float { tanf(x) }
@_transparent public func asin(_ x: Float) -> Float { asinf(x) }
@_transparent public func acos(_ x: Float) -> Float { acosf(x) }
@_transparent public func atan(_ x: Float) -> Float { atanf(x) }
@_transparent public func atan2(_ y: Float, _ x: Float) -> Float { atan2f(y, x) }
@_transparent public func sqrt(_ x: Float) -> Float { x.squareRoot() }
@_transparent public func exp(_ x: Float) -> Float { expf(x) }
@_transparent public func exp2(_ x: Float) -> Float { exp2f(x) }
@_transparent public func log(_ x: Float) -> Float { logf(x) }
@_transparent public func log2(_ x: Float) -> Float { log2f(x) }
@_transparent public func log10(_ x: Float) -> Float { log10f(x) }
@_transparent public func pow(_ x: Float, _ y: Float) -> Float { powf(x, y) }
@_transparent public func hypot(_ x: Float, _ y: Float) -> Float { hypotf(x, y) }
@_transparent public func fmod(_ x: Float, _ y: Float) -> Float { fmodf(x, y) }
@_transparent public func floor(_ x: Float) -> Float { x.rounded(.down) }
@_transparent public func ceil(_ x: Float) -> Float { x.rounded(.up) }
@_transparent public func round(_ x: Float) -> Float { x.rounded() }
@_transparent public func trunc(_ x: Float) -> Float { x.rounded(.towardZero) }

// corelibs Foundation gives `CGFloat` the transcendental functions but not
// the rounding ones, which Darwin's CoreGraphics overlay does. Without them a
// `ceil(optionalLabel?.frame.width ?? 0)` takes the `Double` overload and
// cannot convert the optional (`SelectButtonNode`).
@_transparent public func floor(_ x: CGFloat) -> CGFloat { x.rounded(.down) }
@_transparent public func ceil(_ x: CGFloat) -> CGFloat { x.rounded(.up) }
@_transparent public func round(_ x: CGFloat) -> CGFloat { x.rounded() }
@_transparent public func trunc(_ x: CGFloat) -> CGFloat { x.rounded(.towardZero) }

#endif
