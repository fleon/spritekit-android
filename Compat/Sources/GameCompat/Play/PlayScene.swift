import Foundation
import SpriteKitShim

/// One level, playable: a board built from the catalog's own `Level`, taps
/// routed into `GameEngine`, and each move played through `Timeline`.
///
/// Deliberately bare. There is no HUD, no tip, no pause menu, no backdrop
/// and no win card — those are screens of their own and later stages. A tap
/// on a Switchling is the whole of the input, and a cleared level says so in
/// the log and opens the next one.
public final class PlayScene: SKScene {
    private var entry: LevelEntry
    private var board: PlayBoardNode?
    /// The boards behind the one on screen, so a move can be taken back.
    private var history: [GameState] = []
    private var isWon = false

    /// How long a cleared level is left on screen before the next one.
    private static let winPause: TimeInterval = 1.6

    init(entry: LevelEntry, size: CGSize) {
        self.entry = entry
        super.init(size: size)
        scaleMode = .aspectFill
    }

    /// The level the catalog knows by `id`, or the first one it has.
    public convenience init?(levelID: String?, size: CGSize) {
        guard let entry = levelID.flatMap(LevelCatalog.level(withID:)) ?? LevelCatalog.levels.first else { return nil }
        self.init(entry: entry, size: size)
    }

    public override func didMove(to view: SKView) {
        buildBoard()
    }

    public override func didChangeSize(_ oldSize: CGSize) {
        guard board != nil else { return }
        layoutBoard()
    }

    // MARK: - The board

    private func buildBoard() {
        board?.removeFromParent()
        history = []
        isWon = false

        guard let state = try? GameEngine.createState(entry.level) else {
            PlayLog.write("level \(entry.id) will not start: its board is invalid")
            return
        }
        let world = LevelCatalog.allWorlds.first { $0.index == entry.worldIndex }
        let theme = world?.theme ?? .garden
        UISkin.current = theme.skin
        backgroundColor = theme.palette.backgroundBottom

        let board = PlayBoardNode(level: entry.level, theme: theme, state: state)
        addChild(board)
        self.board = board
        layoutBoard()

        PlayLog.write(
            "playing \(entry.id) — \(world?.name ?? "?") \(entry.number), "
                + "\(state.width)x\(state.height), \(state.switchlings.count) Switchlings, "
                + "\(entry.level.solution.count) moves to solve"
        )
    }

    /// Fits the board in the view, cells no bigger than the game's own 50
    /// points. The real rule is `SceneLayout`'s, which shares the screen with
    /// a HUD, a tip and the safe area; with none of those here, this is the
    /// same cap over a plain centred fit.
    private func layoutBoard() {
        guard let board else { return }
        board.setScale(1)
        let bounds = board.calculateAccumulatedFrame()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let room = sz(size.width * DesignSystem.boardRoomShare, size.height * DesignSystem.boardRoomShare)
        let fit = min(room.width / bounds.width, room.height / bounds.height)
        let scale = min(fit, DesignSystem.boardCellScale)
        board.setScale(scale)
        board.position = pt(
            size.width / 2 - bounds.midX * scale,
            size.height / 2 - bounds.midY * scale
        )
    }

    // MARK: - Taps

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        tap(at: touch.location(in: self))
    }

    /// A tap at `scenePoint`: the Switchling under it takes a step its arrow's
    /// way, as a tap does in the game.
    private func tap(at scenePoint: CGPoint) {
        guard let board, !board.isPlaying, !isWon else { return }
        let point = convert(scenePoint, to: board)
        guard let id = board.actorID(at: point) else {
            PlayLog.write(String(
                format: "tap at scene %.0f,%.0f (board %.0f,%.0f) hit nobody",
                Double(scenePoint.x), Double(scenePoint.y), Double(point.x), Double(point.y)
            ))
            return
        }
        move(id)
    }

    /// Runs one action through the engine and plays what comes back. A tap
    /// that only bonks is not a move — the engine hands back the same board
    /// and tick — so it animates but is not recorded, exactly as in the game.
    private func move(_ id: String) {
        guard let board else { return }
        let previous = board.state
        guard let direction = previous.switchling(id)?.direction,
              let next = GameEngine.move(previous, id: id, direction: direction) else { return }

        let isMove = next.tick != previous.tick
        if isMove { history.append(previous) }
        PlayLog.write(
            isMove
                ? "move \(history.count): \(id) \(direction.rawValue)"
                : "\(id) \(direction.rawValue) only bonks — not a move"
        )

        board.play(previous: previous, next: next) { [weak self] in
            self?.finish(next, wasMove: isMove)
        }
    }

    private func finish(_ state: GameState, wasMove: Bool) {
        guard wasMove, state.isComplete, !isWon else { return }
        isWon = true
        PlayLog.write("\(entry.id) solved in \(history.count) moves — everyone home")
        run(.sequence([
            .wait(forDuration: Self.winPause),
            .run { [weak self] in self?.advance() },
        ]))
    }

    /// Opens the next level in the world, then the next world's first; after
    /// the last there is nowhere to go, so it plays again.
    private func advance() {
        let levels = LevelCatalog.levels
        guard let index = levels.firstIndex(where: { $0.id == entry.id }) else { return }
        entry = levels.indices.contains(index + 1) ? levels[index + 1] : levels[0]
        buildBoard()
    }

    // MARK: - Undo and restart, for a driver rather than a HUD

    /// Takes the last move back. No button reaches this yet — the HUD is a
    /// screen of its own — but the scripted runs and the host tests do.
    @discardableResult
    public func undo() -> Bool {
        guard let board, !isWon, let previous = history.popLast() else { return false }
        board.settle(on: previous)
        return true
    }

    public func restart() {
        buildBoard()
    }

    /// How many moves have been played, for a driver checking a solution ran.
    public var moveCount: Int { history.count }
    public var isComplete: Bool { board?.state.isComplete ?? false }
    public var levelID: String { entry.id }
}

/// Where the gameplay ring says what happened. The shell points it at
/// logcat; the host tests at nothing, or at a list they then read.
public enum PlayLog {
    nonisolated(unsafe) public static var sink: ((String) -> Void)?

    static func write(_ message: String) {
        sink?(message)
    }
}
