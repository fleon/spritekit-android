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

    public struct Meshes {
        public var fill: ShapeTessellator.Mesh?
        public var stroke: ShapeTessellator.Mesh?
    }

    private struct Key: Hashable {
        var digest: Int
        var kind: Int               // 0 fill, 1 stroke
        var width: Int              // hundredths of a point
        var cap: Int
        var join: Int
        var scale: Int              // twentieths of a pixel per point
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
    public func meshes(for shape: DrawList.Shape) -> Meshes? {
        guard Self.isEnabled, let path = shape.path else { return nil }
        let wantsFill = shape.fillColor.alpha > 0
        let wantsStroke = shape.lineWidth > 0 && shape.strokeColor.alpha > 0
        guard wantsFill || wantsStroke else { return Meshes() }
        if wantsFill, shape.fillTexture != nil { return nil }
        if wantsStroke, shape.strokeTexture != nil { return nil }

        let quantised = Int((pixelsPerPoint * Self.transformScale(shape.transform) * 20).rounded())
        guard quantised > 0 else { return Meshes() }
        let scale = CGFloat(quantised) / 20
        let digest = PathDigest.of(path)

        var result = Meshes()
        var subpaths: [PathRasteriser.Subpath]?
        func flattened() -> [PathRasteriser.Subpath] {
            if let subpaths { return subpaths }
            let made = PathRasteriser.flatten(path, scale: scale)
            subpaths = made
            return made
        }

        if wantsFill {
            let key = Key(digest: digest, kind: 0, width: 0, cap: 0, join: 0, scale: quantised)
            guard let mesh = mesh(for: key, make: { ShapeTessellator.fill(flattened(), scale: scale) }) else { return nil }
            result.fill = mesh
        }
        if wantsStroke {
            let key = Key(
                digest: digest, kind: 1, width: Int((shape.lineWidth * 100).rounded()),
                cap: Int(shape.lineCap.rawValue), join: Int(shape.lineJoin.rawValue), scale: quantised
            )
            guard let mesh = mesh(for: key, make: {
                ShapeTessellator.stroke(flattened(), width: shape.lineWidth, cap: shape.lineCap, join: shape.lineJoin, scale: scale)
            }) else { return nil }
            result.stroke = mesh
        }
        return result
    }

    public func removeAll() {
        cache.removeAll()
        bytes = 0
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
