#if SPRITEKIT_SHIM
import Foundation

#if !canImport(Darwin)
public typealias vector_float2 = SIMD2<Float>
#endif

/// A distortion of a node's picture. SpriteKit has one kind, the grid.
open class SKWarpGeometry {
    public init() {}
}

/// A grid laid over a node's picture in its unit space (0…1, origin bottom
/// left): each vertex samples the picture at its source position and is drawn
/// at its destination position.
///
/// A game may build one for every pose of a swaying plant, beating wing or
/// swimming fish, usually over a regular source grid.
open class SKWarpGeometryGrid: SKWarpGeometry {
    public let numberOfColumns: Int
    public let numberOfRows: Int
    /// Row by row from the bottom, each row left to right.
    public let sourcePositions: [SIMD2<Float>]
    public let destinationPositions: [SIMD2<Float>]

    /// One cell, undistorted.
    public override convenience init() {
        self.init(columns: 1, rows: 1)
    }

    /// `columns` by `rows` cells, undistorted.
    public convenience init(columns: Int, rows: Int) {
        let regular = SKWarpGeometryGrid.regular(columns: columns, rows: rows)
        self.init(columns: columns, rows: rows, sourcePositions: regular, destinationPositions: regular)
    }

    /// SpriteKit raises when a list has the wrong count, and so does this.
    public init(columns: Int, rows: Int, sourcePositions: [SIMD2<Float>], destinationPositions: [SIMD2<Float>]) {
        precondition(columns >= 1 && rows >= 1, "SKWarpGeometryGrid needs at least one cell")
        let count = (columns + 1) * (rows + 1)
        let regular = sourcePositions.isEmpty || destinationPositions.isEmpty
            ? SKWarpGeometryGrid.regular(columns: columns, rows: rows) : []
        let source = sourcePositions.isEmpty ? regular : sourcePositions
        let destination = destinationPositions.isEmpty ? regular : destinationPositions
        precondition(source.count == count && destination.count == count,
                     "SKWarpGeometryGrid: positions must number (columns + 1) * (rows + 1)")
        numberOfColumns = columns
        numberOfRows = rows
        self.sourcePositions = source
        self.destinationPositions = destination
        super.init()
    }

    public var vertexCount: Int { sourcePositions.count }

    public func sourcePosition(at index: Int) -> SIMD2<Float> { sourcePositions[index] }
    public func destPosition(at index: Int) -> SIMD2<Float> { destinationPositions[index] }

    public func replacingBySourcePositions(positions: [SIMD2<Float>]) -> Self {
        Self.make(columns: numberOfColumns, rows: numberOfRows, source: positions, destination: destinationPositions)
    }

    public func replacingByDestinationPositions(positions: [SIMD2<Float>]) -> Self {
        Self.make(columns: numberOfColumns, rows: numberOfRows, source: sourcePositions, destination: positions)
    }

    private static func make(columns: Int, rows: Int, source: [SIMD2<Float>], destination: [SIMD2<Float>]) -> Self {
        // A plain `Self(...)` would need a `required` initializer, which a
        // subclass the game never declares would then have to repeat.
        unsafeDowncast(
            SKWarpGeometryGrid(columns: columns, rows: rows, sourcePositions: source, destinationPositions: destination),
            to: self
        )
    }

    static func regular(columns: Int, rows: Int) -> [SIMD2<Float>] {
        var positions: [SIMD2<Float>] = []
        positions.reserveCapacity((columns + 1) * (rows + 1))
        for row in 0...rows {
            for column in 0...columns {
                positions.append(SIMD2(Float(column) / Float(columns), Float(row) / Float(rows)))
            }
        }
        return positions
    }

    /// Whether the two grids have the same shape, so one can blend into the
    /// other. SpriteKit's warp actions snap to their first pose otherwise.
    func matches(_ other: SKWarpGeometryGrid) -> Bool {
        numberOfColumns == other.numberOfColumns && numberOfRows == other.numberOfRows
    }

    /// Each position `t` of the way from this grid's to `other`'s.
    func blended(to other: SKWarpGeometryGrid, _ t: Float) -> SKWarpGeometryGrid {
        func mix(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>]) -> [SIMD2<Float>] {
            var out: [SIMD2<Float>] = []
            out.reserveCapacity(a.count)
            for index in 0..<min(a.count, b.count) { out.append(a[index] + (b[index] - a[index]) * t) }
            return out
        }
        return SKWarpGeometryGrid(
            columns: numberOfColumns, rows: numberOfRows,
            sourcePositions: mix(sourcePositions, other.sourcePositions),
            destinationPositions: mix(destinationPositions, other.destinationPositions)
        )
    }
}

/// A node whose picture can be warped: sprites and effect nodes.
public protocol SKWarpable: AnyObject {
    var warpGeometry: SKWarpGeometry? { get set }
    /// How finely the grid is subdivided to smooth it; SpriteKit's default 2.
    var subdivisionLevels: Int { get set }
}

extension SKSpriteNode: SKWarpable {}
extension SKEffectNode: SKWarpable {}

// MARK: Actions

/// Measured against SpriteKit through `SKRenderer` (see the tests): each
/// vertex, source and destination alike, moves in a straight line; a keyframe
/// list blends linearly from one pose to the next, and from the node's own
/// warp to the first pose by the first time; a node with no warp, or one of a
/// different shape, takes the first pose (or the target) at once instead.
/// Both raise in SpriteKit on lists of different counts or shapes, and trap
/// here.
public extension SKAction {
    static func warp(to warp: SKWarpGeometry, duration: TimeInterval) -> SKAction? {
        SKAction(kind: .warpTo(warp), duration: duration)
    }

    static func animate(withWarps warps: [SKWarpGeometry], times: [NSNumber]) -> SKAction? {
        animate(withWarps: warps, times: times, restore: false)
    }

    static func animate(withWarps warps: [SKWarpGeometry], times: [NSNumber], restore: Bool) -> SKAction? {
        precondition(!warps.isEmpty && warps.count == times.count,
                     "SKAction: 'warps' and 'times' arrays must have non-zero and equal counts")
        let grids = warps.compactMap { $0 as? SKWarpGeometryGrid }
        precondition(grids.count == warps.count && grids.allSatisfy { $0.matches(grids[0]) },
                     "SKAction: 'warps' must all have the same number of rows and columns")
        let seconds = times.map(\.doubleValue)
        return SKAction(kind: .warps(warps, seconds, restore), duration: seconds.last ?? 0)
    }

    internal static func warp(_ node: SKNode, from start: SKWarpGeometry?, to target: SKWarpGeometry, progress: CGFloat) {
        guard let node = node as? SKWarpable else { return }
        guard let start = start as? SKWarpGeometryGrid, let end = target as? SKWarpGeometryGrid,
              start.matches(end), progress < 1 else {
            node.warpGeometry = target
            return
        }
        node.warpGeometry = start.blended(to: end, Float(progress))
    }

    internal static func warp(_ node: SKNode, from start: SKWarpGeometry?, through warps: [SKWarpGeometry],
                              times: [TimeInterval], at time: TimeInterval, restore: Bool) {
        guard let node = node as? SKWarpable, let first = warps.first, let lastTime = times.last else { return }
        if time >= lastTime, restore {
            node.warpGeometry = start
            return
        }
        // Before the first pose: from the node's own warp, if it can blend.
        if time < times[0] {
            if let start = start as? SKWarpGeometryGrid, let pose = first as? SKWarpGeometryGrid,
               start.matches(pose), times[0] > 0 {
                node.warpGeometry = start.blended(to: pose, Float(time / times[0]))
            } else {
                node.warpGeometry = first
            }
            return
        }
        guard let next = times.firstIndex(where: { $0 > time }) else {
            node.warpGeometry = warps[warps.count - 1]
            return
        }
        let span = times[next] - times[next - 1]
        guard span > 0, let a = warps[next - 1] as? SKWarpGeometryGrid, let b = warps[next] as? SKWarpGeometryGrid else {
            node.warpGeometry = warps[next - 1]
            return
        }
        node.warpGeometry = a.blended(to: b, Float((time - times[next - 1]) / span))
    }
}

/// The triangles a warp grid draws as, in the picture's unit space.
///
/// Matches SpriteKit's own, measured on macOS by rendering a picture that
/// encodes its texture coordinates through `SKRenderer` and fitting the
/// result (see the tests, which pin it to those measurements):
///
///   - every cell is cut into 2^levels × 2^levels smaller cells, their
///     corners placed by **bilinear** interpolation of the cell's four
///     vertices, for the source and the destination alike (not a smoothing
///     spline: a cell's corners stay put);
///   - levels past 3 draw exactly as 3 does;
///   - each small cell is two triangles split along its bottom-left to
///     top-right diagonal;
///   - a grid whose destination is the plain regular grid is not
///     subdivided at all, whatever its source does.
public struct WarpMesh: Equatable {
    /// Where each vertex is drawn, in the node's unit space.
    public var positions: [SIMD2<Float>]
    /// Where each vertex samples the picture, in unit texture space.
    public var texCoords: [SIMD2<Float>]
    /// Three per triangle, counter-clockwise.
    public var indices: [UInt16]

    /// SpriteKit draws level 4 and up exactly as level 3.
    public static let deepestLevel = 3

    public init(grid: SKWarpGeometryGrid, subdivisionLevels: Int) {
        let columns = grid.numberOfColumns, rows = grid.numberOfRows
        let level = WarpMesh.isUntouched(grid) ? 0 : min(max(subdivisionLevels, 0), WarpMesh.deepestLevel)
        let split = 1 << level
        let across = columns * split + 1, down = rows * split + 1

        positions = []
        texCoords = []
        positions.reserveCapacity(across * down)
        texCoords.reserveCapacity(across * down)
        func vertex(_ points: [SIMD2<Float>], _ column: Int, _ row: Int) -> SIMD2<Float> {
            points[row * (columns + 1) + column]
        }
        func bilinear(_ points: [SIMD2<Float>], _ x: Int, _ y: Int) -> SIMD2<Float> {
            let column = min(x / split, columns - 1), row = min(y / split, rows - 1)
            let u = Float(x - column * split) / Float(split)
            let v = Float(y - row * split) / Float(split)
            let bottom = vertex(points, column, row) * (1 - u) + vertex(points, column + 1, row) * u
            let top = vertex(points, column, row + 1) * (1 - u) + vertex(points, column + 1, row + 1) * u
            return bottom * (1 - v) + top * v
        }
        for y in 0..<down {
            for x in 0..<across {
                positions.append(bilinear(grid.destinationPositions, x, y))
                texCoords.append(bilinear(grid.sourcePositions, x, y))
            }
        }

        indices = []
        indices.reserveCapacity((across - 1) * (down - 1) * 6)
        for y in 0..<(down - 1) {
            for x in 0..<(across - 1) {
                let a = UInt16(y * across + x), b = a + 1
                let c = UInt16((y + 1) * across + x), d = c + 1
                // Bottom left to top right: (a, b, d) and (a, d, c).
                indices.append(contentsOf: [a, b, d, a, d, c])
            }
        }
    }

    public var vertexCount: Int { positions.count }

    /// Whether the grid's destination is the plain regular grid, which
    /// SpriteKit doesn't subdivide. Built as `regular` builds it, so it
    /// compares exactly, without making that grid.
    public static func isUntouched(_ grid: SKWarpGeometryGrid) -> Bool {
        let columns = grid.numberOfColumns, rows = grid.numberOfRows
        var index = 0
        for row in 0...rows {
            for column in 0...columns {
                if grid.destinationPositions[index] != SIMD2(Float(column) / Float(columns), Float(row) / Float(rows)) { return false }
                index += 1
            }
        }
        return true
    }

    /// The bounds of where the grid draws, in unit space: every vertex of
    /// its mesh is a bilinear mix of a cell's corners, so none lies outside
    /// the destination's own.
    public static func bounds(of grid: SKWarpGeometryGrid) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        var low = grid.destinationPositions[0], high = low
        for point in grid.destinationPositions {
            low = pointwiseMin(low, point)
            high = pointwiseMax(high, point)
        }
        return (low, high)
    }
}

#endif
