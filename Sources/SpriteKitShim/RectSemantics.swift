#if SPRITEKIT_SHIM
import Foundation

/// How CoreGraphics answers `CGRect`'s overlap questions, where
/// swift-corelibs-foundation answers differently at the edges.
///
/// Corelibs builds `intersection` from closed ranges, so two rects that only
/// touch share a zero-wide strip and `intersects` says yes, where
/// CoreGraphics says no; and it gives back a spanned rect's own width where
/// CoreGraphics gives `maxX − minX`, which can round a bit either way. Its
/// `contains(_: CGRect)` is `union(r) == self`, which that same rounding
/// breaks: (0.1, 0, 0.2, 1) doesn't contain itself. A layout that tests
/// grid spots against grown rects and the screen meets edges exactly; a
/// spot one side lets through and the other doesn't takes a random draw the
/// other doesn't, and every piece placed after it lands elsewhere.
///
/// Each rule was fitted against a Mac's CoreGraphics over every pair of a
/// grid of rects (null, infinite, zero-sized, negative-sized) and 400,000
/// random fractional pairs sharing edges, with no mismatch
/// (`RectSemanticsTests`, which keeps checking it on the host).
public enum RectSemantics {
    /// On each axis a rect covers [min, max), a zero-long one the point
    /// itself; two rects intersect where those overlap on both axes.
    public static func intersects(_ a: CGRect, _ b: CGRect) -> Bool {
        guard !a.isNull, !b.isNull else { return false }
        return overlaps(a.minX, a.maxX, b.minX, b.maxX) && overlaps(a.minY, a.maxY, b.minY, b.maxY)
    }

    /// The shared part, `max(minX) … min(maxX)` each way, null where they
    /// don't meet (touching rects share a zero-wide strip).
    public static func intersection(_ a: CGRect, _ b: CGRect) -> CGRect {
        guard !a.isNull, !b.isNull else { return .null }
        let x0 = max(a.minX, b.minX), x1 = min(a.maxX, b.maxX)
        let y0 = max(a.minY, b.minY), y1 = min(a.maxY, b.maxY)
        guard x0 <= x1, y0 <= y1 else { return .null }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Whether `b` lies within `a`, edges included; a null rect lies in
    /// any rect, and a null rect holds nothing else.
    public static func contains(_ a: CGRect, _ b: CGRect) -> Bool {
        if b.isNull { return true }
        if a.isNull { return false }
        return a.minX <= b.minX && b.maxX <= a.maxX && a.minY <= b.minY && b.maxY <= a.maxY
    }

    private static func overlaps(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Bool {
        let low = max(a0, b0), high = min(a1, b1)
        if low != high { return low < high }
        return covers(low, a0, a1) && covers(low, b0, b1)
    }

    private static func covers(_ point: CGFloat, _ start: CGFloat, _ end: CGFloat) -> Bool {
        start == end ? point == start : point >= start && point < end
    }
}

#if !canImport(Darwin)
// A member declared here takes precedence over Foundation's (as
// `BundleInfo.swift`'s `infoDictionary` does), so the game's `CGRect` calls
// reach CoreGraphics' answers with no edit.
public extension CGRect {
    func intersects(_ rect2: CGRect) -> Bool { RectSemantics.intersects(self, rect2) }
    func intersection(_ rect2: CGRect) -> CGRect { RectSemantics.intersection(self, rect2) }
    func contains(_ rect2: CGRect) -> Bool { RectSemantics.contains(self, rect2) }
}
#endif
#endif
