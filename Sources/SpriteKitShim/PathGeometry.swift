import Foundation

/// The path calls CoreGraphics works out itself rather than recording:
/// a fillet between two tangents and a dashed copy. On Android `CGPath`
/// records, so the shim has to do the geometry; it is here, in portable
/// terms, so the tests can check it against CoreGraphics on the Mac.
public enum PathGeometry {
    /// Where the pen ends after `elements`, as `CGPath.currentPoint` reports
    /// it: nil on an empty path, the subpath's start after a close.
    public static func currentPoint(after elements: [PathElement]) -> CGPoint? {
        var pen: CGPoint?
        var start: CGPoint?
        for element in elements {
            switch element {
            case let .move(p):
                pen = p
                start = p
            case let .line(p), let .quadCurve(p, _), let .curve(p, _, _):
                pen = p
            case let .arc(centre, radius, _, end, _):
                pen = CGPoint(x: centre.x + cos(end) * radius, y: centre.y + sin(end) * radius)
            case .close:
                pen = start
            }
        }
        return pen
    }

    /// `addArc(tangent1End:tangent2End:radius:)`: a line from `pen` toward
    /// `corner`, then the arc of `radius` tangent to both `pen`→`corner` and
    /// `corner`→`end`. Degenerate cases draw a line to `corner`, as
    /// CoreGraphics does. The arc's `clockwise` is the rising-angle sense the
    /// rasteriser reads.
    public static func tangentArc(from pen: CGPoint, corner: CGPoint, end: CGPoint, radius: CGFloat) -> [PathElement] {
        let a = CGVector(dx: pen.x - corner.x, dy: pen.y - corner.y)
        let b = CGVector(dx: end.x - corner.x, dy: end.y - corner.y)
        let la = hypot(a.dx, a.dy), lb = hypot(b.dx, b.dy)
        guard radius > 0, la > 1e-9, lb > 1e-9 else { return [.line(corner)] }
        let ua = CGVector(dx: a.dx / la, dy: a.dy / la), ub = CGVector(dx: b.dx / lb, dy: b.dy / lb)
        let cross = ua.dx * ub.dy - ua.dy * ub.dx
        let dot = ua.dx * ub.dx + ua.dy * ub.dy
        guard abs(cross) > 1e-9 else { return [.line(corner)] }
        let angle = acos(max(-1, min(1, dot)))
        let along = radius / tan(angle / 2)
        let first = CGPoint(x: corner.x + ua.dx * along, y: corner.y + ua.dy * along)
        let second = CGPoint(x: corner.x + ub.dx * along, y: corner.y + ub.dy * along)
        var bisector = CGVector(dx: ua.dx + ub.dx, dy: ua.dy + ub.dy)
        let lbis = hypot(bisector.dx, bisector.dy)
        bisector = CGVector(dx: bisector.dx / lbis, dy: bisector.dy / lbis)
        let reach = radius / sin(angle / 2)
        let centre = CGPoint(x: corner.x + bisector.dx * reach, y: corner.y + bisector.dy * reach)
        let start = atan2(first.y - centre.y, first.x - centre.x)
        let stop = atan2(second.y - centre.y, second.x - centre.x)
        // The short way round, which is less than a half turn.
        let rising = remainder(stop - start, 2 * .pi) > 0
        return [.line(first), .arc(center: centre, radius: radius, start: start, end: stop, clockwise: rising)]
    }

    /// `copy(dashingWithPhase:lengths:)` over a path already flattened: each
    /// dash an open polyline of its own. The pattern runs on round corners
    /// and across a closed subpath's closing segment, and starts afresh at
    /// every subpath, `phase` into the pattern, as CoreGraphics does.
    public static func dash(_ subpaths: [PathRasteriser.Subpath], phase: CGFloat, lengths: [CGFloat]) -> [[CGPoint]] {
        let pattern = lengths.filter { $0 >= 0 }
        let period = pattern.reduce(0, +)
        guard period > 0 else { return subpaths.map(\.points) }
        var dashes: [[CGPoint]] = []
        for subpath in subpaths {
            var points = subpath.points
            if subpath.isClosed, let first = points.first, points.last != first { points.append(first) }
            guard points.count > 1 else { continue }
            var index = 0
            var left = pattern[0]
            var on = true
            var skip = phase.truncatingRemainder(dividingBy: period)
            if skip < 0 { skip += period }
            while skip > 0 {
                if skip >= left {
                    skip -= left
                    index = (index + 1) % pattern.count
                    left = pattern[index]
                    on.toggle()
                } else {
                    left -= skip
                    skip = 0
                }
            }
            var current: [CGPoint] = on ? [points[0]] : []
            for i in 1 ..< points.count {
                var from = points[i - 1]
                let to = points[i]
                var segment = hypot(to.x - from.x, to.y - from.y)
                while segment > 0 {
                    if left >= segment {
                        if on { current.append(to) }
                        left -= segment
                        segment = 0
                    } else {
                        let t = left / segment
                        let cut = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                        if on {
                            current.append(cut)
                            if current.count > 1 { dashes.append(current) }
                            current = []
                        } else {
                            current = [cut]
                        }
                        on.toggle()
                        segment -= left
                        from = cut
                        index = (index + 1) % pattern.count
                        left = pattern[index]
                    }
                }
            }
            if on, current.count > 1 { dashes.append(current) }
        }
        return dashes
    }
}

// MARK: - Arcs as curves, transforms and reversal

public extension PathGeometry {
    /// An arc as CoreGraphics adds one: cubic Béziers of at most a quarter
    /// turn each, measured from the start angle, the last taking what is
    /// left. `rising` is the shim's (UIKit's) `clockwise`: the angle rises
    /// along the arc, as CoreGraphics' `clockwise: false`. No curves for a
    /// sweep of nothing (start equal to end).
    static func curves(
        center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, rising: Bool
    ) -> [PathElement] {
        var sweep = end - start
        if rising {
            while sweep < 0 { sweep += .pi * 2 }
        } else {
            while sweep > 0 { sweep -= .pi * 2 }
        }
        guard sweep != 0 else { return [] }
        var curves: [PathElement] = []
        var angle = start
        var left = sweep
        while abs(left) > 1e-12 {
            let step = left > 0 ? min(left, .pi / 2) : max(left, -.pi / 2)
            let k = 4 / 3 * tan(step / 4) * radius
            let (c0, s0) = (cos(angle), sin(angle))
            let (c1, s1) = (cos(angle + step), sin(angle + step))
            curves.append(.curve(
                to: CGPoint(x: center.x + radius * c1, y: center.y + radius * s1),
                control1: CGPoint(x: center.x + radius * c0 - k * s0, y: center.y + radius * s0 + k * c0),
                control2: CGPoint(x: center.x + radius * c1 + k * s1, y: center.y + radius * s1 - k * c1)
            ))
            angle += step
            left -= step
        }
        return curves
    }

    /// The same path with every arc made curves, as CoreGraphics records it:
    /// an arc starts a subpath at its first point where there is no pen, and
    /// is joined to the pen with a line where there is one.
    static func curvesOnly(_ elements: [PathElement]) -> [PathElement] {
        var out: [PathElement] = []
        var hasPen = false
        for element in elements {
            switch element {
            case let .arc(center, radius, start, end, rising):
                let first = CGPoint(x: center.x + cos(start) * radius, y: center.y + sin(start) * radius)
                out.append(hasPen ? .line(first) : .move(first))
                out += curves(center: center, radius: radius, start: start, end: end, rising: rising)
                hasPen = true
            case .close:
                out.append(element)
                hasPen = false
            default:
                out.append(element)
                hasPen = true
            }
        }
        return out
    }

    /// `UIBezierPath.apply(_:)` and `CGPath.copy(using:)`: every point
    /// through `transform`, arcs first made curves so any transform holds.
    static func transformed(_ elements: [PathElement], by transform: CGAffineTransform) -> [PathElement] {
        curvesOnly(elements).map { element in
            switch element {
            case let .move(p): return .move(p.applying(transform))
            case let .line(p): return .line(p.applying(transform))
            case let .quadCurve(p, c): return .quadCurve(to: p.applying(transform), control: c.applying(transform))
            case let .curve(p, c1, c2):
                return .curve(to: p.applying(transform), control1: c1.applying(transform), control2: c2.applying(transform))
            case .arc, .close: return element
            }
        }
    }

    /// `UIBezierPath.reversing()`: each subpath drawn the other way, in the
    /// same order. An open one starts from where it ended; a closed one
    /// keeps its start and goes round the other way.
    static func reversed(_ elements: [PathElement]) -> [PathElement] {
        var out: [PathElement] = []
        var segments: [PathElement] = []   // .line / .quadCurve / .curve
        var start: CGPoint?
        var pen: CGPoint?

        func flush(closed: Bool) {
            guard let first = start else { return }
            var froms = [first]            // where each segment starts
            for segment in segments.dropLast() {
                switch segment {
                case let .line(p), let .quadCurve(p, _), let .curve(p, _, _): froms.append(p)
                default: break
                }
            }
            let last = pen ?? first
            if closed {
                // The closing line, the other way round, comes first — of
                // no length where the subpath ends where it began, as
                // AppKit records it.
                out.append(.move(first))
                out.append(.line(last))
            } else {
                out.append(.move(last))
            }
            for (segment, from) in zip(segments, froms).reversed() {
                switch segment {
                case .line: out.append(.line(from))
                case let .quadCurve(_, c): out.append(.quadCurve(to: from, control: c))
                case let .curve(_, c1, c2): out.append(.curve(to: from, control1: c2, control2: c1))
                default: break
                }
            }
            if closed {
                // A last line back to the start is the close's to draw.
                if case .line(first)? = out.last, out.count > 1 { out.removeLast() }
                out.append(.close)
            }
            segments = []
            start = nil
        }

        for element in curvesOnly(elements) {
            switch element {
            case let .move(p):
                flush(closed: false)
                start = p
                pen = p
            case let .line(p), let .quadCurve(p, _), let .curve(p, _, _):
                if start == nil { start = pen ?? .zero }
                segments.append(element)
                pen = p
            case .close:
                flush(closed: true)
                pen = nil
            case .arc:
                break
            }
        }
        flush(closed: false)
        return out
    }
}
