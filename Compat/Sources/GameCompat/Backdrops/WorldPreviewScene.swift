import Foundation
import SpriteKitShim

/// A level of a world over that world's live backdrop, lit as on iOS: the
/// game's own `BackdropNode` (its scenery, gradient, ambient motes, scrim and
/// edge blur), `SceneLightNode` and `WorldLightNode` moving the lights, and
/// the shared light where a world has one — set up in the order `GameScene`
/// sets them up (its `load()` and `layout`).
///
/// This file is the port's. It stands in for `GameScene` until the scenes
/// ring brings it: there is no HUD, so the round buttons the backdrop blurs
/// and shades behind are where `GameScene` puts them (back and settings in
/// the top corners, the four controls along the bottom), as rects alone.
/// A tap on a Switchling plays its move; anywhere else, the scenery reacts
/// (`BackdropNode.touch`), as in the game.
public final class WorldPreviewScene: SKScene {
    private let entry: LevelEntry
    private let theme: WorldTheme
    private let backdrop: BackdropNode
    private var board: PlayBoardNode?
    private var sharedLight: SharedLightNode?
    private lazy var lights = SceneLightNode { [weak self] in
        guard let board = self?.board else { return 0 }
        return board.metrics.cell * board.xScale
    }
    private lazy var worldLights = WorldLightNode(
        boards: { [] },
        backdrops: { [weak self] in self.map { [$0.backdrop] } ?? [] }
    )
    private var laidOut: CGRect?

    /// What to leave out, to see what each part costs on a device
    /// (`-WorldHide live,blur,board,lights,ambient`): the live backdrop, the
    /// edge blur's effect, the board, the light nodes, the ambient motes.
    public nonisolated(unsafe) static var hidden: Set<String> = []

    /// `levelID`'s level, or its world's first; nil if the catalog has none.
    public init?(levelID: String?, size: CGSize) {
        guard let entry = levelID.flatMap(LevelCatalog.level(withID:)) ?? LevelCatalog.levels.first else { return nil }
        self.entry = entry
        theme = LevelCatalog.allWorlds.first { $0.index == entry.worldIndex }?.theme ?? .garden
        backdrop = BackdropNode(theme: theme, style: .calm, variant: entry.number)
        super.init(size: size)
        scaleMode = .aspectFill
        anchorPoint = pt(0.5, 0.5)
        backgroundColor = theme.palette.backgroundBottom
        UISkin.current = theme.skin
        addChild(backdrop)
        if BoardGrounding.shown(in: theme).contains(.light), let look = theme.palette.grounding, let pattern = look.pattern {
            let light = SharedLightNode(look: look, pattern: pattern, banded: true)
            light.zPosition = DesignSystem.groundingLightZ
            addChild(light)
            sharedLight = light
        }
        addChild(lights)
        addChild(worldLights)
        buildBoard()
    }

    public override func didMove(to view: SKView) {
        if !Self.hidden.contains("lights") {
            lights.start()
            worldLights.start()
        }
        board?.isHidden = Self.hidden.contains("board")
        layout()
        PlayLog.write("world preview: \(entry.id) over \(theme.rawValue)'s backdrop")
    }

    public override func willMove(from view: SKView) {
        lights.stop()
        worldLights.stop()
    }

    public override func didChangeSize(_ oldSize: CGSize) {
        layout()
    }

    public override func update(_ currentTime: TimeInterval) {
        layout()
        if Self.hidden.contains("blur") { (backdrop.children.first as? SKEffectNode)?.shouldEnableEffects = false }
        if Self.hidden.contains("live") { backdrop.liveBackdrop?.isHidden = true }
        if Self.hidden.contains("ambient") {
            backdrop.children.first?.children.first?.children.forEach { if $0 is AmbientParticlesNode { $0.isHidden = true } }
        }
    }

    private func buildBoard() {
        guard let state = try? GameEngine.createState(entry.level) else { return }
        let board = PlayBoardNode(level: entry.level, theme: theme, state: state)
        board.zPosition = DesignSystem.contentZ
        addChild(board)
        self.board = board
    }

    /// `GameScene.layout`'s backdrop half: the board fitted, then the
    /// backdrop told the board's shape, what the screen covers and where the
    /// round buttons stand.
    private func layout() {
        guard view != nil else { return }
        let layout = SceneLayout(scene: self)
        guard layout.visibleRect != laidOut else { return }
        laidOut = layout.visibleRect
        var occupied: [CGRect] = []
        var footprint: CGRect?
        var silhouette: [CGRect] = []
        if let board {
            board.setScale(1)
            let bounds = board.calculateAccumulatedFrame()
            if bounds.width > 0, bounds.height > 0 {
                let room = layout.safeRect.size
                let fit = min(room.width * DesignSystem.boardRoomShare / bounds.width, room.height * DesignSystem.boardRoomShare / bounds.height)
                let scale = min(fit, DesignSystem.boardCellScale)
                let position = pt(layout.safeRect.midX - bounds.midX * scale, layout.safeRect.midY - bounds.midY * scale)
                board.setScale(scale)
                board.position = position
                let placed = rect(position.x + bounds.minX * scale, position.y + bounds.minY * scale, bounds.width * scale, bounds.height * scale)
                footprint = placed
                occupied.append(placed)
                silhouette = board.silhouette(scale: scale, position: position)
            }
        }
        let header = DesignSystem.headerButtonSize
        let top = [-1, 1].map { side -> CGRect in
            let center = layout.cornerButtonCenter(side: CGFloat(side), end: 1, size: header)
            return rect(center.x - header / 2, center.y - header / 2, header, header)
        }
        let controls = ControlsBarFrame.bounds(layout)
        let edges = EdgeButtons(top: top, bottom: [controls])
        occupied += top + [controls]
        backdrop.outlineBoard(silhouette)
        backdrop.layout(layout, keepClear: occupied, edges: edges)
        if let footprint { backdrop.focus(on: footprint) }
        sharedLight?.layout(layout, board: footprint)
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        if let board, !board.isPlaying, let id = board.actorID(at: convert(point, to: board)) {
            move(id)
            return
        }
        let reacted = backdrop.touch(at: point)
        PlayLog.write(String(format: "tap at %.0f,%.0f: scenery %@", Double(point.x), Double(point.y), reacted ? "reacted" : "had nothing there"))
    }

    private func move(_ id: String) {
        guard let board else { return }
        let previous = board.state
        guard let direction = previous.switchling(id)?.direction,
              let next = GameEngine.move(previous, id: id, direction: direction) else { return }
        board.play(previous: previous, next: next) {}
    }
}

/// Where `GameScene` stands its four controls upright (`controlsCenter`,
/// `ControlsBarNode.bounds`), as a rect, for the edge blur behind them.
private enum ControlsBarFrame {
    static func bounds(_ layout: SceneLayout) -> CGRect {
        let size = DesignSystem.controlButtonSize
        let count: CGFloat = 4
        let span = size * count + DesignSystem.controlGap * (count - 1)
        let vertical = layout.isLandscape
        let box = vertical ? sz(size, span) : sz(span, size)
        let center = vertical
            ? pt(layout.safeRect.maxX - size / 2, layout.visibleRect.midY)
            : pt(layout.safeRect.midX, layout.contentBottom + DesignSystem.controlsBottomInset + size / 2)
        return rect(center.x - box.width / 2, center.y - box.height / 2 - DesignSystem.buttonEdgeDepth, box.width, box.height + DesignSystem.buttonEdgeDepth)
    }
}
