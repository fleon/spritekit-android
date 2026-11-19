import Foundation
import SpriteKitShim

/// Shapes' triangles (`ShapeTessellator`), kept by what they draw, for the
/// batcher to append to the frame's colour batches.
///
/// Keyed as the masks are (`PathDigest`, the stroke's measures and the
/// density they're made for), so a path rebuilt each layout with the same
/// segments in it finds its triangles, and one that changes is made again
/// on the frame thread: tessellating is cheap enough not to need a worker.
/// What can't be tessellated is remembered too, so that shape goes to its
/// mask each frame without being tried again.
public final class ShapeMeshes {

    /// Off, every shape is a pass of its own, drawn through its mask.
    nonisolated(unsafe) public static var isEnabled = true

    /// The display's pixels per scene point; a shape's own scale is
    /// multiplied in.
    public var pixelsPerPoint: CGFloat = 1

    /// The screen's pixels per scene point, whatever share of them the
    /// scene is drawn at: what SpriteKit's stroke edges are measured in
    /// (`ShapeTessellator.Edges.spriteKit`).
    public var screenPixelsPerPoint: CGFloat = 1

    public struct Meshes {
        public var fill: ShapeTessellator.Mesh?
        public var stroke: ShapeTessellator.Mesh?
        /// Which meshes these are: equal for the same keys, so a node's
        /// finished vertices (`Placed`) know when to be made again.
        public var signature: Int = 0
    }

    struct Key: Hashable {
        var digest: Int
        var kind: Int               // 0 fill, 1 stroke, 2 a stroke a texture runs along
        var width: Int              // hundredths of a point
        var cap: Int
        var join: Int
        var scale: Int              // twentieths of a pixel per point
        var edge: Int = 0           // twentieths of a screen pixel per point
        var glow: Int = 0           // hundredths of a point
        var aliased = false
    }

    private struct Cached {
        /// Nil: tried, and left to the mask.
        var mesh: ShapeTessellator.Mesh?
        var used: UInt64
    }

    private var cache: [Key: Cached] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    private let budget: Int

    /// How many meshes have been made, and what making them has cost, in
    /// seconds (the frame report's).
    public private(set) var tessellated = 0
    public private(set) var tessellateSeconds = 0.0

    public init(budget: Int = 8 * 1024 * 1024) {
        self.budget = budget
    }

    /// The shape's fill and stroke as triangles in its own space, or nil
    /// when it should draw through its mask: a textured fill or stroke, or
    /// a path the tessellator leaves alone.
    /// What a shape's meshes are keyed by, worked out without looking them
    /// up: what the batcher compares a node's kept vertices against before
    /// it fetches anything. `.mask` when the shape keeps its mask, `.nothing`
    /// when there's nothing to draw.
    enum Plan {
        case mask
        case nothing
        case meshes(Keys)
    }

    struct Keys {
        var path: CGPath
        var fill: Key?
        var stroke: Key?
        var textured: Bool
        var scale: CGFloat
        var signature: Int
    }

    func plan(for shape: DrawList.Shape) -> Plan {
        guard Self.isEnabled, let path = shape.path else { return .mask }
        let wantsFill = shape.fillColor.alpha > 0
        let wantsStroke = shape.lineWidth > 0 && shape.strokeColor.alpha > 0
        guard wantsFill || wantsStroke else { return .nothing }
        if wantsFill, shape.fillTexture != nil { return .mask }
        // A stroke's texture runs along it (`StrokeTextureTests`), which the
        // mask can't carry: the stroke is triangles with places along it. A
        // texture cut from another (`SKTexture(rect:in:)`) does too, over the
        // whole image it was cut from, as SpriteKit draws one.
        let textured = wantsStroke && shape.strokeTexture != nil
        if textured, !Self.runsAlong(shape.strokeTexture) { return .mask }

        let quantised = Int((pixelsPerPoint * Self.transformScale(shape.transform) * 20).rounded())
        guard quantised > 0 else { return .nothing }
        let digest = self.digest(of: path, owner: shape.owner)
        var keys = Keys(path: path, textured: textured, scale: CGFloat(quantised) / 20, signature: 0)
        if wantsFill {
            let key = Key(digest: digest, kind: 0, width: 0, cap: 0, join: 0, scale: quantised)
            keys.fill = key
            keys.signature = key.hashValue
        }
        if wantsStroke {
            let key = Key(
                digest: digest, kind: textured ? 2 : 1, width: Int((shape.lineWidth * 100).rounded()),
                cap: Int(shape.lineCap.rawValue), join: Int(shape.lineJoin.rawValue), scale: quantised,
                edge: Int((screenPixelsPerPoint * 20).rounded()),
                glow: Int((max(0, shape.glowWidth) * 100).rounded()), aliased: !shape.isAntialiased
            )
            keys.stroke = key
            keys.signature = keys.signature &* 31 &+ key.hashValue
        }
        return .meshes(keys)
    }

    public func meshes(for shape: DrawList.Shape) -> Meshes? {
        switch plan(for: shape) {
        case .mask: return nil
        case .nothing: return Meshes()
        case let .meshes(keys): return meshes(for: shape, keys)
        }
    }

    /// The meshes `keys` name, made where they're missing.
    func meshes(for shape: DrawList.Shape, _ keys: Keys) -> Meshes? {
        let path = keys.path, scale = keys.scale
        var result = Meshes()
        result.signature = keys.signature
        var subpaths: [PathRasteriser.Subpath]?
        func flattened() -> [PathRasteriser.Subpath] {
            if let subpaths { return subpaths }
            let made = PathRasteriser.flatten(path, scale: scale)
            subpaths = made
            return made
        }
        if let key = keys.fill {
            guard let mesh = mesh(for: key, make: {
                // Flattened four times as fine as the stroke: with no feather a
                // fill's rim is its chords, each cutting inside the curve,
                // and SpriteKit's circle covers within a pixel or so of the
                // exact area (`SpriteKitShapeEdgesTests`). A fill is one
                // vertex a point, so this still costs less than its feather did.
                ShapeTessellator.fill(PathRasteriser.flatten(path, scale: scale * 4), scale: scale, edges: .spriteKit)
            }) else { return nil }
            result.fill = mesh
        }
        if let key = keys.stroke {
            let textured = keys.textured
            guard let mesh = mesh(for: key, make: {
                ShapeTessellator.stroke(
                    flattened(), width: shape.lineWidth, cap: shape.lineCap, join: shape.lineJoin,
                    // SpriteKit mitres whatever the node's `miterLimit` (measured).
                    miterLimit: .greatestFiniteMagnitude,
                    scale: scale, alongTexture: textured, edges: .spriteKit, edgePixels: CGFloat(key.edge) / 20,
                    glow: CGFloat(key.glow) / 100, antialiased: !key.aliased
                )
            }) else { return nil }
            result.stroke = mesh
        }
        return result
    }

    #if !canImport(Darwin)
    /// Each node's path as last digested: the object (held, so its identity
    /// can't pass to another), how many times it had changed, and its digest.
    private var pathDigests: [ObjectIdentifier: (path: CGPath, version: Int, digest: Int)] = [:]
    #endif

    /// The path's digest (`PathDigest`), read again only when the node's
    /// path is another object or has changed since: hashing every segment of
    /// every shape every frame was most of what a still shape cost. On a Mac
    /// `CGPath` is CoreGraphics' own, with no count of its changes, so it is
    /// always read.
    private func digest(of path: CGPath, owner: ObjectIdentifier?) -> Int {
        #if !canImport(Darwin)
        if let owner {
            if let known = pathDigests[owner], known.path === path, known.version == path.version { return known.digest }
            let digest = PathDigest.of(path)
            if pathDigests.count > 8192 { pathDigests.removeAll() }
            pathDigests[owner] = (path, path.version, digest)
            return digest
        }
        #endif
        return PathDigest.of(path)
    }

    public func removeAll() {
        batchFloats = 0
        batchIndices = 0
        #if !canImport(Darwin)
        pathDigests.removeAll()
        #endif
        cache.removeAll()
        bytes = 0
        placed.removeAll()
        placedBytes = 0
    }

    // MARK: Finished vertices

    /// A node's fill and stroke as the batch takes them, moved and
    /// coloured, kept while what went into them holds: a still shape is
    /// then two copies a frame instead of a sum per vertex. Indices are
    /// kept as last offset too, as a still scene puts each shape at the
    /// same place in its batch every frame.
    ///
    /// Kept only once a node has drawn the same way twice running: one
    /// that moves every frame would otherwise pay to keep vertices it never
    /// uses again, so it is written straight into the batch instead.
    ///
    /// A class, so reading one is a reference: as a struct, every look at
    /// an entry copied it, and retained and released its three arrays.
    final class Placed {
        var signature: Int
        var transform: CGAffineTransform
        var colours: SIMD8<Float>
        var vertices: [Float] = []
        var indices: [UInt16] = []
        var offsetIndices: [UInt16] = []
        var offsetFirst: Int = -1
        var isKept = false
        var used: UInt64 = 0
        var byteCount: Int { 64 + vertices.count * 4 + (indices.count + offsetIndices.count) * 2 }

        init(signature: Int, transform: CGAffineTransform, colours: SIMD8<Float>, used: UInt64) {
            self.signature = signature
            self.transform = transform
            self.colours = colours
            self.used = used
        }
    }

    private var placed: [ObjectIdentifier: Placed] = [:]
    private var placedBytes = 0
    private let placedBudget = 16 * 1024 * 1024

    /// `shape`'s finished vertices and its indices offset by `first`, or
    /// nil when the caller should write them itself: a shape no node owns,
    /// or one that has changed since the frame before.
    func placed(
        for shape: DrawList.Shape,
        _ meshes: Meshes,
        colours: SIMD8<Float>,
        first: Int,
        make: () -> (vertices: [Float], indices: [UInt16])
    ) -> (vertices: [Float], indices: [UInt16])? {
        guard let owner = shape.owner else { return nil }
        clock += 1
        guard let entry = placed[owner],
              matches(entry, meshes.signature, shape.transform, colours) else {
            // New, or changed: noted, and written by the caller this time.
            // A node that changes every frame notes into the entry it has.
            if let old = placed[owner] {
                placedBytes -= old.byteCount
                old.signature = meshes.signature
                old.transform = shape.transform
                old.colours = colours
                old.used = clock
                old.vertices = []
                old.indices = []
                old.offsetIndices = []
                old.offsetFirst = -1
                old.isKept = false
                placedBytes += old.byteCount
            } else {
                let note = Placed(signature: meshes.signature, transform: shape.transform, colours: colours, used: clock)
                placed[owner] = note
                placedBytes += note.byteCount
                if placedBytes > placedBudget { evictPlaced() }
            }
            return nil
        }
        if !entry.isKept {
            placedBytes -= entry.byteCount
            let made = make()
            entry.vertices = made.vertices
            entry.indices = made.indices
            entry.offsetIndices = []
            entry.isKept = true
            entry.offsetFirst = -1
            placedBytes += entry.byteCount
        }
        let kept = keep(entry, first: first)
        if placedBytes > placedBudget { evictPlaced() }
        return kept
    }

    /// A node's kept vertices for this frame, when nothing that went into
    /// them has changed: found from its plan alone, before any mesh is
    /// looked up or copied. The batcher's path for a still shape.
    func kept(for shape: DrawList.Shape, _ keys: Keys, colours: SIMD8<Float>) -> Placed? {
        guard let owner = shape.owner, let entry = placed[owner], entry.isKept,
              matches(entry, keys.signature, shape.transform, colours) else { return nil }
        return entry
    }

    /// `entry`'s vertices, its indices offset by `first`.
    func keep(_ entry: Placed, first: Int) -> (vertices: [Float], indices: [UInt16]) {
        clock += 1
        entry.used = clock
        if entry.offsetFirst != first {
            let offset = UInt16(first)
            let indices = entry.indices
            placedBytes -= entry.offsetIndices.count * 2
            entry.offsetIndices = SpriteBatcher.offset(indices, by: offset)
            entry.offsetFirst = first
            placedBytes += entry.offsetIndices.count * 2
        }
        return (entry.vertices, entry.offsetIndices)
    }

    private func matches(_ entry: Placed, _ signature: Int, _ transform: CGAffineTransform, _ colours: SIMD8<Float>) -> Bool {
        entry.signature == signature && entry.transform == transform && entry.colours == colours
    }

    // MARK: Batch sizes

    /// The most floats and indices a colour batch has taken since the
    /// scene began: what a batch reserves the first time a shape needs it
    /// to grow, so it is allocated once a frame rather than regrown (and
    /// copied) every time it doubles.
    private(set) var batchFloats = 0
    private(set) var batchIndices = 0

    func noteBatch(floats: Int, indices: Int) {
        batchFloats = max(batchFloats, floats)
        batchIndices = max(batchIndices, indices)
    }

    /// The fill's rgb and alpha, the stroke's, each alpha times the node's.
    /// Whether a stroke's texture can run along it as triangles: one with a
    /// height to take its aspect from.
    static func runsAlong(_ texture: SKTexture?) -> Bool {
        guard let texture else { return false }
        let size = texture.size()
        return size.width > 0 && size.height > 0
    }

    static func colours(_ shape: DrawList.Shape) -> SIMD8<Float> {
        let f = shape.fillColor, s = shape.strokeColor, a = shape.alpha
        return SIMD8(
            Float(f.red), Float(f.green), Float(f.blue), Float(f.alpha * a),
            Float(s.red), Float(s.green), Float(s.blue), Float(s.alpha * a)
        )
    }

    private func evictPlaced() {
        for (owner, entry) in placed.sorted(by: { $0.value.used < $1.value.used }) {
            placed.removeValue(forKey: owner)
            placedBytes -= entry.byteCount
            if placedBytes <= placedBudget / 2 { break }
        }
    }

    private func mesh(for key: Key, make: () -> ShapeTessellator.Mesh?) -> ShapeTessellator.Mesh? {
        clock += 1
        if var hit = cache[key] {
            hit.used = clock
            cache[key] = hit
            return hit.mesh
        }
        let started = MediaTime.source()
        let mesh = make()
        tessellateSeconds += MediaTime.source() - started
        tessellated += 1
        cache[key] = Cached(mesh: mesh, used: clock)
        bytes += (mesh?.byteCount ?? 0) + 64
        if bytes > budget { evict() }
        return mesh
    }

    /// Least recently drawn first, down to half the budget. The batches
    /// copy the vertices out, so nothing drawn this frame needs keeping.
    private func evict() {
        for (key, entry) in cache.sorted(by: { $0.value.used < $1.value.used }) {
            cache.removeValue(forKey: key)
            bytes -= (entry.mesh?.byteCount ?? 0) + 64
            if bytes <= budget / 2 { break }
        }
    }

    /// How much a transform scales: the square root of the area it
    /// multiplies by, as the masks measure it.
    static func transformScale(_ t: CGAffineTransform) -> CGFloat {
        let determinant = abs(t.a * t.d - t.b * t.c)
        return determinant > 0 ? sqrt(determinant) : 0
    }
}

/// A hash of what a path draws, so a rebuilt path with the same segments
/// finds what was made for the last one.
public enum PathDigest {
    public static func of(_ path: CGPath) -> Int {
        var hasher = Hasher()
        for element in path.pathElements {
            switch element {
            case let .move(p): hasher.combine(0); combine(p, into: &hasher)
            case let .line(p): hasher.combine(1); combine(p, into: &hasher)
            case let .quadCurve(p, c):
                hasher.combine(2); combine(p, into: &hasher); combine(c, into: &hasher)
            case let .curve(p, c1, c2):
                hasher.combine(3)
                combine(p, into: &hasher); combine(c1, into: &hasher); combine(c2, into: &hasher)
            case let .arc(centre, radius, start, end, clockwise):
                hasher.combine(4)
                combine(centre, into: &hasher)
                hasher.combine(quantise(radius))
                hasher.combine(quantise(start))
                hasher.combine(quantise(end))
                hasher.combine(clockwise)
            case .close: hasher.combine(5)
            }
        }
        return hasher.finalize()
    }

    private static func combine(_ point: CGPoint, into hasher: inout Hasher) {
        hasher.combine(quantise(point.x))
        hasher.combine(quantise(point.y))
    }

    /// Coordinates are compared at a thousandth of a point: far finer than
    /// anything that could show, and it keeps the key an integer, so the
    /// float noise of a rebuilt path does not miss its own entry.
    private static func quantise(_ value: CGFloat) -> Int {
        value.isFinite ? Int((value * 1000).rounded()) : 0
    }
}
