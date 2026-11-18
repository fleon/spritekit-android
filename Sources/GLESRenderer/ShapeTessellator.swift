import Foundation
import SpriteKitShim

/// `SKShapeNode`'s fill and stroke as triangles, the way a game engine's
/// draw node makes them, rather than as a coverage mask.
///
/// The idea is axmol's `DrawNode` (MIT; Chipmunk's debug drawing before
/// it): turn a shape into coloured triangles once, in the node's own
/// space, and let the node's transform carry them. A shape that moves,
/// turns, fades or scales then costs no rasterising and no upload, and its
/// triangles join the batch of colour sprites around them instead of being
/// a draw call (and a texture) of their own. A shape whose path changes
/// every frame is re-tessellated, which costs microseconds where a mask
/// cost milliseconds and had to lag a frame behind (`MaskLag`).
///
/// `DrawNode` itself leaves edges aliased (its fragment shader `step`s),
/// draws strokes as quads with round ends overlapping at every vertex, and
/// has no joins. Here every edge is feathered across one device pixel in
/// the geometry (a vertex at the rim carries coverage 0, one a pixel in
/// carries 1), centred on the true edge so that a pixel's alpha follows
/// how much of it the shape covers, as `PathRasteriser`'s does. Strokes
/// are one strip a subpath with CoreGraphics' joins and caps, built the
/// way NanoVG expands a stroke: the inner side of a turn meets at one
/// point, the outer side is mitred, bevelled or rounded.
///
/// What it does not take on returns nil and the shape keeps its mask:
/// fills of more than one subpath unless they sit apart, self-crossing
/// outlines, and paths with too many points to test for crossings.
public enum ShapeTessellator {

    /// Triangles in the node's own space. Coverage multiplies the colour's
    /// alpha: 1 inside, falling to 0 at a feathered rim.
    public struct Mesh: Equatable {
        public var positions: [SIMD2<Float>] = []
        public var coverage: [Float] = []
        public var indices: [UInt16] = []

        public init() {}

        public var isEmpty: Bool { indices.isEmpty }
        public var vertexCount: Int { positions.count }
        /// What keeping it costs, roughly.
        public var byteCount: Int { positions.count * 12 + indices.count * 2 }
    }

    /// The fill's points are tested pairwise for crossings, so a path with
    /// more is left to the mask. A rounded panel is a few dozen points.
    public static let maximumFillPoints = 768

    /// Fills `subpaths` (from `PathRasteriser.flatten` at `scale`), each
    /// closed implicitly. Nil when it isn't a fill this can make.
    public static func fill(_ subpaths: [PathRasteriser.Subpath], scale: CGFloat) -> Mesh? {
        guard scale > 0, scale.isFinite else { return nil }
        var polygons: [[CGPoint]] = []
        var total = 0
        for subpath in subpaths {
            var points = dedupe(subpath.points)
            if points.count > 2, distance(points[0], points[points.count - 1]) < epsilon { points.removeLast() }
            points = withoutStraightVertices(points)
            guard points.count > 2 else { continue }
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            total += points.count
            guard total <= maximumFillPoints else { return nil }
            // Before the area: a figure eight's lobes cancel to none.
            guard isSimple(points) else { return nil }
            let area = signedArea(points)
            guard abs(area) > epsilon * epsilon else { continue }
            polygons.append(area < 0 ? points.reversed() : points)
        }
        if polygons.isEmpty { return Mesh() }

        // Several subpaths fill as their union only where none overlaps
        // another: then non-zero and even-odd agree with drawing each.
        if polygons.count > 1 {
            guard polygons.count <= 32 else { return nil }
            let boxes = polygons.map(boundingBox)
            for i in 0 ..< boxes.count {
                for j in (i + 1) ..< boxes.count {
                    let a = boxes[i], b = boxes[j]
                    if a.minX <= b.maxX, b.minX <= a.maxX, a.minY <= b.maxY, b.minY <= a.maxY { return nil }
                }
            }
        }

        var builder = Builder()
        for polygon in polygons {
            guard appendFill(polygon, fringe: 1 / scale, coverage: 1, into: &builder) else { return nil }
        }
        return builder.mesh()
    }

    /// Strokes `subpaths` (from `PathRasteriser.flatten` at `scale`).
    public static func stroke(
        _ subpaths: [PathRasteriser.Subpath],
        width: CGFloat,
        cap: CGLineCap,
        join: CGLineJoin,
        miterLimit: CGFloat = 10,
        scale: CGFloat
    ) -> Mesh? {
        guard scale > 0, scale.isFinite, width.isFinite else { return nil }
        guard width > 0 else { return Mesh() }
        let fringe = 1 / scale
        // A stroke thinner than a pixel is drawn a pixel wide and fainter,
        // which is what its coverage comes to.
        let pen = Pen(
            width: width,
            half: width / 2,
            fringe: fringe,
            scale: scale,
            join: join,
            miterLimit: miterLimit
        )

        var builder = Builder()
        for subpath in subpaths {
            var points = dedupe(subpath.points)
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            var closed = subpath.isClosed
            if closed, points.count > 2, distance(points[0], points[points.count - 1]) < epsilon { points.removeLast() }
            if points.count < 3 { closed = false }

            guard points.count > 1 else {
                // A subpath that goes nowhere: a dot, which round and
                // square caps still draw and a butt cap does not.
                guard let only = points.first else { continue }
                switch cap {
                case .round:
                    let steps = arcSteps(radius: pen.half, sweep: 2 * .pi, scale: scale)
                    let disc = (0 ..< max(steps, 8)).map {
                        point(on: only, radius: pen.half, angle: CGFloat($0) / CGFloat(max(steps, 8)) * 2 * .pi)
                    }
                    guard appendFill(disc, fringe: fringe, coverage: pen.coverage, into: &builder) else { return nil }
                case .square:
                    let h = pen.half
                    let square = [
                        CGPoint(x: only.x - h, y: only.y - h), CGPoint(x: only.x + h, y: only.y - h),
                        CGPoint(x: only.x + h, y: only.y + h), CGPoint(x: only.x - h, y: only.y + h),
                    ]
                    guard appendFill(square, fringe: fringe, coverage: pen.coverage, into: &builder) else { return nil }
                default:
                    break
                }
                continue
            }
            appendStroke(points, closed: closed, cap: cap, pen: pen, trueHalf: width / 2, into: &builder)
        }
        return builder.mesh()
    }

    // MARK: - Fills

    /// A simple counter-clockwise polygon, triangulated over its rim pulled
    /// in by half its feather, with a ramp out to its rim pushed out as far.
    ///
    /// Each edge feathers over `|nx| + |ny|` pixels: what a pixel's square
    /// spans across an edge with normal `n`, so a diagonal's ramp is as wide
    /// as its exact coverage's. False, and the shape keeps its mask, where
    /// the polygon is thinner than its feather: pulled in, its rim turns
    /// inside out and the fill would cover a band where only a sliver is.
    private static func appendFill(_ polygon: [CGPoint], fringe: CGFloat, coverage: Float, into builder: inout Builder) -> Bool {
        guard let triangles = triangulate(polygon) else { return false }
        let n = polygon.count
        var normals: [CGPoint] = []
        var halves: [CGFloat] = []
        normals.reserveCapacity(n)
        halves.reserveCapacity(n)
        for i in 0 ..< n {
            // Outward is the right of travel round a counter-clockwise rim.
            let normal = rightNormal(from: polygon[i], to: polygon[(i + 1) % n]) ?? .zero
            normals.append(normal)
            halves.append(feather(normal) * fringe / 2)
        }
        var inside: [CGPoint] = []
        var outside: [CGPoint] = []
        inside.reserveCapacity(n)
        outside.reserveCapacity(n)
        for i in 0 ..< n {
            let previous = (i - 1 + n) % n
            let m = offset(normals[previous], halves[previous], normals[i], halves[i])
            let v = polygon[i]
            inside.append(CGPoint(x: v.x - m.x, y: v.y - m.y))
            outside.append(CGPoint(x: v.x + m.x, y: v.y + m.y))
        }
        for i in 0 ..< n {
            let j = (i + 1) % n
            let edge = CGPoint(x: polygon[j].x - polygon[i].x, y: polygon[j].y - polygon[i].y)
            if (inside[j].x - inside[i].x) * edge.x + (inside[j].y - inside[i].y) * edge.y <= 0 { return false }
        }
        let inner = inside.map { builder.add($0, coverage) }
        let outer = outside.map { builder.add($0, 0) }
        for (a, b, c) in triangles { builder.triangle(inner[a], inner[b], inner[c]) }
        for i in 0 ..< n {
            let j = (i + 1) % n
            builder.quad(inner[i], outer[i], outer[j], inner[j])
        }
        return true
    }

    /// How many pixels an edge with unit normal `n` feathers over.
    private static func feather(_ n: CGPoint) -> CGFloat {
        max(1, abs(n.x) + abs(n.y))
    }

    /// Where a vertex goes when the edge before it moves `h0` along `n0`
    /// and the one after moves `h1` along `n1`. With equal moves it is
    /// axmol's `(n0 + n1) / (n0·n1 + 1)`, scaled. Capped, so a needle-sharp
    /// corner's feather stays near it.
    private static func offset(_ n0: CGPoint, _ h0: CGFloat, _ n1: CGPoint, _ h1: CGFloat) -> CGPoint {
        let determinant = n0.x * n1.y - n0.y * n1.x
        var m: CGPoint
        if abs(determinant) > 1e-6 {
            m = CGPoint(x: (h0 * n1.y - h1 * n0.y) / determinant, y: (n0.x * h1 - n1.x * h0) / determinant)
        } else {
            // Straight on (or straight back): along the shared normal.
            let h = (h0 + h1) / 2
            m = CGPoint(x: n0.x * h, y: n0.y * h)
        }
        let length = hypot(m.x, m.y), limit = 4 * max(h0, h1)
        if length > limit { m = CGPoint(x: m.x / length * limit, y: m.y / length * limit) }
        return m
    }

    /// Triangles for a simple counter-clockwise polygon, as index triples: a
    /// fan when it's convex, ears clipped otherwise. Nil if no ear is found,
    /// which a simple polygon always has, so only for degenerate input.
    static func triangulate(_ polygon: [CGPoint]) -> [(Int, Int, Int)]? {
        let n = polygon.count
        guard n >= 3 else { return [] }
        if isConvex(polygon) {
            return (1 ..< n - 1).map { (0, $0, $0 + 1) }
        }

        var remaining = Array(0 ..< n)
        var triangles: [(Int, Int, Int)] = []
        triangles.reserveCapacity(n - 2)
        var cursor = 0
        var sinceLastEar = 0
        while remaining.count > 3 {
            let m = remaining.count
            if sinceLastEar > m { return nil }
            let k = cursor % m
            let i0 = remaining[(k - 1 + m) % m], i1 = remaining[k], i2 = remaining[(k + 1) % m]
            let a = polygon[i0], b = polygon[i1], c = polygon[i2]
            let turn = cross(b.x - a.x, b.y - a.y, c.x - b.x, c.y - b.y)
            if abs(turn) <= epsilon * epsilon, (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y) > 0 {
                // Straight through: no triangle, just one point fewer.
                remaining.remove(at: k)
                sinceLastEar = 0
                continue
            }
            var isEar = turn > 0
            if isEar {
                for j in remaining where j != i0 && j != i1 && j != i2 {
                    let p = polygon[j]
                    if p == a || p == b || p == c { continue }
                    if contains(p, a, b, c) { isEar = false; break }
                }
            }
            if isEar {
                triangles.append((i0, i1, i2))
                remaining.remove(at: k)
                sinceLastEar = 0
                // Stay on the same index: its new neighbour may be an ear now.
                cursor = k == 0 ? m - 2 : k - 1
            } else {
                cursor = k + 1
                sinceLastEar += 1
            }
        }
        triangles.append((remaining[0], remaining[1], remaining[2]))
        return triangles
    }

    private static func isConvex(_ polygon: [CGPoint]) -> Bool {
        let n = polygon.count
        for i in 0 ..< n {
            let a = polygon[i], b = polygon[(i + 1) % n], c = polygon[(i + 2) % n]
            if cross(b.x - a.x, b.y - a.y, c.x - b.x, c.y - b.y) < -epsilon * epsilon { return false }
        }
        return true
    }

    /// Whether `p` is in triangle `abc` (counter-clockwise), edges included.
    private static func contains(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        cross(b.x - a.x, b.y - a.y, p.x - a.x, p.y - a.y) >= 0
            && cross(c.x - b.x, c.y - b.y, p.x - b.x, p.y - b.y) >= 0
            && cross(a.x - c.x, a.y - c.y, p.x - c.x, p.y - c.y) >= 0
    }

    /// No two edges cross or touch, other than neighbours at their shared
    /// point. Pairwise, which `maximumFillPoints` keeps affordable, and the
    /// answer is cached with the mesh.
    static func isSimple(_ polygon: [CGPoint]) -> Bool {
        let n = polygon.count
        guard n > 3 else { return true }
        var boxes: [(minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat)] = []
        boxes.reserveCapacity(n)
        for i in 0 ..< n {
            let a = polygon[i], b = polygon[(i + 1) % n]
            boxes.append((min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y)))
        }
        for i in 0 ..< n {
            let bi = boxes[i]
            for j in stride(from: i + 2, to: n, by: 1) {
                if i == 0, j == n - 1 { continue }       // neighbours round the end
                let bj = boxes[j]
                if bj.minX > bi.maxX || bj.maxX < bi.minX || bj.minY > bi.maxY || bj.maxY < bi.minY { continue }
                if segmentsMeet(polygon[i], polygon[(i + 1) % n], polygon[j], polygon[(j + 1) % n]) { return false }
            }
        }
        return true
    }

    private static func segmentsMeet(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func side(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            cross(b.x - a.x, b.y - a.y, c.x - a.x, c.y - a.y)
        }
        let d1 = side(p3, p4, p1), d2 = side(p3, p4, p2)
        let d3 = side(p1, p2, p3), d4 = side(p1, p2, p4)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return true }
        func onSegment(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> Bool {
            min(a.x, b.x) <= p.x && p.x <= max(a.x, b.x) && min(a.y, b.y) <= p.y && p.y <= max(a.y, b.y)
        }
        if d1 == 0, onSegment(p3, p4, p1) { return true }
        if d2 == 0, onSegment(p3, p4, p2) { return true }
        if d3 == 0, onSegment(p1, p2, p3) { return true }
        if d4 == 0, onSegment(p1, p2, p4) { return true }
        return false
    }

    // MARK: - Strokes

    /// The stroke's measures, in points. `half` is at least half a pixel.
    private struct Pen {
        var width: CGFloat
        var half: CGFloat
        var fringe: CGFloat
        var scale: CGFloat
        var join: CGLineJoin
        var miterLimit: CGFloat
        /// Where full coverage ends and where the feather reaches nothing.
        ///
        /// Across the stroke its exact coverage is a trapezoid: the width
        /// swept by a pixel's span, `fringe`. Its foot reaches `(width +
        /// fringe) / 2` out, its top `|width - fringe| / 2`, at full
        /// coverage unless the stroke is thinner than the span: then at
        /// `width / fringe`, a hairline drawn fainter rather than wider.
        var core: CGFloat { abs(width - fringe) / 2 }
        var outer: CGFloat { (width + fringe) / 2 }
        var coverage: Float { Float(min(1, width / fringe)) }

        /// The pen where the stroke runs along `direction`: its feather as
        /// wide as a pixel's square reaches across it (`feather`).
        func feathered(across direction: CGPoint) -> Pen {
            var pen = self
            pen.fringe *= ShapeTessellator.feather(CGPoint(x: -direction.y, y: direction.x))
            return pen
        }
    }

    /// The direction halfway between two, for the feather at a join.
    private static func bisector(_ d0: CGPoint, _ d1: CGPoint) -> CGPoint {
        let sum = CGPoint(x: d0.x + d1.x, y: d0.y + d1.y)
        let length = hypot(sum.x, sum.y)
        return length > 1e-9 ? CGPoint(x: sum.x / length, y: sum.y / length) : d0
    }

    /// One cross-section of a stroke: two points each side of the path, the
    /// outer of each feathered to nothing. `plus` is the left of travel.
    private struct Section {
        var plusOuter: Int, plusCore: Int, minusCore: Int, minusOuter: Int
    }

    private static func section(at p: CGPoint, normal n: CGPoint, pen: Pen, coverage: Float, into builder: inout Builder) -> Section {
        let o = pen.outer, c = pen.core
        return Section(
            plusOuter: builder.add(CGPoint(x: p.x + n.x * o, y: p.y + n.y * o), 0),
            plusCore: builder.add(CGPoint(x: p.x + n.x * c, y: p.y + n.y * c), coverage),
            minusCore: builder.add(CGPoint(x: p.x - n.x * c, y: p.y - n.y * c), coverage),
            minusOuter: builder.add(CGPoint(x: p.x - n.x * o, y: p.y - n.y * o), 0)
        )
    }

    /// The body between two sections: three quads, feather, core, feather.
    private static func bridge(_ s: Section, _ t: Section, into builder: inout Builder) {
        builder.quad(s.plusOuter, s.plusCore, t.plusCore, t.plusOuter)
        builder.quad(s.plusCore, s.minusCore, t.minusCore, t.plusCore)
        builder.quad(s.minusCore, s.minusOuter, t.minusOuter, t.minusCore)
    }

    private static func appendStroke(
        _ points: [CGPoint],
        closed: Bool,
        cap: CGLineCap,
        pen: Pen,
        trueHalf: CGFloat,
        into builder: inout Builder
    ) {
        let n = points.count
        let segments = closed ? n : n - 1
        var directions: [CGPoint] = []
        var lengths: [CGFloat] = []
        directions.reserveCapacity(segments)
        lengths.reserveCapacity(segments)
        for i in 0 ..< segments {
            let a = points[i], b = points[(i + 1) % n]
            let length = distance(a, b)
            lengths.append(length)
            directions.append(CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length))
        }

        // For each vertex, the section the segment arriving ends on and the
        // one the segment leaving starts from.
        var arriving = [Section?](repeating: nil, count: n)
        var leaving = [Section?](repeating: nil, count: n)

        let joined = closed ? Array(0 ..< n) : Array(1 ..< n - 1)
        for i in joined {
            let incoming = (i - 1 + segments) % segments
            let (a, b) = appendJoin(
                at: points[i],
                from: directions[incoming], length: lengths[incoming],
                to: directions[i], length: lengths[i],
                pen: pen.feathered(across: bisector(directions[incoming], directions[i])), into: &builder
            )
            arriving[i] = a
            leaving[i] = b
        }

        if !closed {
            leaving[0] = appendCap(
                at: points[0], direction: directions[0], isStart: true,
                cap: cap, pen: pen.feathered(across: directions[0]), trueHalf: trueHalf, into: &builder
            )
            arriving[n - 1] = appendCap(
                at: points[n - 1], direction: directions[segments - 1], isStart: false,
                cap: cap, pen: pen.feathered(across: directions[segments - 1]), trueHalf: trueHalf, into: &builder
            )
        }

        for i in 0 ..< segments {
            guard let s = leaving[i], let t = arriving[(i + 1) % n] else { continue }
            bridge(s, t, into: &builder)
        }
    }

    /// The sections either side of a join at `v`, and the wedge filling the
    /// outside of the turn between them.
    private static func appendJoin(
        at v: CGPoint,
        from d0: CGPoint, length length0: CGFloat,
        to d1: CGPoint, length length1: CGFloat,
        pen: Pen,
        into builder: inout Builder
    ) -> (Section, Section) {
        let n0 = CGPoint(x: -d0.y, y: d0.x), n1 = CGPoint(x: -d1.y, y: d1.x)
        let turn = cross(d0.x, d0.y, d1.x, d1.y)
        let dot = d0.x * d1.x + d0.y * d1.y
        let k = pen.coverage

        // Where the two offset edges meet, per unit of offset, on the left.
        let denominator = 1 + dot
        let miter = denominator > 1e-9 ? CGPoint(x: (n0.x + n1.x) / denominator, y: (n0.y + n1.y) / denominator) : nil
        let miterLength = miter.map { hypot($0.x, $0.y) } ?? .infinity

        // A turn so slight that every join would draw the same pixels: one
        // shared section, as a flattened curve's thousand small turns want.
        if let miter, (miterLength - 1) * pen.outer * pen.scale * 2 < 0.1 {
            let s = mitred(at: v, miter, pen: pen, into: &builder)
            return (s, s)
        }

        // Which side is outside the turn: right of travel for a left turn.
        let outside: CGFloat = turn > 0 ? -1 : 1

        // The inside meets at one point unless the turn is so sharp, for
        // the stroke's width, that the point lies past the segments' ends
        // (half each, the other half being the next join's).
        let reach = denominator > 1e-9 ? pen.outer * abs(turn) / denominator : .infinity
        let insideMeets = miter != nil && reach <= min(length0, length1) / 2

        if pen.join == .miter, let miter, miterLength <= pen.miterLimit, insideMeets {
            let s = mitred(at: v, miter, pen: pen, into: &builder)
            return (s, s)
        }

        func at(_ base: CGPoint, _ dir: CGPoint, _ r: CGFloat) -> CGPoint {
            CGPoint(x: base.x + dir.x * r, y: base.y + dir.y * r)
        }
        let inside = -outside
        // The inside points: shared, or each section's own.
        let insideA: (outer: Int, core: Int)
        let insideB: (outer: Int, core: Int)
        let centre: Int
        if insideMeets, let miter {
            let m = CGPoint(x: miter.x * inside, y: miter.y * inside)
            let shared = (builder.add(at(v, m, pen.outer), 0), builder.add(at(v, m, pen.core), k))
            insideA = shared
            insideB = shared
            centre = shared.1
        } else {
            let a = CGPoint(x: n0.x * inside, y: n0.y * inside), b = CGPoint(x: n1.x * inside, y: n1.y * inside)
            insideA = (builder.add(at(v, a, pen.outer), 0), builder.add(at(v, a, pen.core), k))
            insideB = (builder.add(at(v, b, pen.outer), 0), builder.add(at(v, b, pen.core), k))
            centre = builder.add(v, k)
        }
        let outA = CGPoint(x: n0.x * outside, y: n0.y * outside), outB = CGPoint(x: n1.x * outside, y: n1.y * outside)
        let outsideA = (outer: builder.add(at(v, outA, pen.outer), 0), core: builder.add(at(v, outA, pen.core), k))
        let outsideB = (outer: builder.add(at(v, outB, pen.outer), 0), core: builder.add(at(v, outB, pen.core), k))

        func assemble(_ ins: (outer: Int, core: Int), _ out: (outer: Int, core: Int)) -> Section {
            outside < 0
                ? Section(plusOuter: ins.outer, plusCore: ins.core, minusCore: out.core, minusOuter: out.outer)
                : Section(plusOuter: out.outer, plusCore: out.core, minusCore: ins.core, minusOuter: ins.outer)
        }
        let a = assemble(insideA, outsideA)
        let b = assemble(insideB, outsideB)

        // The wedge outside the turn, fanned from the inside point, from
        // the arriving section's outside points round to the leaving one's.
        var chain: [(outer: Int, core: Int)] = [outsideA]
        switch pen.join {
        case .round:
            let start = atan2(outA.y, outA.x)
            let sweep = atan2(turn, dot)
            let steps = arcSteps(radius: pen.outer, sweep: abs(sweep), scale: pen.scale)
            if steps > 1 {
                for step in 1 ..< steps {
                    let angle = start + sweep * CGFloat(step) / CGFloat(steps)
                    let dir = CGPoint(x: cos(angle), y: sin(angle))
                    chain.append((builder.add(at(v, dir, pen.outer), 0), builder.add(at(v, dir, pen.core), k)))
                }
            }
        case .miter:
            if let miter, miterLength <= pen.miterLimit {
                let tip = CGPoint(x: miter.x * outside, y: miter.y * outside)
                chain.append((builder.add(at(v, tip, pen.outer), 0), builder.add(at(v, tip, pen.core), k)))
            }
        default:
            break                       // bevel: straight across
        }
        chain.append(outsideB)
        for index in 1 ..< chain.count {
            let p = chain[index - 1], q = chain[index]
            builder.triangle(centre, p.core, q.core)
            builder.quad(p.core, p.outer, q.outer, q.core)
        }
        return (a, b)
    }

    /// One section through a mitred vertex: both sides on the miter.
    private static func mitred(at v: CGPoint, _ miter: CGPoint, pen: Pen, into builder: inout Builder) -> Section {
        let o = pen.outer, c = pen.core, k = pen.coverage
        return Section(
            plusOuter: builder.add(CGPoint(x: v.x + miter.x * o, y: v.y + miter.y * o), 0),
            plusCore: builder.add(CGPoint(x: v.x + miter.x * c, y: v.y + miter.y * c), k),
            minusCore: builder.add(CGPoint(x: v.x - miter.x * c, y: v.y - miter.y * c), k),
            minusOuter: builder.add(CGPoint(x: v.x - miter.x * o, y: v.y - miter.y * o), 0)
        )
    }

    /// An open end, and the section the body runs from (or to). `direction`
    /// is the end segment's direction of travel.
    private static func appendCap(
        at p: CGPoint,
        direction d: CGPoint,
        isStart: Bool,
        cap: CGLineCap,
        pen: Pen,
        trueHalf: CGFloat,
        into builder: inout Builder
    ) -> Section {
        let n = CGPoint(x: -d.y, y: d.x)
        // Out of the stroke, past this end.
        let away = isStart ? CGPoint(x: -d.x, y: -d.y) : d
        switch cap {
        case .round:
            let s = section(at: p, normal: n, pen: pen, coverage: pen.coverage, into: &builder)
            let centre = builder.add(p, pen.coverage)
            // Round the back of the end, from one side to the other.
            let from = isStart ? (outer: s.plusOuter, core: s.plusCore) : (outer: s.minusOuter, core: s.minusCore)
            let to = isStart ? (outer: s.minusOuter, core: s.minusCore) : (outer: s.plusOuter, core: s.plusCore)
            let startAngle = isStart ? atan2(n.y, n.x) : atan2(-n.y, -n.x)
            let steps = max(2, arcSteps(radius: pen.outer, sweep: .pi, scale: pen.scale))
            var previous = from
            for step in 1 ... steps {
                let next: (outer: Int, core: Int)
                if step == steps {
                    next = to
                } else {
                    let angle = startAngle + .pi * CGFloat(step) / CGFloat(steps)
                    let dir = CGPoint(x: cos(angle), y: sin(angle))
                    next = (
                        builder.add(CGPoint(x: p.x + dir.x * pen.outer, y: p.y + dir.y * pen.outer), 0),
                        builder.add(CGPoint(x: p.x + dir.x * pen.core, y: p.y + dir.y * pen.core), pen.coverage)
                    )
                }
                builder.triangle(centre, previous.core, next.core)
                builder.quad(previous.core, previous.outer, next.outer, next.core)
                previous = next
            }
            return s

        case .square, .butt:
            // The end itself feathers across a pixel centred on it; a square
            // cap's end is half the width further out.
            let end = cap == .square ? CGPoint(x: p.x + away.x * trueHalf, y: p.y + away.y * trueHalf) : p
            let f = pen.fringe / 2
            let rim = section(at: CGPoint(x: end.x + away.x * f, y: end.y + away.y * f), normal: n, pen: pen, coverage: 0, into: &builder)
            let body = section(at: CGPoint(x: end.x - away.x * f, y: end.y - away.y * f), normal: n, pen: pen, coverage: pen.coverage, into: &builder)
            bridge(rim, body, into: &builder)
            return body

        @unknown default:
            return section(at: p, normal: n, pen: pen, coverage: pen.coverage, into: &builder)
        }
    }

    /// Steps for an arc so its chords stray under `PathRasteriser.flatness`
    /// pixels, as the rasteriser flattens its arcs.
    private static func arcSteps(radius: CGFloat, sweep: CGFloat, scale: CGFloat) -> Int {
        let pixels = radius * scale
        let flatness = PathRasteriser.flatness
        let perSegment = 2 * acos(max(-1, min(1, 1 - flatness / max(pixels, flatness))))
        return max(1, min(256, Int((abs(sweep) / max(perSegment, 0.01)).rounded(.up))))
    }

    // MARK: - Building

    struct Builder {
        var positions: [SIMD2<Float>] = []
        var coverage: [Float] = []
        var indices: [Int] = []

        mutating func add(_ p: CGPoint, _ c: Float) -> Int {
            positions.append(SIMD2(Float(p.x), Float(p.y)))
            coverage.append(c)
            return positions.count - 1
        }

        mutating func triangle(_ a: Int, _ b: Int, _ c: Int) {
            indices.append(a); indices.append(b); indices.append(c)
        }

        mutating func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            triangle(a, b, c)
            triangle(a, c, d)
        }

        /// Nil past what 16-bit indices reach: a batch's limit.
        func mesh() -> Mesh? {
            guard positions.count <= Int(UInt16.max) + 1 else { return nil }
            var mesh = Mesh()
            mesh.positions = positions
            mesh.coverage = coverage
            mesh.indices = indices.map { UInt16($0) }
            return mesh
        }
    }

    // MARK: - Small geometry

    private static let epsilon: CGFloat = 1e-6

    private static func cross(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat) -> CGFloat {
        ax * by - ay * bx
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }

    private static func point(on centre: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
    }

    private static func rightNormal(from a: CGPoint, to b: CGPoint) -> CGPoint? {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 1e-12 else { return nil }
        return CGPoint(x: dy / length, y: -dx / length)
    }

    private static func dedupe(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        out.reserveCapacity(points.count)
        for p in points where out.isEmpty || distance(out[out.count - 1], p) > epsilon {
            out.append(p)
        }
        return out
    }

    /// Drops vertices the outline runs straight through, which add nothing
    /// to a fill and trip the ear test.
    private static func withoutStraightVertices(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 3 else { return points }
        var out = points
        var i = 0
        while out.count > 3, i < out.count {
            let n = out.count
            let a = out[(i - 1 + n) % n], b = out[i], c = out[(i + 1) % n]
            let abx = b.x - a.x, aby = b.y - a.y, bcx = c.x - b.x, bcy = c.y - b.y
            let scale = hypot(abx, aby) * hypot(bcx, bcy)
            if abs(cross(abx, aby, bcx, bcy)) <= scale * 1e-9, abx * bcx + aby * bcy > 0 {
                out.remove(at: i)
            } else {
                i += 1
            }
        }
        return out
    }

    private static func signedArea(_ polygon: [CGPoint]) -> CGFloat {
        var twice: CGFloat = 0
        for i in 0 ..< polygon.count {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            twice += a.x * b.y - b.x * a.y
        }
        return twice / 2
    }

    private static func boundingBox(_ polygon: [CGPoint]) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for p in polygon {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
