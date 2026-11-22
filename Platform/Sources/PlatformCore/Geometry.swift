import Foundation
import SpriteKitShim

// Shorthands for the geometry a SpriteKit game builds all day: `pt`, `sz`
// and `rect` for the CoreGraphics initializers, `clamp` and `lerp` for the
// arithmetic between them.

@inlinable
public nonisolated func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: y)
}

public nonisolated func pt(_ x: Int, _ y: Int) -> CGPoint {
    CGPoint(x: CGFloat(x), y: CGFloat(y))
}

public nonisolated func sz(_ width: CGFloat, _ height: CGFloat) -> CGSize {
    CGSize(width: width, height: height)
}

public nonisolated func sz(_ width: Int, _ height: Int) -> CGSize {
    CGSize(width: CGFloat(width), height: CGFloat(height))
}

/// A square.
public nonisolated func sz(_ side: CGFloat) -> CGSize {
    CGSize(width: side, height: side)
}

public nonisolated func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
}

public nonisolated func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> CGRect {
    CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
}

/// A rectangle at the origin.
public nonisolated func rect(_ width: CGFloat, _ height: CGFloat) -> CGRect {
    rect(0, 0, width, height)
}

/// A square at the origin.
public nonisolated func rect(_ size: CGFloat) -> CGRect {
    rect(0, 0, size, size)
}

public nonisolated func rect(_ size: CGSize) -> CGRect {
    rect(size.width, size.height)
}

public func range(_ start: CGFloat, _ end: CGFloat) -> SKRange {
    SKRange(lowerLimit: start, upperLimit: end)
}

public func range(_ constantValue: CGFloat) -> SKRange {
    SKRange(constantValue: constantValue)
}

/// Holds a node's x at `x`.
public func xConstraint(_ x: CGFloat) -> SKConstraint {
    SKConstraint.positionX(range(x))
}

public func xConstraint(_ x: SKRange) -> SKConstraint {
    SKConstraint.positionX(x)
}

/// Holds a node's y at `y`.
public func yConstraint(_ y: CGFloat) -> SKConstraint {
    SKConstraint.positionY(range(y))
}

public func yConstraint(_ y: SKRange) -> SKConstraint {
    SKConstraint.positionY(y)
}

public nonisolated func distance(_ point1: CGPoint, _ point2: CGPoint) -> CGFloat {
    hypot(point2.x - point1.x, point2.y - point1.y)
}

/// A point on the quadratic Bézier curve from `start` to `end` at `t`.
public nonisolated func quadraticBezier(_ start: CGPoint, _ control: CGPoint, _ end: CGPoint, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let a = u * u
    let b = 2 * u * t
    let c = t * t
    return pt(a * start.x + b * control.x + c * end.x, a * start.y + b * control.y + c * end.y)
}

/// Degrees in radians.
public nonisolated func degrees(_ value: CGFloat) -> CGFloat {
    value * .pi / 180
}

extension CGFloat {
    public nonisolated func clamp(_ min: CGFloat, _ max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(self, max))
    }

    /// The value this share of the way from `start` to `end`.
    public nonisolated func lerp(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
        start + (end - start) * self
    }

    public nonisolated func lerp(_ start: CGPoint, _ end: CGPoint) -> CGPoint {
        pt(lerp(start.x, end.x), lerp(start.y, end.y))
    }

    /// Mixes the two colours' components in their own colour space.
    public func lerp(_ start: UIColor, _ end: UIColor) -> UIColor {
        var startR: CGFloat = 0, startG: CGFloat = 0, startB: CGFloat = 0, startA: CGFloat = 0
        var endR: CGFloat = 0, endG: CGFloat = 0, endB: CGFloat = 0, endA: CGFloat = 0
        start.getRed(&startR, green: &startG, blue: &startB, alpha: &startA)
        end.getRed(&endR, green: &endG, blue: &endB, alpha: &endA)
        return UIColor(
            red: lerp(startR, endR),
            green: lerp(startG, endG),
            blue: lerp(startB, endB),
            alpha: lerp(startA, endA)
        )
    }

    /// How far this value lies from `start` to `end`, as a share: `lerp`
    /// undone.
    public nonisolated func unlerp(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
        (self - start) / (end - start)
    }
}

extension CGPoint {
    public nonisolated func clamp(_ min: CGPoint, _ max: CGPoint) -> CGPoint {
        pt(x.clamp(min.x, max.x), y.clamp(min.y, max.y))
    }

    public nonisolated func offset(_ offset: CGPoint) -> CGPoint {
        pt(x + offset.x, y + offset.y)
    }

    public nonisolated func offset(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        offset(pt(x, y))
    }
}

extension CGRect {
    /// A rectangle this size placed so `anchor` (a share of its size) sits
    /// at the origin, as a sprite's anchor point places it.
    public nonisolated func anchor(_ anchor: CGPoint) -> CGRect {
        rect(-anchor.x * width, -anchor.y * height, width, height)
    }

    public nonisolated func anchor(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        anchor(pt(x, y))
    }

    public nonisolated func anchor(_ a: CGFloat) -> CGRect {
        anchor(a, a)
    }

    public nonisolated func offset(_ offset: CGPoint) -> CGRect {
        rect(minX + offset.x, minY + offset.y, width, height)
    }

    public nonisolated func offset(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        offset(pt(x, y))
    }

    public nonisolated var center: CGPoint { pt(midX, midY) }
}
