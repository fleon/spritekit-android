// Apple is detected through Darwin rather than canImport(CoreGraphics):
// this package ships a target *named* CoreGraphics so the game's own
// `import CoreGraphics` resolves on Android, and keying off the module name
// would make SpriteKitShim depend on it circularly.

#if SPRITEKIT_SHIM && canImport(Darwin)
// Building the shim on a Mac for development and tests: the real geometry
// types are right there, so use them rather than shadowing them.
@_exported import CoreGraphics
#endif

#if SPRITEKIT_SHIM && !canImport(Darwin)
// On Android, CGFloat, CGPoint, CGSize and CGRect come from Foundation.
// Re-exporting means the game's files get them from `import CoreGraphics`
// just as they do on Apple, without an edit.
@_exported import Foundation

// swift-corelibs-foundation already vends CGFloat, CGPoint, CGSize and CGRect
// (including insetBy/offsetBy/midX and friends). These are the pieces it
// leaves out that the game's geometry helpers rely on.

public struct CGVector: Equatable, Sendable {
    public var dx: CGFloat
    public var dy: CGFloat
    public init(dx: CGFloat = 0, dy: CGFloat = 0) {
        self.dx = dx
        self.dy = dy
    }
    public static let zero = CGVector()
}

/// The 2D affine transform, laid out as CoreGraphics lays it out:
///
///     | a  b  0 |
///     | c  d  0 |
///     | tx ty 1 |
public struct CGAffineTransform: Equatable, Sendable {
    public var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat
    public var tx: CGFloat, ty: CGFloat

    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public init(translationX tx: CGFloat, y ty: CGFloat) {
        self.init(a: 1, b: 0, c: 0, d: 1, tx: tx, ty: ty)
    }

    public init(scaleX sx: CGFloat, y sy: CGFloat) {
        self.init(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }

    public init(rotationAngle angle: CGFloat) {
        let s = sin(angle), c = cos(angle)
        self.init(a: c, b: s, c: -s, d: c, tx: 0, ty: 0)
    }

    public var isIdentity: Bool { self == .identity }

    /// `self` applied first, then `other` — CoreGraphics' concatenation order.
    public func concatenating(_ other: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            tx: tx * other.a + ty * other.c + other.tx,
            ty: tx * other.b + ty * other.d + other.ty
        )
    }

    public func translatedBy(x: CGFloat, y: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: x, y: y).concatenating(self)
    }

    public func scaledBy(x: CGFloat, y: CGFloat) -> CGAffineTransform {
        CGAffineTransform(scaleX: x, y: y).concatenating(self)
    }

    public func rotated(by angle: CGFloat) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: angle).concatenating(self)
    }

    /// Nil when the transform collapses (a zero scale), as CoreGraphics
    /// returns the original in that case.
    public func inverted() -> CGAffineTransform {
        let determinant = a * d - b * c
        guard abs(determinant) > .ulpOfOne else { return self }
        let inverse = 1 / determinant
        return CGAffineTransform(
            a: d * inverse,
            b: -b * inverse,
            c: -c * inverse,
            d: a * inverse,
            tx: (c * ty - d * tx) * inverse,
            ty: (b * tx - a * ty) * inverse
        )
    }
}

public extension CGPoint {
    func applying(_ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: a_x(t), y: a_y(t))
    }
    private func a_x(_ t: CGAffineTransform) -> CGFloat { t.a * x + t.c * y + t.tx }
    private func a_y(_ t: CGAffineTransform) -> CGFloat { t.b * x + t.d * y + t.ty }
}

public extension CGSize {
    func applying(_ t: CGAffineTransform) -> CGSize {
        CGSize(width: t.a * width + t.c * height, height: t.b * width + t.d * height)
    }
}

public extension CGRect {
    /// The axis-aligned bounds of the transformed rectangle.
    func applying(_ t: CGAffineTransform) -> CGRect {
        let corners = [
            CGPoint(x: minX, y: minY).applying(t),
            CGPoint(x: maxX, y: minY).applying(t),
            CGPoint(x: minX, y: maxY).applying(t),
            CGPoint(x: maxX, y: maxY).applying(t),
        ]
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let left = xs.min(), let right = xs.max(),
              let bottom = ys.min(), let top = ys.max() else { return .zero }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}

#endif
