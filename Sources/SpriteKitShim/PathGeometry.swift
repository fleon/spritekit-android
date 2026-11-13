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
