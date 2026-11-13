import Foundation
import SpriteKitShim

/// One level, playable: a board built from the catalog's own `Level`, taps
/// routed into `GameEngine`, and each move played through `Timeline`.
///
/// Deliberately bare. There is no HUD, no tip, no pause menu, no backdrop
/// and no win card — those are screens of their own and later stages. A tap
/// on a Switchling is the whole of the input, and a cleared level says so in
/// the log and opens the next one, through the game's own loading screen
/// (`TransitionManager`) as every scene change in the game goes.
public final class PlayScene: SKScene, LoadableScene {
    private var entry: LevelEntry
    private var board: PlayBoardNode?
    /// The boards behind the one on screen, so a move can be taken back.
    private var history: [GameState] = []
    /// The moves behind `history`, which a share film replays.
    private var moves: [GameSession.Move] = []
    private var isWon = false
    /// The layout the loading screen built this for, while it has no view.
    var plannedLayout: SceneLayout?
    private var isLoaded = false
    /// The win card's Share, until the win card itself is ported.
    private var shareButton: SKNode?
    private var shareLabel: SKLabelNode?
    private var isSharing = false

    /// How a run is driven, from the launch arguments (`GLESBackend`).
    public struct Options {
        /// Presses Share as soon as the level is cleared.
        public var autoShare = false
        /// What Share films.
        public var share = FilmShare.Choices()
        /// Called with the file once the share sheet is open.
        public var shared: ((URL?) -> Void)?

        public init() {}
    }

    public nonisolated(unsafe) static var options = Options()

    /// How long a cleared level is left on screen before the next one.
    private static let winPause: TimeInterval = 1.6
    /// The stand-in Share button's width, the win card's pill being the UI ring's.
    private static let shareWidth: CGFloat = 180

    /// Plays each level's stored solution by itself, a move at a time, so a
    /// run on a device clears level after level through the loading screen
    /// (`debug.switchlings.autosolve`, as the game's `-AutoSolve`).
    public nonisolated(unsafe) static var autoSolves = false
    /// The wait before each move it plays: the first also covers the fade in.
    private static let autoSolvePause: TimeInterval = 0.6

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

    /// Builds the board, once: off the main thread when the loading screen
    /// makes the scene, else as it shows.
    func load() {
        guard !isLoaded else { return }
        isLoaded = true
        buildBoard()
    }

    public override func didMove(to view: SKView) {
        load()
        PlayLog.write("showing \(entry.id)")
        autoSolve()
    }

    /// The next move of the stored solution, after a pause.
    private func autoSolve() {
        guard Self.autoSolves, !isWon, history.count < entry.level.solution.count else { return }
        let step = entry.level.solution[history.count]
        run(.sequence([
            .wait(forDuration: Self.autoSolvePause),
            .run { [weak self] in self?.move(step.id) },
        ]))
    }

    public override func didChangeSize(_ oldSize: CGSize) {
        guard board != nil else { return }
        layoutBoard()
    }

    // MARK: - The board

    private func buildBoard() {
        board?.removeFromParent()
        shareButton?.removeFromParent()
        shareButton = nil
        history = []
        moves = []
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
        let point = touch.location(in: self)
        if isWon {
            guard !isSharing else { return }
            if let shareButton, shareButton.contains(point) {
                share()
            } else {
                advance()
            }
            return
        }
        tap(at: point)
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
        if isMove {
            history.append(previous)
            moves.append(GameSession.Move(id: id, direction: direction))
        }
        PlayLog.write(
            isMove
                ? "move \(history.count): \(id) \(direction.rawValue)"
                : "\(id) \(direction.rawValue) only bonks — not a move"
        )

        board.play(previous: previous, next: next) { [weak self] in
            self?.finish(next, wasMove: isMove)
            if isMove { self?.autoSolve() }
        }
    }

    private func finish(_ state: GameState, wasMove: Bool) {
        guard wasMove, state.isComplete, !isWon else { return }
        isWon = true
        PlayLog.write("\(entry.id) solved in \(history.count) moves — everyone home")
        run(.sequence([
            .wait(forDuration: Self.winPause),
            .run { [weak self] in self?.showShare() },
        ]))
    }

    // MARK: - Share

    /// The win card's Share, standing in for the card: a primary button
    /// under the board. A tap anywhere else goes on to the next level.
    private func showShare() {
        let size = sz(Self.shareWidth, DesignSystem.buttonMediumHeight)
        let button = SKNode()
        let face = SurfaceTexture.chunkyResting(size: size, style: .primary(cornerRadius: size.height / 2))
        button.addChild(face)
        let title = label(.font(.black, DesignSystem.buttonMediumFontSize), .text(LocalizedString.share.localized), .color(Theme.primaryText), .z(DesignSystem.zStep))
        title.centerCapitals(on: .zero)
        button.addChild(title)
        let bottom = board.map { convert(CGPoint(x: 0, y: $0.calculateAccumulatedFrame().minY), from: $0).y } ?? size.height * 2
        button.position = pt(self.size.width / 2, max(size.height * 2, bottom - size.height * 1.5))
        button.zPosition = DesignSystem.hudZ
        addChild(button)
        shareButton = button
        shareLabel = title
        if Self.options.autoShare { share() }
    }

    private func share() {
        guard let view, let shareButton, !isSharing else { return }
        isSharing = true
        let started = MediaTime.source()
        PlayLog.write("filming \(entry.id): \(Self.options.share)")
        FilmShare.share(entry: entry, moves: moves, choices: Self.options.share, view: view, from: shareButton, progress: { [weak self] fraction in
            self?.shareLabel?.text = "\(Int((fraction * 100).rounded()))%"
        }) { [weak self] url in
            guard let self else { return }
            self.isSharing = false
            self.shareLabel?.text = LocalizedString.share.localized
            let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
            PlayLog.write(url.map { "film ready in \(String(format: "%.1f", MediaTime.source() - started)) s: \($0.path), \(size / 1024) KB" } ?? "the film could not be made")
            Self.options.shared?(url)
        }
    }

    /// Opens the next level in the world, then the next world's first; after
    /// the last there is nowhere to go, so it plays again. It goes as the
    /// game's Next does: through the loading screen, fading out and in.
    private func advance() {
        let levels = LevelCatalog.levels
        guard let index = levels.firstIndex(where: { $0.id == entry.id }) else { return }
        let next = levels.indices.contains(index + 1) ? levels[index + 1] : levels[0]
        guard let view else {
            entry = next
            buildBoard()
            return
        }
        TransitionManager.present(.play(next), in: view)
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

extension Destination {
    /// A level, played by `PlayScene`. The game's own is `.level`, made in
    /// `GameScene.swift` with the real `GameScene`, which is not here yet.
    static func play(_ entry: LevelEntry) -> Destination {
        Destination(index: .gameplay, theme: LevelCatalog.world(at: entry.worldIndex)?.theme ?? .garden) {
            PlayScene(entry: entry, size: $0)
        }
    }
}

/// Where the gameplay ring says what happened. The shell points it at
/// logcat; the host tests at nothing, or at a list they then read.
public enum PlayLog {
    nonisolated(unsafe) public static var sink: ((String) -> Void)?

    static func write(_ message: String) {
        sink?(message)
    }
}
