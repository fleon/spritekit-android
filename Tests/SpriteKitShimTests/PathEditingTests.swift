#if canImport(AppKit)
import AppKit
import Testing
@testable import SpriteKitShim
import RuntimeTestSupport

// `UIBezierPath`'s arcs, `apply(_:)` and `reversing()` on Android rest on
// `PathGeometry`; here each is measured against CoreGraphics (arcs,
// transforms) and AppKit's `NSBezierPath.reversed` (UIKit's `reversing()`
// on the Mac) as they record the same paths.

/// Element-wise, to within rounding; Apple's trailing `move` after a close
/// (NSBezierPath records one) is not a segment and is dropped.
private func same(_ ours: [PathElement], _ apple: [PathElement]) -> Bool {
    var apple = apple
    if case .move? = apple.last, apple.count > 1, case .close = apple[apple.count - 2] { apple.removeLast() }
    guard ours.count == apple.count else { return false }
    for (a, b) in zip(ours, apple) {
        switch (a, b) {
        case let (.move(p), .move(q)), let (.line(p), .line(q)):
            guard near(p, q, 1e-9) else { return false }
        case let (.quadCurve(p, c), .quadCurve(q, d)):
            guard near(p, q, 1e-9), near(c, d, 1e-9) else { return false }
        case let (.curve(p, c1, c2), .curve(q, d1, d2)):
            guard near(p, q, 1e-9), near(c1, d1, 1e-9), near(c2, d2, 1e-9) else { return false }
        case (.close, .close):
            break
        default:
            return false
        }
    }
    return true
}

struct ArcCase: CustomTestStringConvertible, Sendable {
    var start: CGFloat
    var end: CGFloat
    var rising: Bool
    var afterPen: Bool
    var testDescription: String { "\(start)→\(end) \(rising ? "rising" : "falling")\(afterPen ? " after a pen" : "")" }
}

private let arcs: [ArcCase] = [
    ArcCase(start: 0, end: 3 * .pi / 2, rising: true, afterPen: false),
    ArcCase(start: 0, end: .pi / 3, rising: false, afterPen: true),
    ArcCase(start: 0, end: 2 * .pi, rising: true, afterPen: false),
    ArcCase(start: 1, end: 1, rising: true, afterPen: true),
    ArcCase(start: -.pi / 2, end: .pi * 1.25, rising: true, afterPen: true),
    ArcCase(start: 2.5, end: -0.4, rising: false, afterPen: false),
]

@Suite("Path editing against CoreGraphics")
struct PathEditingTests {
    @Test("An arc becomes CoreGraphics' own curves, joined to the pen as it joins them", arguments: arcs)
    func arcAsCurves(_ arc: ArcCase) {
        let center = CGPoint(x: 5, y: 5)
        let apple = CGMutablePath()
        var ours: [PathElement] = []
        if arc.afterPen {
            apple.move(to: .zero)
            ours.append(.move(.zero))
        }
        // UIKit's clockwise (the shim's) is CoreGraphics' counterclockwise
        // in a y-up space.
        apple.addArc(center: center, radius: 10, startAngle: arc.start, endAngle: arc.end, clockwise: !arc.rising)
        ours.append(.arc(center: center, radius: 10, start: arc.start, end: arc.end, clockwise: arc.rising))
        let made = PathGeometry.curvesOnly(ours)
        // CoreGraphics' arc of no sweep leaves only the pen's line or move.
        #expect(same(made, apple.pathElements))
    }

    /// `PathGeometry.transformed` is `UIBezierPath.apply(_:)` and, on Android,
    /// `CGPath.copy(using:)` itself.
    @Test("apply(_:) moves every point as CGPath.copy(using:) does, arcs included")
    func transform() throws {
        let apple = CGMutablePath()
        apple.move(to: CGPoint(x: 1, y: 2))
        apple.addLine(to: CGPoint(x: 8, y: 3))
        apple.addQuadCurve(to: CGPoint(x: 9, y: 9), control: CGPoint(x: 12, y: 5))
        apple.addArc(center: CGPoint(x: 4, y: 4), radius: 3, startAngle: 0.2, endAngle: 2.9, clockwise: false)
        apple.closeSubpath()
        var transform = CGAffineTransform(rotationAngle: 0.5).scaledBy(x: 2, y: -1.5).translatedBy(x: 3, y: -7)
        let moved = try #require(apple.copy(using: &transform))

        let ours: [PathElement] = [
            .move(CGPoint(x: 1, y: 2)),
            .line(CGPoint(x: 8, y: 3)),
            .quadCurve(to: CGPoint(x: 9, y: 9), control: CGPoint(x: 12, y: 5)),
            .arc(center: CGPoint(x: 4, y: 4), radius: 3, start: 0.2, end: 2.9, clockwise: true),
            .close,
        ]
        #expect(same(PathGeometry.transformed(ours, by: transform), moved.pathElements))
    }

    @Test("reversing() draws each subpath the other way, in order, as AppKit's reversed does")
    func reversal() {
        var ours: [PathElement] = []
        // An open polyline ending in a curve.
        ours += [
            .move(CGPoint(x: 0, y: 0)),
            .line(CGPoint(x: 10, y: 0)),
            .curve(to: CGPoint(x: 20, y: 10), control1: CGPoint(x: 12, y: 1), control2: CGPoint(x: 18, y: 5)),
        ]
        // A closed triangle, closed by the close alone.
        ours += [.move(CGPoint(x: 100, y: 100)), .line(CGPoint(x: 110, y: 100)), .line(CGPoint(x: 110, y: 110)), .close]
        // A closed square that draws its own last side.
        ours += [.move(CGPoint(x: 50, y: 50))]
        ours += [(60, 50), (60, 60), (50, 60), (50, 50)].map { .line(CGPoint(x: $0.0, y: $0.1)) }
        ours += [.close]
        // A circle, all curves, closed.
        ours += CGPath(ellipseIn: CGRect(x: -20, y: -20, width: 10, height: 10), transform: nil).pathElements
        // An arc after a pen, open; and a quadratic.
        ours += [
            .move(CGPoint(x: 190, y: 0)),
            .arc(center: CGPoint(x: 200, y: 0), radius: 5, start: 0, end: 2, clockwise: true),
            .quadCurve(to: CGPoint(x: 230, y: 5), control: CGPoint(x: 220, y: 20)),
        ]

        // AppKit's path holds the same segments, arcs as CoreGraphics' own
        // curves (pinned by the arc test above).
        let path = NSBezierPath()
        for element in PathGeometry.curvesOnly(ours) {
            switch element {
            case let .move(p): path.move(to: p)
            case let .line(p): path.line(to: p)
            case let .quadCurve(p, c): path.curve(to: p, controlPoint1: c, controlPoint2: c)
            case let .curve(p, c1, c2): path.curve(to: p, controlPoint1: c1, controlPoint2: c2)
            case .close: path.close()
            case .arc: break
            }
        }
        // NSBezierPath has no quadratic segment: it records one as a cubic
        // with its control point twice, so ours is compared the same way.
        let cubicOnly = PathGeometry.reversed(ours).map { element -> PathElement in
            if case let .quadCurve(p, c) = element { return .curve(to: p, control1: c, control2: c) }
            return element
        }
        #expect(same(cubicOnly, path.reversed.cgPath.pathElements))
    }

    @Test("A cut-out drawn reversed inside a rect winds the other way, so it stays a hole under the nonzero rule")
    func cutout() {
        let outer = CGMutablePath()
        outer.addRect(CGRect(x: 0, y: 0, width: 100, height: 100))
        let hole: [PathElement] = PathElementsOf(path: CGPath(roundedRect: CGRect(x: 30, y: 30, width: 40, height: 40), cornerWidth: 8, cornerHeight: 8, transform: nil))
        let combined = outer.pathElements + PathGeometry.reversed(hole)
        let apple = CGMutablePath()
        apple.addRect(CGRect(x: 0, y: 0, width: 100, height: 100))
        apple.addPath(NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 40, height: 40), xRadius: 8, yRadius: 8).reversed.cgPath)
        #expect(!apple.contains(CGPoint(x: 50, y: 50), using: .winding))
        // Our reversed hole, recorded into CoreGraphics, is a hole too.
        let ours = CGMutablePath()
        for element in combined {
            switch element {
            case let .move(p): ours.move(to: p)
            case let .line(p): ours.addLine(to: p)
            case let .quadCurve(p, c): ours.addQuadCurve(to: p, control: c)
            case let .curve(p, c1, c2): ours.addCurve(to: p, control1: c1, control2: c2)
            case .close: ours.closeSubpath()
            case .arc: break
            }
        }
        #expect(!ours.contains(CGPoint(x: 50, y: 50), using: .winding))
        #expect(ours.contains(CGPoint(x: 10, y: 10), using: .winding))
    }
}

private func PathElementsOf(path: CGPath) -> [PathElement] { path.pathElements }
#endif
