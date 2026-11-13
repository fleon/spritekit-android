import Foundation
import SpriteKitShim

/// A level's board: its tiles at their heights, the kerb round its outline,
/// every Switchling's home, every Switchling and its arrow — built from the
/// level's own data and moved by the game's own `Timeline`.
///
/// This is **not** the game's `BoardNode`, which is 2,701 lines across 38
/// component files and reaches into world lighting, the live backdrops, the
/// rig runtime and every mechanic's own node. What it is, is the same board
/// assembled from the same pieces as far as those pieces port: the tiles,
/// the kerb, the homes and the arrows are the game's own component nodes,
/// unmodified, and the geometry (`BoardMetrics`), the outline
/// (`BoardOutline`) and the motion (`Timeline`, `BoardKeyframes`) are the
/// game's own code. What is written here is the assembly, the depth ordering
/// copied from `BoardNode`'s own rules, and the hit test.
///
/// Not drawn yet, and nothing here pretends otherwise: every mechanic's art
/// (springs, whirlpools, gates, buttons, blocks, arrow banks, currents, ice,
/// screens, ledges, thresholds, keys, locks, light pillars, turntables,
/// platform switches and the Mainframe's three). A level that has them plays
/// by the same rules — the engine is whole — but its board shows bare floor
/// where they should stand. Sunny Garden's first levels have none, which is
/// why they are what this slice plays.
final class PlayBoardNode: SKNode {
    let metrics: BoardMetrics
    let level: Level
    private let theme: WorldTheme
    private let outline: BoardOutline
    /// Walls outside the board's outline, which keep their authored height
    /// out of what is drawn (`BoardNode.height`).
    private let authoredWalls: Set<GridPoint>

    private let gridLayer = SKNode()
    private var tiles: [GridPoint: TileNode] = [:]
    private var actors: [String: PlaySwitchlingNode] = [:]
    private var arrows: [String: ArrowTileNode] = [:]
    private var goals: [String: GoalNode] = [:]
    /// Cast order, for the z that breaks ties between Switchlings on one row.
    private var castOrder: [String: Int] = [:]

    private(set) var state: GameState

    private enum ActionKey {
        static let track = "board.track"
    }

    private enum Layer {
        /// `BoardNode.Layer.arrows`: arrows draw above the whole board.
        static let arrows = DesignSystem.boardLayerStep * 4
    }

    init(level: Level, theme: WorldTheme, state: GameState) {
        self.level = level
        self.theme = theme
        self.state = state
        metrics = BoardMetrics(level: level)
        outline = BoardOutline(level: level, metrics: metrics)
        var walls = Set<GridPoint>()
        for (y, row) in level.map.enumerated() {
            for (x, tile) in row.enumerated() where tile == "#" {
                let cell = GridPoint(x, y)
                if !outline.contains(cell) { walls.insert(cell) }
            }
        }
        authoredWalls = walls
        super.init()

        addChild(gridLayer)
        build()
        show(state)
    }

    /// The board's size in its own coordinates, kerb included — what a scene
    /// scales to fit.
    var boardSize: CGSize { frame.size }

    // MARK: - Building

    private func build() {
        let cell = metrics.cell
        let looks = level.tiles?.map(Array.init)
        let currentCells = Set((level.conveyors ?? []).map { GridPoint($0.x, $0.y) })
        let crumbleCells = Set((level.crumbling ?? []).map { GridPoint($0.x, $0.y) })
        let iceCells = Set(level.ice ?? [])
        let liftWays = Dictionary(grouping: level.lifts ?? [], by: \.target)
            .mapValues { LiftControlNode.Ways(raises: $0.map(\.raises)) }

        for point in outline.cells {
            // Rows and columns as the level is authored, inside its outer
            // ring: what picks the cell's brick, so a level looks the same
            // every time (`BoardNode.build`).
            let authored = GridPoint(point.x - 1, point.y - 1)
            let picked = Self.pickedLook(looks, at: point)
                .flatMap { $0 >= 1 && $0 <= TileNode.brickCount(theme) ? $0 : nil }
            let variant = picked ?? TileNode.brickVariant(theme, row: authored.y, column: authored.x)
            let isIce = iceCells.contains(point)
            let tile = TileNode(
                brick: isIce
                    ? TileNode.iceAsset(row: authored.y, column: authored.x)
                    : theme.brickAsset(variant),
                theme: theme,
                cell: cell,
                surface: currentCells.contains(point)
                    ? .water
                    : crumbleCells.contains(point) ? .cracked(seed: Self.crackSeed(authored)) : .solid,
                lift: liftWays[point],
                showsPips: level.hasHeights
            )
            tile.position = metrics.point(point)
            gridLayer.addChild(tile)
            tiles[point] = tile
        }

        let frame = BoardFrameNode(outline: outline, metrics: metrics, theme: theme)
        gridLayer.addChild(frame)

        for (order, switchling) in state.switchlings.enumerated() {
            castOrder[switchling.id] = order

            let goal = GoalNode(
                theme: theme, castID: switchling.id, cell: cell,
                driftDirection: switchling.goal.direction
            )
            gridLayer.addChild(goal)
            goals[switchling.id] = goal

            let actor = PlaySwitchlingNode(castID: switchling.id, theme: theme, cell: cell)
            gridLayer.addChild(actor)
            actors[switchling.id] = actor

            let arrow = ArrowTileNode(
                cell: cell, direction: switchling.direction,
                bobPhase: order, ink: theme.skin.arrowInk
            )
            gridLayer.addChild(arrow)
            arrows[switchling.id] = arrow
        }
    }

    /// The look a level's `tiles` picks for a cell, a digit from 1, if it
    /// picks one (`BoardNode.pickedLook`).
    private static func pickedLook(_ looks: [[Character]]?, at point: GridPoint) -> Int? {
        guard let looks, looks.indices.contains(point.y), looks[point.y].indices.contains(point.x) else { return nil }
        return looks[point.y][point.x].wholeNumberValue
    }

    /// Where a crumbling floor's cracks start, by the cell as authored, so a
    /// tile cracks the same way every time.
    private static func crackSeed(_ cell: GridPoint) -> Float {
        Float((cell.x &* 73 &+ cell.y &* 151) % 997) / 997
    }

    // MARK: - Showing a state

    /// Snaps the board to `state`: no motion, everything where that board
    /// puts it. What `show` does and `play` does must agree, or a move would
    /// end somewhere other than where it was animated to.
    func show(_ state: GameState) {
        self.state = state

        for (point, tile) in tiles {
            let front = GridPoint(point.x, point.y + 1)
            tile.setFrontHeight(tiles[front] != nil ? height(state, front) : nil)
            tile.setHeight(height(state, point), animated: false)
            tile.zPosition = z(point, .tile, in: state)
            tile.setCollapsed(state.crumbling.first { $0.x == point.x && $0.y == point.y }?.crumbled ?? false)
        }

        for switchling in state.switchlings {
            let position = metrics.point(switchling.position, height: height(state, switchling.position))
            if let actor = actors[switchling.id] {
                actor.removeAction(forKey: ActionKey.track)
                actor.position = position
                actor.zPosition = actorZ(switchling.id, row: switchling.y)
                actor.setHome(switchling.isHome)
            }
            if let arrow = arrows[switchling.id] {
                arrow.removeAction(forKey: ActionKey.track)
                arrow.position = position
                arrow.zPosition = Self.arrowZ(switchling.y)
                arrow.setDirection(switchling.direction)
            }
            if let goal = goals[switchling.id] {
                goal.removeAction(forKey: ActionKey.track)
                goal.position = metrics.point(
                    switchling.goal.position,
                    height: height(state, switchling.goal.position)
                )
                goal.zPosition = z(switchling.goal.position, .goal, in: state)
                goal.setFilled(switchling.isHome)
            }
        }
    }

    // MARK: - Playing a move

    /// Plays one engine action: the `Timeline` carries each Switchling, its
    /// arrow and any drifting home along its own track, and the board is
    /// snapped to `next` when the last of them lands.
    ///
    /// `speed` plays a move faster (undo runs at `rewindSpeedup`).
    func play(
        previous: GameState,
        next: GameState,
        speed: Double = 1,
        completion: @escaping () -> Void
    ) {
        let timeline = Timeline(previous: previous, next: next)
        let duration = timeline.total / 1000 / speed

        guard duration > 0 else {
            show(next)
            completion()
            return
        }

        // Heights only change when a platform switch moves one, and the
        // platform settles at `mechanismAt`; before that the board is as it
        // was. Levels without platform switches never take the second branch.
        let heightAt: (Int, Int, Double) -> CGFloat = { [weak self] x, y, t in
            guard let self else { return 0 }
            let board = t < timeline.mechanismAt ? previous : next
            return CGFloat(self.height(board, GridPoint(x, y)))
        }

        for track in timeline.tracks {
            guard let actor = actors[track.id] else { continue }
            runTrack(actor, track.points, total: timeline.total, duration: duration, heightAt: heightAt) { [weak self] grid in
                self?.actorZ(track.id, row: BoardMetrics.row(passing: grid.y)) ?? 0
            }
        }
        for track in timeline.goalTracks {
            guard let goal = goals[track.id] else { continue }
            runTrack(goal, track.points, total: timeline.total, duration: duration, heightAt: heightAt, curve: .easeInOut) { [weak self] grid in
                self?.z(passing: grid, .goal, in: next) ?? 0
            }
        }

        // An arrow tile has a path of its own, not its holder's: in a trade
        // the two fly between the Switchlings. `finalArrows` is keyed by who
        // ends up holding each one, so a tile starts where it came from —
        // which is why its start direction is set before it moves.
        for (holder, tile) in timeline.finalArrows {
            guard let arrow = arrows[holder] else { continue }
            arrow.setDirection(tile.startDirection)
            runTrack(arrow, tile.path, total: timeline.total, duration: duration, heightAt: heightAt) { grid in
                Self.arrowZ(BoardMetrics.row(passing: grid.y))
            }
            // A signpost or a turntable turns an arrow where it floats.
            for turn in tile.turns {
                arrow.run(.sequence([
                    .wait(forDuration: turn.t / 1000 / speed),
                    .run { [weak arrow] in arrow?.turn(to: turn.direction, animated: true) },
                ]))
            }
        }

        run(.sequence([
            .wait(forDuration: duration),
            .run { [weak self] in
                self?.show(next)
                completion()
            },
        ]), withKey: ActionKey.track)
    }

    /// Whether a move is still playing.
    var isPlaying: Bool { action(forKey: ActionKey.track) != nil }

    /// Stops a move mid-flight and snaps to `state` (restart, and undo
    /// during a move).
    func settle(on state: GameState) {
        removeAction(forKey: ActionKey.track)
        show(state)
    }

    private func runTrack(
        _ node: SKNode,
        _ points: [TrackPoint],
        total: Double,
        duration: TimeInterval,
        heightAt: @escaping (Int, Int, Double) -> CGFloat,
        curve: TimingCurve = .linear,
        depth: @escaping (CGPoint) -> CGFloat
    ) {
        let frames = BoardKeyframes.frames(points, total: total, metrics: metrics, height: heightAt)
        if let first = frames.first { BoardKeyframes.pose(node, first, depth: depth) }
        node.run(
            BoardKeyframes.action(frames, duration: duration, curve: curve, depth: depth),
            withKey: ActionKey.track
        )
    }

    // MARK: - Depth, copied from BoardNode's own rules

    /// A cell's height as drawn: a wall outside the outline keeps none, so a
    /// hole never lifts what draws beside it (`BoardNode.height`).
    private func height(_ state: GameState, _ cell: GridPoint) -> Int {
        authoredWalls.contains(cell) ? 0 : state.heightAt(cell.x, cell.y)
    }

    /// A tile no higher than the one behind it, and what lies flat on it,
    /// draws with the row behind (`BoardNode.isFlat`).
    private func isFlat(_ cell: GridPoint, in state: GameState) -> Bool {
        let behind = GridPoint(cell.x, cell.y - 1)
        guard tiles[behind] != nil else { return false }
        return height(state, cell) <= height(state, behind)
    }

    private func z(_ cell: GridPoint, _ depth: BoardDepth, offset: CGFloat = 0, in state: GameState) -> CGFloat {
        depth.liesFlat && isFlat(cell, in: state)
            ? BoardMetrics.z(row: cell.y - 1, depth, offset: offset + DesignSystem.boardFlatZ)
            : BoardMetrics.z(row: cell.y, depth, offset: offset)
    }

    /// A flat piece between cells draws over every cell it overlaps.
    private func z(passing point: CGPoint, _ depth: BoardDepth, offset: CGFloat = 0, in state: GameState) -> CGFloat {
        BoardMetrics.cells(passing: point).map { z($0, depth, offset: offset, in: state) }.max() ?? 0
    }

    private func actorZ(_ id: String, row: Int) -> CGFloat {
        BoardMetrics.z(
            row: row, .standing,
            offset: DesignSystem.boardPieceZ + CGFloat(castOrder[id] ?? 0) * DesignSystem.boardTieZ
        )
    }

    private static func arrowZ(_ row: Int) -> CGFloat {
        BoardMetrics.z(above: Layer.arrows, row: row, offset: DesignSystem.boardPieceZ)
    }

    // MARK: - Taps

    /// The Switchling a tap at `point` (in the board's coordinates) hits:
    /// its floating arrow tile first, then its own cell, nearer rows before
    /// farther ones — `BoardNode.actorID(at:)`, rule for rule.
    func actorID(at point: CGPoint) -> String? {
        let byRow = state.switchlings.sorted { $0.y > $1.y }
        for switchling in byRow {
            let position = metrics.point(switchling.position, height: height(state, switchling.position))
            if arrows[switchling.id]?.hitRect(at: position).contains(point) == true { return switchling.id }
        }
        for switchling in byRow {
            let position = metrics.point(switchling.position, height: height(state, switchling.position))
            let hit = rect(
                position.x - metrics.cell / 2,
                position.y - metrics.cell / 2,
                metrics.cell,
                metrics.cell * (0.5 + DesignSystem.actorHitAbove)
            )
            if hit.contains(point) { return switchling.id }
        }
        return nil
    }
}
