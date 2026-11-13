import Foundation
import SpriteKitShim

// What a share film's stage reaches for that isn't ported yet. The film
// itself — `SolutionFilm.swift` (its stage and `FilmDrawTurns` included),
// `FilmSoundtrack.swift` and `MediaClock.swift` — is the game's own file,
// unmodified, as are the wordmark over the board (`TitleLogoNode`) and the
// credit and code under it (`CreditNode`, `LevelCodeNode`, `ShadowLabelNode`).
// Each type below is a seam for a ring of its own, and goes when the real
// file compiles here:
//
//   - `BoardNode` is 2,701 lines over 38 component files; the gameplay
//     ring's `PlayBoardNode` stands in, carried by the same `Timeline` at
//     each Switchling's rig pace, with `BoardNode`'s intro timings, so a
//     film's moves start on the frames they start on iOS.
//   - `BackdropNode` is the eight live backdrops; this draws the world's
//     gradient, which the real one shows under them till they bake.
//   - The lights (`SceneLightNode`, `WorldLightNode`, `SharedLightNode`,
//     `LightCanvas`) are the lighting ring's; a film here is lit as painted.
//   - `ShareFormNode`, `SolutionShare` and `EdgeButtons` are the UI ring's,
//     and only their shapes are here.

// MARK: - The share form's choices (`ShareFormNode`'s own enums, verbatim)

enum ShareFormNode {
    enum Format: Int {
        case image
        case video
        /// A Level Designer level's picture of how it starts.
        case puzzle
    }

    enum FrameRate: Int, CaseIterable {
        case standard = 30
        case smooth = 60
    }

    enum Orientation: Int {
        case portrait
        case landscape
    }
}

// MARK: - Who a share credits (`SolutionShare.Attribution`, verbatim)

enum SolutionShare {
    struct Attribution {
        let name: String
        let photo: UIImage?
        var caption = LocalizedString.shareCreatedBy
        var codeCaption = LocalizedString.shareLevelCode

        static func anonymous(in theme: WorldTheme) -> Attribution {
            let cast = Cast.allCases.randomElement() ?? .a
            let pose = Int.random(in: 1...DesignSystem.shareAvatarPoses)
            let name: LocalizedString = StoreManager.shared.isFullGameUnlocked ? .shareSupporter : .sharePlayer
            return Attribution(name: name.localized, photo: UIImage(named: "Avatar\(theme.assetName)\(cast.rawValue)\(pose)"))
        }
    }
}

// MARK: - The board

/// The game's `BoardNode`, as far as a share film uses it, over the gameplay
/// ring's `PlayBoardNode`. Its geometry (`frameRect`, `placement`,
/// `footprint`, `silhouette`) is `BoardNode`'s own maths over the same
/// outline and kerbs.
final class BoardNode: SKNode {
    let metrics: BoardMetrics
    let frameRect: CGRect
    var isSilent = false
    var soundSink: ((AudioManager.Sound) -> Void)?
    private let board: PlayBoardNode
    private let silhouetteRects: [CGRect]
    private let paces: [String: Timeline.Pace]

    init(level: Level, state: GameState, theme: WorldTheme, isTransposed: Bool) {
        board = PlayBoardNode(level: level, theme: theme, state: state)
        metrics = board.metrics
        let outer = board.frameNode?.outerRect ?? .zero
        let arrowTop = metrics.point(GridPoint(metrics.originX, metrics.originY)).y
            + metrics.cell * (DesignSystem.arrowFloatOffsetRatio + DesignSystem.arrowFloatSizeRatio / 2)
        frameRect = outer.isEmpty ? outer : rect(outer.minX, outer.minY, outer.width, max(outer.maxY, arrowTop) - outer.minY)
        let cellMetrics = board.metrics
        silhouetteRects = board.outline.cells.map { cell in
            let center = cellMetrics.point(cell)
            return rect(center.x - cellMetrics.cell / 2, center.y - cellMetrics.cell / 2, cellMetrics.cell, cellMetrics.cell)
        } + (board.frameNode?.pieceFrames ?? [])
        paces = Dictionary(uniqueKeysWithValues: state.switchlings.map { ($0.id, Self.pace(castID: $0.id, theme: theme)) })
        super.init()
        addChild(board)
    }

    /// `BoardNode.placement(in:maxScale:)`.
    func placement(in area: CGRect, maxScale: CGFloat) -> (scale: CGFloat, position: CGPoint) {
        let frameHeight = frameRect.height + DesignSystem.frameBaseDepth
        let scale = min(area.width / frameRect.width, area.height / frameHeight, maxScale)
        let position = pt(
            area.midX - frameRect.midX * scale,
            area.midY - (frameRect.midY - DesignSystem.frameBaseDepth / 2) * scale
        )
        return (scale, position)
    }

    /// `BoardNode.footprint(at:)`.
    func footprint(at placement: (scale: CGFloat, position: CGPoint)) -> CGRect {
        let base = DesignSystem.frameBaseDepth
        return rect(
            placement.position.x + frameRect.minX * placement.scale,
            placement.position.y + (frameRect.minY - base) * placement.scale,
            frameRect.width * placement.scale,
            (frameRect.height + base) * placement.scale
        )
    }

    /// `BoardNode.silhouette(at:)`.
    func silhouette(at placement: (scale: CGFloat, position: CGPoint)) -> [CGRect] {
        silhouetteRects.map { area in
            rect(placement.position.x + area.minX * placement.scale, placement.position.y + area.minY * placement.scale,
                 area.width * placement.scale, area.height * placement.scale)
        }
    }

    @discardableResult
    func playIntro(delay: TimeInterval, slowdown: Double) -> TimeInterval {
        board.playIntro(delay: delay, slowdown: slowdown)
    }

    func celebrate() {
        board.celebrate()
    }

    @discardableResult
    func animate(from previous: GameState, to next: GameState, slowdown: Double) -> TimeInterval {
        let paces = paces
        let sink = soundSink
        return board.play(previous: previous, next: next, speed: 1 / slowdown, pace: { paces[$0] ?? .board }, sounds: sink) {}
    }

    /// `ActorNode.pace`, from the rig the Switchling would play: how long
    /// the board takes to carry it, so its moves last as long as on iOS.
    private static func pace(castID: String, theme: WorldTheme) -> Timeline.Pace {
        let name = String(theme.characterName(castID).dropFirst("Character".count))
        guard let move = RigData.named(name)?.move else { return .board }
        func span(_ window: ClosedRange<CGFloat>) -> Double { Double(window.upperBound - window.lowerBound) * 1000 }
        let step = RigNode.travel(of: move)
        let hop = RigNode.travel(of: "hop")
        let jump = RigNode.travel(of: "jump")
        let rebound = RigNode.travel(of: "rebound")
        return Timeline.Pace(
            step: span(step),
            windUp: Double(step.lowerBound) * 1000,
            eases: move == "slide",
            hop: move == "slide" ? span(hop) : nil,
            hopWindUp: Double(hop.lowerBound) * 1000,
            jump: span(jump),
            jumpWindUp: Double(jump.lowerBound) * 1000,
            rebound: span(rebound),
            convey: Double(DesignSystem.rigRideCell) * 1000,
            slide: span(DesignSystem.rigSlideTravel),
            glides: true,
            portal: Double(DesignSystem.rigPortal) * 1000,
            swapPad: Double(DesignSystem.rigWarp) * 1000
        )
    }
}

// MARK: - The backdrop

/// The world's backdrop behind a film's board: its gradient, top to
/// bottom (`WorldPalette.backgroundTop`, `backgroundBottom`), as the real
/// one shows wherever its live scenery isn't drawn.
final class BackdropNode: SKNode {
    private let theme: WorldTheme
    private let gradient = SKSpriteNode()
    /// Rows in the gradient's texture, stretched over the frame.
    private static let gradientSteps: CGFloat = 256

    init(theme: WorldTheme) {
        self.theme = theme
        super.init()
        addChild(gradient)
    }

    func layout(_ layout: SceneLayout, keepClear: [CGRect], edges: EdgeButtons) {
        let visible = layout.visibleRect
        let palette = theme.palette
        let image = UIGraphicsImageRenderer(size: sz(1, Self.gradientSteps)).image { context in
            let colours = [palette.backgroundTop.cgColor, palette.backgroundBottom.cgColor] as CFArray
            if let fill = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(fill, start: .zero, end: pt(0, Self.gradientSteps), options: [])
            }
        }
        gradient.texture = SKTexture(image: image)
        gradient.size = visible.size
        gradient.position = pt(visible.midX, visible.midY)
    }

    func outlineBoard(_ silhouette: [CGRect]) {}
    func focus(on board: CGRect) {}
    func planScenery() {}
    func host(in view: SKView, pointsPerUnit: CGFloat) {}
    func bakeNow() {}
}

// MARK: - Lights

/// Where an off-screen scene's lights fall (`SceneLighting.swift`).
enum LightCanvas {
    case view(SKView)
    case render(visible: CGRect, pixelsPerPoint: CGFloat)
}

final class SceneLightNode: SKNode {
    var offscreen: LightCanvas?
    init(_ cellSize: @escaping () -> CGFloat) { super.init() }
    func start() {}
}

final class WorldLightNode: SKNode {
    var offscreen: LightCanvas?
    init(boards: @escaping () -> [BoardNode], backdrops: @escaping () -> [BackdropNode]) { super.init() }
    func start() {}
}

final class SharedLightNode: SKNode {
    init(look: GroundingLook, pattern: SharedLightPattern) { super.init() }
    func layout(_ layout: SceneLayout, board: CGRect) {}
}

extension BoardGrounding {
    /// What a world shows round its board (`BoardGroundingArt.swift`): none
    /// of it is drawn here yet.
    static func shown(in theme: WorldTheme) -> BoardGrounding { [] }
}

// MARK: - Layout, as far as the stage names it

/// The round buttons' frames along each edge (`EdgeShade.swift`).
struct EdgeButtons: Equatable {
    var top: [CGRect] = []
    var bottom: [CGRect] = []
}
