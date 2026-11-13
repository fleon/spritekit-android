import Foundation

/// Turns a recorded `CGPath` into 8-bit coverage.
///
/// This is CoreGraphics' job on Apple, and on Android nothing else does it:
/// `SKShapeNode` records a path and `SurfaceTexture`'s `CGContext` sites draw
/// every chunky button, panel, meter and focus ring in the game. So the port
/// needs one rasteriser and this is it.
///
/// **Swift rather than a vendored C library.** The two realistic
/// alternatives were cross-compiling something like NanoSVG's rasteriser or
/// writing one here. This is maybe 400 lines, it runs on cached masks rather
/// than per frame, and — the deciding reason — it lives in `GLESRenderer`,
/// the half of the renderer with no GL in it, so every edge case can be
/// tested on the Mac with no device, no context and no cmake run. A vendored
/// C rasteriser would have put a second set of pinned tarballs next to
/// FreeType in everyone's build, to save work that is not on a hot path.
///
/// Coverage is computed as area, not as a yes/no sample: each pixel row is
/// walked `subSamples` times in y, and each span contributes its exact
/// fractional width in x. That gives antialiasing close enough to
/// CoreGraphics' that a rounded button corner reads the same.
public enum PathRasteriser {

    /// Sub-scanlines per pixel row. Horizontal coverage is exact, so this
    /// only sets how finely a near-horizontal edge is graded; 16 is past the
    /// point where a rounded corner shows steps, and masks are cached, so
    /// the cost is paid once per distinct shape rather than per frame.
    public static let subSamples = 16

    /// How far a flattened curve may stray from the true one, in device
    /// pixels. A quarter of a pixel is below what antialiasing can show.
    public static let flatness: CGFloat = 0.25

    // MARK: - Masks

    /// An 8-bit coverage mask, and where it sits in the path's own space.
    ///
    /// `bounds` is in path points, so the renderer draws the mask as a quad
    /// through the node's transform and never has to know how it was
    /// rasterised.
    public struct Mask: Equatable {
        public var width: Int
        public var height: Int
        /// Row 0 is the **top** row, `bounds.maxY` in path space, as an
        /// image is normally stored. The renderer's UVs flip for it rather
        /// than the pixels being copied twice.
        public var pixels: [UInt8]
        public var bounds: CGRect
        /// Pixels per point.
        public var scale: CGFloat

        public var isEmpty: Bool { width <= 0 || height <= 0 }
        public var byteCount: Int { pixels.count }

        public init(width: Int, height: Int, pixels: [UInt8], bounds: CGRect, scale: CGFloat) {
            self.width = width
            self.height = height
            self.pixels = pixels
            self.bounds = bounds
            self.scale = scale
        }
    }

    public enum FillRule: Sendable, Hashable {
        case nonZero, evenOdd
    }

    /// Fills `path` at `scale` pixels per point.
    ///
    /// Nil when the path encloses nothing — an empty path, or one so small
    /// at this scale that it would not cover a pixel.
    public static func fill(
        _ path: CGPath,
        rule: FillRule = .nonZero,
        scale: CGFloat
    ) -> Mask? {
        let polygons = flatten(path, scale: scale).map(\.points).filter { $0.count > 2 }
        return rasterise(polygons, rule: rule, scale: scale)
    }

    /// Strokes `path` at `scale` pixels per point.
    ///
    /// The stroke is turned into outlines and filled non-zero, which is what
    /// CoreGraphics does too: overlapping joins and caps then union rather
    /// than darkening where they meet.
    public static func stroke(
        _ path: CGPath,
        width: CGFloat,
        cap: CGLineCap = .butt,
        join: CGLineJoin = .miter,
        miterLimit: CGFloat = 10,
        scale: CGFloat
    ) -> Mask? {
        guard width > 0 else { return nil }
        let outlines = strokeOutlines(
            flatten(path, scale: scale),
            width: width,
            cap: cap,
            join: join,
            miterLimit: miterLimit
        )
        return rasterise(outlines, rule: .nonZero, scale: scale)
    }

    // MARK: - Flattening

    /// One subpath as a polyline, in path points.
    public struct Subpath: Equatable {
        public var points: [CGPoint]
        public var isClosed: Bool
    }

    /// Breaks a path into polylines. Curves are subdivided finely enough that
    /// they stay within `flatness` device pixels of the true curve at
    /// `scale`, so a big rounded panel is not visibly faceted and a small one
    /// costs little.
    public static func flatten(_ path: CGPath, scale: CGFloat) -> [Subpath] {
        flatten(path.pathElements, scale: scale)
    }

    /// The same, from segments already read off a path. The tests build
    /// these directly: `.arc` is a thing only the shim records, so on the
    /// host there is no other way to reach that case.
    public static func flatten(_ elements: [PathElement], scale: CGFloat) -> [Subpath] {
        var subpaths: [Subpath] = []
        var current: [CGPoint] = []
        var closed = false
        var start = CGPoint.zero
        var pen = CGPoint.zero

        func finish() {
            if current.count > 1 { subpaths.append(Subpath(points: current, isClosed: closed)) }
            else if current.count == 1 { subpaths.append(Subpath(points: current, isClosed: false)) }
            current = []
            closed = false
        }

        for element in elements {
            switch element {
            case let .move(p):
                finish()
                current = [p]
                start = p
                pen = p

            case let .line(p):
                if current.isEmpty { current = [pen] }
                current.append(p)
                pen = p

            case let .quadCurve(p, c):
                if current.isEmpty { current = [pen] }
                appendQuad(from: pen, control: c, to: p, scale: scale, into: &current)
                pen = p

            case let .curve(p, c1, c2):
                if current.isEmpty { current = [pen] }
                appendCubic(from: pen, control1: c1, control2: c2, to: p, scale: scale, into: &current)
                pen = p

            case let .arc(centre, radius, from, to, clockwise):
                let first = point(on: centre, radius: radius, angle: from)
                if current.isEmpty {
                    current = [first]
                    start = first
                } else if hypot(first.x - pen.x, first.y - pen.y) > 1e-6 {
                    // CoreGraphics joins the pen to the arc's start with a line.
                    current.append(first)
                }
                appendArc(
                    centre: centre, radius: radius, from: from, to: to,
                    clockwise: clockwise, scale: scale, into: &current
                )
                pen = current.last ?? first

            case .close:
                closed = true
                finish()
                pen = start
                current = []
            }
        }
        finish()
        return subpaths
    }

    /// A point on a circle, in the scene's y-up space.
    private static func point(on centre: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
    }

    /// `UIBezierPath.addArc(clockwise:)` is defined in UIKit's y-down space,
    /// where the angle grows clockwise on screen. A path drawn there and used
    /// in SpriteKit's y-up space therefore sweeps with the angle **rising**
    /// when `clockwise` is true — which is what the game's own two call sites
    /// expect: the loading spinner's arc grows from nothing as its end angle
    /// rises, and `UIBezierPath(roundedRect:)`'s corners join up only this
    /// way round.
    private static func appendArc(
        centre: CGPoint,
        radius: CGFloat,
        from: CGFloat,
        to: CGFloat,
        clockwise: Bool,
        scale: CGFloat,
        into points: inout [CGPoint]
    ) {
        var sweep = to - from
        if clockwise {
            while sweep < 0 { sweep += .pi * 2 }
        } else {
            while sweep > 0 { sweep -= .pi * 2 }
        }
        guard radius > 0, sweep != 0 else { return }

        // Enough segments that the chord's sag stays under `flatness`.
        let pixels = radius * max(scale, 0.0001)
        let perSegment = 2 * acos(max(-1, min(1, 1 - flatness / max(pixels, flatness))))
        let steps = max(2, Int((abs(sweep) / max(perSegment, 0.01)).rounded(.up)))
        for step in 1...steps {
            let angle = from + sweep * CGFloat(step) / CGFloat(steps)
            points.append(point(on: centre, radius: radius, angle: angle))
        }
    }

    private static func appendQuad(
        from a: CGPoint, control c: CGPoint, to b: CGPoint,
        scale: CGFloat, into points: inout [CGPoint]
    ) {
        let steps = curveSteps([a, c, b], scale: scale)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let u = 1 - t
            points.append(CGPoint(
                x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                y: u * u * a.y + 2 * u * t * c.y + t * t * b.y
            ))
        }
    }

    private static func appendCubic(
        from a: CGPoint, control1 c1: CGPoint, control2 c2: CGPoint, to b: CGPoint,
        scale: CGFloat, into points: inout [CGPoint]
    ) {
        let steps = curveSteps([a, c1, c2, b], scale: scale)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let u = 1 - t
            points.append(CGPoint(
                x: u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x,
                y: u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y
            ))
        }
    }

    /// Segments for a curve, from the length of its control polygon in
    /// device pixels. Crude next to adaptive subdivision, and enough: the
    /// error of a uniform split falls as the square of the count, so a
    /// 60-pixel curve in eight pieces is already under a quarter of a pixel.
    private static func curveSteps(_ control: [CGPoint], scale: CGFloat) -> Int {
        var length: CGFloat = 0
        for i in 1 ..< control.count {
            length += hypot(control[i].x - control[i - 1].x, control[i].y - control[i - 1].y)
        }
        let pixels = length * max(scale, 0.0001)
        return max(2, min(128, Int((sqrt(pixels / max(flatness, 0.01)) * 1.2).rounded(.up))))
    }

    // MARK: - Stroking

    /// The outlines of a stroke: segment bodies, joins and caps, each a
    /// closed polygon wound the same way so filling them non-zero unions
    /// them instead of cancelling where they overlap.
    static func strokeOutlines(
        _ subpaths: [Subpath],
        width: CGFloat,
        cap: CGLineCap,
        join: CGLineJoin,
        miterLimit: CGFloat
    ) -> [[CGPoint]] {
        let half = width / 2
        var polygons: [[CGPoint]] = []

        for subpath in subpaths {
            var points = dedupe(subpath.points)
            if subpath.isClosed, points.count > 2,
               distance(points[0], points[points.count - 1]) < 1e-9 {
                points.removeLast()
            }

            // A subpath that goes nowhere: a dot, which round and square
            // caps still draw and a butt cap does not.
            guard points.count > 1 else {
                guard let only = points.first else { continue }
                switch cap {
                case .round: polygons.append(circle(at: only, radius: half))
                case .square: polygons.append(square(at: only, radius: half))
                default: break          // butt draws nothing at all
                }
                continue
            }

            let closed = subpath.isClosed && points.count > 2
            let count = points.count
            let segments = closed ? count : count - 1

            for i in 0 ..< segments {
                let a = points[i]
                let b = points[(i + 1) % count]
                guard let n = normal(from: a, to: b, length: half) else { continue }
                polygons.append([
                    CGPoint(x: a.x + n.x, y: a.y + n.y),
                    CGPoint(x: b.x + n.x, y: b.y + n.y),
                    CGPoint(x: b.x - n.x, y: b.y - n.y),
                    CGPoint(x: a.x - n.x, y: a.y - n.y),
                ])
            }

            // Joins at every interior vertex, and at every vertex of a
            // closed subpath.
            let joins = closed ? Array(0 ..< count) : Array(1 ..< max(count - 1, 1))
            for i in joins {
                let previous = points[(i - 1 + count) % count]
                let v = points[i]
                let next = points[(i + 1) % count]
                appendJoin(
                    at: v, from: previous, to: next,
                    half: half, join: join, miterLimit: miterLimit,
                    into: &polygons
                )
            }

            if !closed {
                appendCap(at: points[0], towards: points[1], half: half, cap: cap, into: &polygons)
                appendCap(
                    at: points[count - 1], towards: points[count - 2],
                    half: half, cap: cap, into: &polygons
                )
            }
        }

        return polygons.map(orientPositively)
    }

    private static func appendJoin(
        at v: CGPoint,
        from previous: CGPoint,
        to next: CGPoint,
        half: CGFloat,
        join: CGLineJoin,
        miterLimit: CGFloat,
        into polygons: inout [[CGPoint]]
    ) {
        guard let d0 = direction(from: previous, to: v),
              let d1 = direction(from: v, to: next) else { return }

        let cross = d0.x * d1.y - d0.y * d1.x
        // Straight on: nothing to fill in.
        guard abs(cross) > 1e-9 || d0.x * d1.x + d0.y * d1.y < 0 else { return }

        if join == .round {
            polygons.append(circle(at: v, radius: half))
            return
        }

        // The outside of the turn is the side the two segment rectangles
        // leave a wedge on: right of the travel for a left turn, left for a
        // right one.
        let side: CGFloat = cross > 0 ? -1 : 1
        let n0 = CGPoint(x: -d0.y * half * side, y: d0.x * half * side)
        let n1 = CGPoint(x: -d1.y * half * side, y: d1.x * half * side)
        let outer0 = CGPoint(x: v.x + n0.x, y: v.y + n0.y)
        let outer1 = CGPoint(x: v.x + n1.x, y: v.y + n1.y)

        if join == .miter {
            // cos(theta) between the segments; the miter runs 1/sin(theta/2)
            // half-widths out, which is what the limit is measured against.
            let cosTheta = max(-1, min(1, -(d0.x * d1.x + d0.y * d1.y)))
            let halfAngle = acos(cosTheta) / 2
            let sinHalf = sin(halfAngle)
            if sinHalf > 1e-6, 1 / sinHalf <= miterLimit {
                var bisector = CGPoint(x: n0.x + n1.x, y: n0.y + n1.y)
                let length = hypot(bisector.x, bisector.y)
                if length > 1e-9 {
                    bisector = CGPoint(x: bisector.x / length, y: bisector.y / length)
                    let reach = half / sinHalf
                    let tip = CGPoint(x: v.x + bisector.x * reach, y: v.y + bisector.y * reach)
                    polygons.append([v, outer0, tip, outer1])
                    return
                }
            }
        }

        polygons.append([v, outer0, outer1])
    }

    private static func appendCap(
        at end: CGPoint,
        towards inner: CGPoint,
        half: CGFloat,
        cap: CGLineCap,
        into polygons: inout [[CGPoint]]
    ) {
        switch cap {
        case .round:
            polygons.append(circle(at: end, radius: half))
        case .square:
            guard let d = direction(from: inner, to: end) else { return }
            let n = CGPoint(x: -d.y * half, y: d.x * half)
            let out = CGPoint(x: d.x * half, y: d.y * half)
            polygons.append([
                CGPoint(x: end.x + n.x, y: end.y + n.y),
                CGPoint(x: end.x + n.x + out.x, y: end.y + n.y + out.y),
                CGPoint(x: end.x - n.x + out.x, y: end.y - n.y + out.y),
                CGPoint(x: end.x - n.x, y: end.y - n.y),
            ])
        default:
            return                      // butt: the segment's own end is the end
        }
    }

    private static func circle(at centre: CGPoint, radius: CGFloat) -> [CGPoint] {
        let steps = max(8, min(64, Int((radius * 2).rounded(.up)) * 4))
        return (0 ..< steps).map {
            let angle = CGFloat($0) / CGFloat(steps) * .pi * 2
            return CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
        }
    }

    private static func square(at centre: CGPoint, radius: CGFloat) -> [CGPoint] {
        [
            CGPoint(x: centre.x - radius, y: centre.y - radius),
            CGPoint(x: centre.x + radius, y: centre.y - radius),
            CGPoint(x: centre.x + radius, y: centre.y + radius),
            CGPoint(x: centre.x - radius, y: centre.y + radius),
        ]
    }

    private static func dedupe(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in points where out.isEmpty || distance(out[out.count - 1], p) > 1e-9 {
            out.append(p)
        }
        return out
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private static func direction(from a: CGPoint, to b: CGPoint) -> CGPoint? {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 1e-9 else { return nil }
        return CGPoint(x: dx / length, y: dy / length)
    }

    private static func normal(from a: CGPoint, to b: CGPoint, length: CGFloat) -> CGPoint? {
        guard let d = direction(from: a, to: b) else { return nil }
        return CGPoint(x: -d.y * length, y: d.x * length)
    }

    /// Winds a polygon counter-clockwise, so a set of them fills non-zero as
    /// a union rather than punching holes where two overlap.
    private static func orientPositively(_ polygon: [CGPoint]) -> [CGPoint] {
        var twiceArea: CGFloat = 0
        for i in 0 ..< polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            twiceArea += a.x * b.y - b.x * a.y
        }
        return twiceArea < 0 ? polygon.reversed() : polygon
    }

    // MARK: - Scanline

    /// One edge in device pixels, pointing up the page, with the sign of its
    /// original direction so winding can be counted.
    private struct Edge {
        var x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat
        var winding: Int
    }

    /// The common path: polygons in path points, coverage out.
    static func rasterise(_ polygons: [[CGPoint]], rule: FillRule, scale: CGFloat) -> Mask? {
        guard scale > 0, !polygons.isEmpty else { return nil }

        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for polygon in polygons {
            for p in polygon {
                guard p.x.isFinite, p.y.isFinite else { return nil }
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }

        // A pixel of margin all round, so an edge that lands exactly on the
        // boundary still has somewhere to put its partial coverage and a
        // linear tap at the mask's rim reads zero rather than clamping the
        // last column outward.
        let margin = 1 / scale
        let bounds = CGRect(
            x: minX - margin, y: minY - margin,
            width: (maxX - minX) + margin * 2, height: (maxY - minY) + margin * 2
        )
        // Rounded up, but off a hair, so a mask whose height lands on 50
        // pixels by two different routes does not come out 51 one of those
        // times — the arc's last point and a curve's are not bit-identical.
        let grain: CGFloat = 1e-6
        let width = max(1, Int((bounds.width * scale - grain).rounded(.up)))
        let height = max(1, Int((bounds.height * scale - grain).rounded(.up)))
        guard width <= 8192, height <= 8192 else { return nil }

        // Into device pixels, row 0 at the top: y grows down the mask while
        // it grows up the path.
        let inPixels = polygons.map { polygon in
            polygon.map {
                CGPoint(x: ($0.x - bounds.minX) * scale, y: (bounds.maxY - $0.y) * scale)
            }
        }
        let pixels = coverage(
            inPixels, rule: rule,
            in: PixelBox(x: 0, y: 0, width: width, height: height)
        )
        guard !pixels.isEmpty else { return nil }
        return Mask(width: width, height: height, pixels: pixels, bounds: bounds, scale: scale)
    }

    /// A window on a pixel grid: where a run of coverage sits and how big it is.
    public struct PixelBox: Equatable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        public var isEmpty: Bool { width <= 0 || height <= 0 }
        public var count: Int { max(0, width) * max(0, height) }
        public var maxX: Int { x + width }
        public var maxY: Int { y + height }

        public func intersection(_ other: PixelBox) -> PixelBox {
            let left = max(x, other.x), top = max(y, other.y)
            let right = min(maxX, other.maxX), bottom = min(maxY, other.maxY)
            return PixelBox(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
        }

        /// The whole-pixel box covering `rect`, which is in the same pixel
        /// space: `floor` on the near edges, `ceil` on the far ones, so a
        /// shape's partial pixels are inside it.
        public static func covering(_ rect: CGRect) -> PixelBox {
            guard rect.width.isFinite, rect.height.isFinite,
                  rect.minX.isFinite, rect.minY.isFinite else { return PixelBox(x: 0, y: 0, width: 0, height: 0) }
            let left = Int(rect.minX.rounded(.down)), top = Int(rect.minY.rounded(.down))
            let right = Int(rect.maxX.rounded(.up)), bottom = Int(rect.maxY.rounded(.up))
            return PixelBox(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
        }
    }

    /// Coverage for polygons **already in pixels**, y down, with (0, 0) the
    /// top left of the grid they are measured against.
    ///
    /// This is the half of the rasteriser `CGContext` needs. A context owns
    /// its bitmap, so it cannot accept whatever bounds a mask happens to
    /// want: it has to ask for coverage over a window of pixels it chose —
    /// the shape's bounds clipped to the clip and the canvas. `rasterise`
    /// above is the other caller, which picks its own bounds and then asks
    /// for all of them.
    ///
    /// Returns `box.width * box.height` bytes, row 0 being `box.y`, or an
    /// empty array for an empty box.
    public static func coverage(
        _ polygons: [[CGPoint]],
        rule: FillRule,
        in box: PixelBox
    ) -> [UInt8] {
        guard !box.isEmpty, !polygons.isEmpty else { return [] }

        // Edges in the box's own space, so the scanline walk counts rows
        // from 0 however far down the bitmap the box sits.
        var edges: [Edge] = []
        edges.reserveCapacity(polygons.reduce(0) { $0 + $1.count })
        for polygon in polygons where polygon.count > 2 {
            for i in 0 ..< polygon.count {
                let a = polygon[i]
                let b = polygon[(i + 1) % polygon.count]
                guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { continue }
                let ax = a.x - CGFloat(box.x), ay = a.y - CGFloat(box.y)
                let bx = b.x - CGFloat(box.x), by = b.y - CGFloat(box.y)
                guard ay != by else { continue }
                edges.append(
                    ay < by
                        ? Edge(x0: ax, y0: ay, x1: bx, y1: by, winding: 1)
                        : Edge(x0: bx, y0: by, x1: ax, y1: ay, winding: -1)
                )
            }
        }
        guard !edges.isEmpty else { return [] }

        // Edges sorted by their top, so each scanline only has to advance a
        // cursor rather than look at every edge in the path.
        edges.sort { $0.y0 < $1.y0 }

        let width = box.width, height = box.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        var row = [CGFloat](repeating: 0, count: width)
        var crossings: [(x: CGFloat, winding: Int)] = []
        crossings.reserveCapacity(16)
        var active: [Int] = []
        var next = 0
        let weight = 1 / CGFloat(subSamples)

        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0 ..< height {
                for i in row.indices { row[i] = 0 }
                let rowTop = CGFloat(y)
                let rowBottom = rowTop + 1

                while next < edges.count, edges[next].y0 < rowBottom {
                    active.append(next)
                    next += 1
                }
                active.removeAll { edges[$0].y1 <= rowTop }
                if active.isEmpty { continue }

                for sample in 0 ..< subSamples {
                    let sy = rowTop + (CGFloat(sample) + 0.5) * weight
                    crossings.removeAll(keepingCapacity: true)
                    for index in active {
                        let edge = edges[index]
                        guard edge.y0 <= sy, sy < edge.y1 else { continue }
                        let t = (sy - edge.y0) / (edge.y1 - edge.y0)
                        crossings.append((edge.x0 + (edge.x1 - edge.x0) * t, edge.winding))
                    }
                    guard crossings.count > 1 else { continue }
                    crossings.sort { $0.x < $1.x }

                    var winding = 0
                    var spanStart: CGFloat = 0
                    for crossing in crossings {
                        let wasInside = inside(winding, rule)
                        winding += rule == .evenOdd ? 1 : crossing.winding
                        let isInside = inside(winding, rule)
                        if !wasInside, isInside {
                            spanStart = crossing.x
                        } else if wasInside, !isInside {
                            add(span: spanStart, to: crossing.x, weight: weight, width: width, into: &row)
                        }
                    }
                }

                let base = y * width
                for x in 0 ..< width where row[x] > 0 {
                    out[base + x] = UInt8(max(0, min(255, (row[x] * 255).rounded())))
                }
            }
        }

        return pixels
    }

    private static func inside(_ winding: Int, _ rule: FillRule) -> Bool {
        rule == .evenOdd ? winding % 2 != 0 : winding != 0
    }

    /// Adds a horizontal span's coverage, exactly: whole pixels take the
    /// full weight and the two ends take their fraction of it.
    private static func add(
        span from: CGFloat,
        to: CGFloat,
        weight: CGFloat,
        width: Int,
        into row: inout [CGFloat]
    ) {
        let start = max(from, 0)
        let end = min(to, CGFloat(width))
        guard end > start else { return }

        let firstPixel = Int(start)
        let lastPixel = min(Int(end), width - 1)
        if firstPixel == lastPixel {
            row[firstPixel] += (end - start) * weight
            return
        }
        row[firstPixel] += (CGFloat(firstPixel + 1) - start) * weight
        if firstPixel + 1 <= lastPixel - 1 {
            for x in (firstPixel + 1) ... (lastPixel - 1) { row[x] += weight }
        }
        let tail = end - CGFloat(lastPixel)
        if tail > 0 { row[lastPixel] += tail * weight }
    }
}
