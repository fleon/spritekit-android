import XCTest
@testable import SpriteKitShim

/// SKWarpGeometryGrid, WarpMesh and the warp actions, pinned to SpriteKit.
///
/// The mesh fixtures were measured on macOS: a 256-point sprite whose texture
/// encodes its own texel in red and green, warped by SpriteKit and rendered
/// through `SKRenderer` into a 512 × 512 target, the sprite centred. Each
/// sample is a pixel (scene points, y up) and the texel SpriteKit drew there.
/// The action fixtures are `node.warpGeometry` read back from a scene ticked
/// by `SKRenderer.update(atTime:)`.
final class WarpGeometryTests: XCTestCase {

    // MARK: The grid

    func testRegularGridOrdersRowsFromTheBottom() {
        let grid = SKWarpGeometryGrid(columns: 2, rows: 1)
        XCTAssertEqual(grid.numberOfColumns, 2)
        XCTAssertEqual(grid.numberOfRows, 1)
        XCTAssertEqual(grid.vertexCount, 6)
        // As SpriteKit prints it.
        XCTAssertEqual((0..<6).map { grid.sourcePosition(at: $0) }, [
            SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1),
        ])
        XCTAssertEqual(grid.sourcePositions, grid.destinationPositions)
        let plain = SKWarpGeometryGrid()
        XCTAssertEqual(plain.numberOfColumns, 1)
        XCTAssertEqual(plain.numberOfRows, 1)
    }

    func testReplacingKeepsTheOtherSide() {
        let grid = SKWarpGeometryGrid(columns: 2, rows: 1)
        let moved = Array(repeating: SIMD2<Float>(0.5, 0.5), count: 6)
        let destination = grid.replacingByDestinationPositions(positions: moved)
        XCTAssertEqual((0..<6).map { destination.destPosition(at: $0) }, moved)
        XCTAssertEqual(destination.sourcePositions, grid.sourcePositions)
        let source = grid.replacingBySourcePositions(positions: moved)
        XCTAssertEqual(source.sourcePositions, moved)
        XCTAssertEqual(source.destinationPositions, grid.destinationPositions)
        XCTAssertEqual(grid.destinationPositions, SKWarpGeometryGrid(columns: 2, rows: 1).destinationPositions)
    }

    func testSpritesAndEffectNodesAreWarpable() {
        let sprite = SKSpriteNode(color: .red, size: CGSize(width: 4, height: 4))
        XCTAssertNil(sprite.warpGeometry)
        XCTAssertEqual(sprite.subdivisionLevels, 2)
        XCTAssertEqual(SKEffectNode().subdivisionLevels, 2)
        let warpable: SKWarpable = sprite
        warpable.warpGeometry = SKWarpGeometryGrid()
        XCTAssertNotNil(sprite.warpGeometry)
    }

    // MARK: The mesh

    func testLevelZeroIsTheGridCutAlongItsDiagonals() {
        let grid = Self.grid(1, 1) { $0 == SIMD2(1, 1) ? SIMD2(1.4, 1.3) : $0 }
        let mesh = WarpMesh(grid: grid, subdivisionLevels: 0)
        XCTAssertEqual(mesh.positions, grid.destinationPositions)
        XCTAssertEqual(mesh.texCoords, grid.sourcePositions)
        // Bottom left to top right.
        XCTAssertEqual(mesh.indices, [0, 1, 3, 0, 3, 2])
    }

    func testSubdivisionIsBilinearAndKeepsTheCorners() {
        let grid = Self.grid(2, 1) { SIMD2($0.x + 0.2 * $0.y * $0.x, $0.y) }
        let mesh = WarpMesh(grid: grid, subdivisionLevels: 2)
        XCTAssertEqual(mesh.vertexCount, (2 * 4 + 1) * (1 * 4 + 1))
        XCTAssertEqual(mesh.indices.count, 2 * 4 * 4 * 6)
        let across = 9
        for row in 0...1 {
            for column in 0...2 {
                XCTAssertEqual(mesh.positions[row * 4 * across + column * 4], grid.destinationPositions[row * 3 + column])
            }
        }
        // A quarter and three quarters into the first cell.
        let p = mesh.positions[1 * across + 3]
        let x: Float = 0.375, y: Float = 0.25
        XCTAssertEqual(p.x, x + 0.2 * y * x, accuracy: 1e-6)
        XCTAssertEqual(p.y, y, accuracy: 1e-6)
    }

    func testLevelsPastThreeDrawAsThree() {
        let grid = Self.grid(1, 1) { $0 == SIMD2(1, 1) ? SIMD2(1.4, 1.3) : $0 }
        XCTAssertEqual(WarpMesh(grid: grid, subdivisionLevels: 4), WarpMesh(grid: grid, subdivisionLevels: 3))
        XCTAssertEqual(WarpMesh(grid: grid, subdivisionLevels: 3).vertexCount, 81)
    }

    func testAnUntouchedDestinationIsNotSubdivided() {
        let grid = Self.grid(2, 2, move: { $0 }) { $0 == SIMD2(0.5, 0.5) ? SIMD2(0.3, 0.4) : $0 }
        XCTAssertEqual(WarpMesh(grid: grid, subdivisionLevels: 3).vertexCount, 9)
    }

    /// Every sample SpriteKit drew lands within a texel of the mesh's.
    func testMatchesSpriteKitsRendering() {
        let cases: [(String, SKWarpGeometryGrid, Int, [Sample])] = [
            ("corner pulled, level 2", Self.cornerPulled, 2, Self.cornerPulledLevel2),
            ("centre pushed, level 2", Self.centrePushed, 2, Self.centrePushedLevel2),
            ("both sides moved, level 2", Self.bothMoved, 2, Self.bothMovedLevel2),
            ("one cell, both sides, level 1", Self.oneCellBoth, 1, Self.oneCellBothLevel1),
        ]
        for (name, grid, level, samples) in cases {
            let mesh = WarpMesh(grid: grid, subdivisionLevels: level)
            var worst = 0
            for sample in samples {
                guard let texel = Self.texel(in: mesh, atPixel: sample) else {
                    XCTFail("\(name): (\(sample.x), \(sample.y)) is off the mesh")
                    continue
                }
                worst = max(worst, abs(texel.u - sample.u), abs(texel.v - sample.v))
            }
            XCTAssertLessThanOrEqual(worst, 1, name)
        }
        // And the samples tell the levels apart: drawn unsubdivided, the
        // pulled corner misses by several texels.
        let coarse = WarpMesh(grid: Self.cornerPulled, subdivisionLevels: 0)
        let misses = Self.cornerPulledLevel2.compactMap { sample in
            Self.texel(in: coarse, atPixel: sample).map { max(abs($0.u - sample.u), abs($0.v - sample.v)) }
        }
        XCTAssertGreaterThan(misses.max() ?? 0, 4)
    }

    // MARK: Actions

    func testWarpToMovesEveryVertexInAStraightLine() {
        let node = Self.node(warp: Self.pose(1, source: 0))
        node.run(SKAction.warp(to: Self.pose(2, source: 0.5), duration: 1)!)
        XCTAssertEqual(Self.trace(node, [0, 0.1, 0.25, 0.5, 0.75, 1.0, 1.25]),
                       [1, 1.1, 1.25, 1.5, 1.75, 2, 2])
        XCTAssertEqual(Self.sourceX(node), 0.5, accuracy: 1e-5)
    }

    func testWarpToFromNothingTakesTheTargetAtOnce() {
        let node = Self.node(warp: nil)
        node.run(SKAction.warp(to: Self.pose(2), duration: 1)!)
        XCTAssertEqual(Self.trace(node, [0, 0.5]), [2, 2])
        let other = Self.node(warp: SKWarpGeometryGrid(columns: 2, rows: 1))
        other.run(SKAction.warp(to: Self.pose(2), duration: 1)!)
        XCTAssertEqual(Self.trace(other, [0, 0.5]), [2, 2])
    }

    func testAnimateBlendsFromTheNodesWarpToTheFirstPose() {
        let node = Self.node(warp: Self.pose(1))
        let action = SKAction.animate(withWarps: [Self.pose(2), Self.pose(3)], times: [0.5, 1.5])!
        XCTAssertEqual(action.duration, 1.5)
        node.run(action)
        XCTAssertEqual(Self.trace(node, [0, 0.1, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0]),
                       [1, 1.2, 1.5, 2, 2.25, 2.5, 2.75, 3, 3])
    }

    func testAnimateFromNothingHoldsTheFirstPose() {
        let node = Self.node(warp: nil)
        node.run(SKAction.animate(withWarps: [Self.pose(2), Self.pose(3)], times: [0.5, 1.5])!)
        XCTAssertEqual(Self.trace(node, [0, 0.25, 0.5, 0.75, 1.5]), [2, 2, 2, 2.25, 3])
    }

    func testAnimateRestoresWhenAsked() {
        let node = Self.node(warp: Self.pose(1))
        node.run(SKAction.animate(withWarps: [Self.pose(2), Self.pose(3)], times: [0.5, 1.5], restore: true)!)
        XCTAssertEqual(Self.trace(node, [0.25, 1.25, 1.5, 2.0]), [1.5, 2.75, 1, 1])
    }

    /// A looped keyframe list plays round and round. The shim's
    /// `repeatForever` drops whatever part of a frame runs past a round's end
    /// (SpriteKit carries it on), so these ticks land on the rounds' ends.
    func testALoopPlaysRoundAndRound() {
        let node = Self.node(warp: Self.pose(1))
        let loop = SKAction.animate(withWarps: [Self.pose(2), Self.pose(3), Self.pose(2)], times: [0, 0.5, 1])!
        node.run(.repeatForever(loop))
        let times = (0...16).map { TimeInterval($0) * 0.125 }
        let round: [Float] = [2, 2.25, 2.5, 2.75, 3, 2.75, 2.5, 2.25, 2]
        XCTAssertEqual(Self.trace(node, times), round + round.dropFirst())
    }

    func testDrawListCarriesTheGrid() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let sprite = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        let grid = Self.pose(1.5)
        sprite.warpGeometry = grid
        sprite.subdivisionLevels = 1
        scene.addChild(sprite)
        guard case let .sprite(command)? = DrawList(scene: scene).commands.first else {
            return XCTFail("no sprite command")
        }
        XCTAssertTrue(command.warp === grid)
        XCTAssertEqual(command.subdivisionLevels, 1)
    }

    // MARK: Helpers

    struct Sample { var x: Int; var y: Int; var u: Int; var v: Int }

    static func grid(_ columns: Int, _ rows: Int, move: (SIMD2<Float>) -> SIMD2<Float>,
                     source: ((SIMD2<Float>) -> SIMD2<Float>)? = nil) -> SKWarpGeometryGrid {
        let regular = SKWarpGeometryGrid(columns: columns, rows: rows).sourcePositions
        return SKWarpGeometryGrid(columns: columns, rows: rows,
                                  sourcePositions: source.map { regular.map($0) } ?? regular,
                                  destinationPositions: regular.map(move))
    }

    /// One cell whose top right is drawn at `x` and whose bottom left
    /// samples at `source`.
    static func pose(_ x: Float, source: Float = 0) -> SKWarpGeometryGrid {
        var s = SKWarpGeometryGrid().sourcePositions, d = s
        s[0].x = source
        d[3].x = x
        return SKWarpGeometryGrid(columns: 1, rows: 1, sourcePositions: s, destinationPositions: d)
    }

    static func node(warp: SKWarpGeometry?) -> SKSpriteNode {
        let node = SKSpriteNode(color: .red, size: CGSize(width: 4, height: 4))
        node.warpGeometry = warp
        return node
    }

    /// The top right's x after each of `times` seconds from the start.
    static func trace(_ node: SKSpriteNode, _ times: [TimeInterval]) -> [Float] {
        var now: TimeInterval = 0
        return times.map { time in
            node.tickActions(time - now)
            now = time
            let grid = node.warpGeometry as? SKWarpGeometryGrid
            return ((grid?.destPosition(at: 3).x ?? .nan) * 1000).rounded() / 1000
        }
    }

    static func sourceX(_ node: SKSpriteNode) -> Float {
        (node.warpGeometry as? SKWarpGeometryGrid)?.sourcePosition(at: 0).x ?? .nan
    }

    /// The texel the mesh draws at a pixel's centre, as the fixture's
    /// sprite was placed: 256 points, centred on a 512-point target.
    static func texel(in mesh: WarpMesh, atPixel sample: Sample) -> (u: Int, v: Int)? {
        let p = SIMD2<Float>((Float(sample.x) + 0.5 - 128) / 256, (Float(sample.y) + 0.5 - 128) / 256)
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let i = (0..<3).map { Int(mesh.indices[t + $0]) }
            let a = mesh.positions[i[0]], b = mesh.positions[i[1]], c = mesh.positions[i[2]]
            let area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
            guard abs(area) > 1e-9 else { continue }
            let wb = ((p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y)) / area
            let wc = ((b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)) / area
            let wa = 1 - wb - wc
            guard wa >= -1e-5, wb >= -1e-5, wc >= -1e-5 else { continue }
            let uv = mesh.texCoords[i[0]] * wa + mesh.texCoords[i[1]] * wb + mesh.texCoords[i[2]] * wc
            func index(_ value: Float) -> Int { min(255, max(0, Int((value * 256).rounded(.down)))) }
            return (index(uv.x), index(uv.y))
        }
        return nil
    }

    static let cornerPulled = grid(1, 1) { $0 == SIMD2(1, 1) ? SIMD2(1.4, 1.3) : $0 }
    static let centrePushed = grid(2, 2) { $0 == SIMD2(0.5, 0.5) ? SIMD2(0.75, 0.65) : $0 }
    static let bothMoved = grid(2, 2, move: {
        $0 == SIMD2(0.5, 0.5) ? SIMD2(0.7, 0.4) : ($0 == SIMD2(1, 1) ? SIMD2(1.2, 1.25) : $0)
    }) { $0 == SIMD2(0.5, 0.5) ? SIMD2(0.35, 0.6) : $0 }
    static let oneCellBoth = grid(1, 1, move: { $0 == SIMD2(1, 0) ? SIMD2(1.3, -0.2) : $0 }) {
        $0 == SIMD2(0, 1) ? SIMD2(0.3, 0.8) : $0
    }

    private static func samples(_ values: [(Int, Int, Int, Int)]) -> [Sample] {
        values.map { Sample(x: $0.0, y: $0.1, u: $0.2, v: $0.3) }
    }

    static let cornerPulledLevel2 = samples([
            (467, 450, 243, 250), (282, 409, 110, 248), (319, 409, 138, 241), (356, 409, 166, 234), (393, 409, 195, 228), (430, 409, 223, 222),
            (467, 409, 253, 216), (134, 368, 4, 239), (171, 368, 31, 231), (208, 368, 59, 224), (245, 368, 86, 217), (282, 368, 115, 211),
            (319, 368, 144, 205), (356, 368, 174, 199), (393, 368, 203, 194), (430, 368, 233, 188), (134, 327, 4, 198), (171, 327, 33, 191),
            (208, 327, 62, 185), (245, 327, 91, 179), (282, 327, 121, 174), (319, 327, 150, 169), (356, 327, 181, 164), (393, 327, 211, 159),
            (430, 327, 243, 154), (134, 286, 5, 157), (171, 286, 34, 151), (208, 286, 65, 147), (245, 286, 95, 142), (282, 286, 127, 137),
            (319, 286, 158, 133), (356, 286, 190, 129), (393, 286, 221, 125), (134, 245, 5, 116), (171, 245, 36, 112), (208, 245, 68, 108),
            (245, 245, 99, 104), (282, 245, 133, 101), (319, 245, 164, 97), (356, 245, 198, 95), (393, 245, 231, 91), (134, 204, 5, 75),
            (171, 204, 38, 72), (208, 204, 72, 70), (245, 204, 106, 67), (282, 204, 140, 65), (319, 204, 174, 63), (356, 204, 208, 61),
            (393, 204, 242, 59), (134, 163, 5, 35), (171, 163, 40, 33), (208, 163, 76, 32), (245, 163, 111, 30), (282, 163, 146, 29),
            (319, 163, 182, 28), (356, 163, 217, 27),
    ])
    static let centrePushedLevel2 = samples([
            (134, 368, 6, 240), (171, 368, 41, 239), (208, 368, 75, 237), (245, 368, 109, 235), (282, 368, 144, 234), (319, 368, 186, 237),
            (356, 368, 226, 239), (134, 327, 5, 199), (171, 327, 35, 194), (208, 327, 63, 189), (245, 327, 92, 184), (282, 327, 118, 178),
            (319, 327, 166, 184), (356, 327, 219, 194), (134, 286, 4, 157), (171, 286, 30, 150), (208, 286, 56, 144), (245, 286, 80, 136),
            (282, 286, 103, 127), (319, 286, 132, 122), (356, 286, 206, 145), (134, 245, 4, 116), (171, 245, 30, 109), (208, 245, 57, 103),
            (245, 245, 84, 97), (282, 245, 113, 92), (319, 245, 153, 94), (356, 245, 209, 106), (134, 204, 4, 75), (171, 204, 33, 70),
            (208, 204, 63, 66), (245, 204, 94, 62), (282, 204, 125, 59), (319, 204, 170, 63), (356, 204, 218, 70), (134, 163, 5, 34),
            (171, 163, 38, 32), (208, 163, 71, 30), (245, 163, 105, 28), (282, 163, 142, 28), (319, 163, 182, 30), (356, 163, 224, 33),
    ])
    static let bothMovedLevel2 = samples([
            (356, 409, 198, 249), (393, 409, 227, 239), (134, 368, 6, 240), (171, 368, 40, 241), (208, 368, 75, 243), (245, 368, 110, 244),
            (282, 368, 136, 241), (319, 368, 164, 231), (356, 368, 196, 221), (393, 368, 231, 210), (134, 327, 5, 200), (171, 327, 33, 205),
            (208, 327, 61, 210), (245, 327, 90, 214), (282, 327, 119, 216), (319, 327, 153, 205), (356, 327, 194, 193), (393, 327, 239, 180),
            (134, 286, 3, 160), (171, 286, 26, 168), (208, 286, 49, 175), (245, 286, 74, 183), (282, 286, 99, 189), (319, 286, 140, 180),
            (356, 286, 193, 165), (134, 245, 3, 119), (171, 245, 22, 129), (208, 245, 40, 140), (245, 245, 60, 149), (282, 245, 82, 158),
            (319, 245, 121, 155), (356, 245, 197, 135), (134, 204, 3, 78), (171, 204, 27, 85), (208, 204, 50, 93), (245, 204, 72, 102),
            (282, 204, 92, 111), (319, 204, 148, 101), (356, 204, 212, 85), (134, 163, 4, 36), (171, 163, 34, 40), (208, 163, 63, 44),
            (245, 163, 92, 49), (282, 163, 128, 50), (319, 163, 175, 44), (356, 163, 222, 39),
    ])
    static let oneCellBothLevel1 = samples([
            (134, 368, 76, 193), (171, 368, 102, 201), (208, 368, 128, 208), (245, 368, 154, 215), (282, 368, 181, 222), (319, 368, 207, 229),
            (356, 368, 233, 237), (134, 327, 64, 160), (171, 327, 90, 168), (208, 327, 116, 175), (245, 327, 144, 181), (282, 327, 171, 187),
            (319, 327, 197, 195), (356, 327, 224, 202), (393, 327, 252, 208), (134, 286, 52, 128), (171, 286, 78, 134), (208, 286, 106, 140),
            (245, 286, 135, 146), (282, 286, 162, 153), (319, 286, 188, 160), (356, 286, 216, 166), (393, 286, 244, 172), (134, 245, 40, 95),
            (171, 245, 68, 100), (208, 245, 96, 106), (245, 245, 125, 112), (282, 245, 153, 118), (319, 245, 181, 124), (356, 245, 209, 130),
            (393, 245, 237, 136), (134, 204, 27, 62), (171, 204, 56, 68), (208, 204, 84, 73), (245, 204, 113, 79), (282, 204, 143, 83),
            (319, 204, 171, 89), (356, 204, 199, 95), (393, 204, 227, 101), (134, 163, 15, 29), (171, 163, 43, 35), (208, 163, 73, 40),
            (245, 163, 103, 44), (282, 163, 133, 49), (319, 163, 161, 55), (356, 163, 189, 61), (393, 163, 219, 66), (430, 163, 249, 71),
            (208, 122, 63, 5), (245, 122, 93, 10), (282, 122, 123, 15), (319, 122, 152, 20), (356, 122, 181, 25), (393, 122, 211, 30),
            (430, 122, 240, 35),
    ])
}
