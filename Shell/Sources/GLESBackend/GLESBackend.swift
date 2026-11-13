import CAndroidShell
import Foundation
import GameCompat
import GLESRenderer
import ShellCore
import SpriteKitShim

/// How the shell gets a renderer.
///
/// The dependency runs one way: `AndroidShell` imports this, loads the art
/// and hands `makeRenderer` to `Shell.run`. This module knows nothing about
/// the shell beyond `ShellCore`'s four seam types, and the shell knows
/// nothing about sprites, textures or shaders.
public enum GLESBackend {

    /// Which scene the shell draws. Set before the first frame from
    /// `debug.switchlings.scene`, so a measuring run can switch with
    /// `adb shell setprop` and no rebuild.
    public enum Scene: String {
        /// A real level from the catalog, played through `Timeline` — the
        /// default, falling back to the hand-laid board if the catalog did
        /// not load.
        case level
        /// The hand-laid board with its rigs, no level behind it.
        case board
        /// Starry Sky's backdrop, drawn by the game's own `NightSkyNode`,
        /// with a board of Sky's bricks over it.
        case sky
        /// The same board, the same loop, no backdrop — the baseline the
        /// sky's cost is measured against.
        case skyBoardOnly
        /// The sky drawn whole every frame instead of in bands, so the
        /// saving `BandedLayerNode` buys can be read off.
        case skyUnbanded
        /// The reef's particles alone, each emitter set up exactly as
        /// `SeabedNode` sets it up: snow, motes, puffing vents, and a burst
        /// of bubbles wherever a tap lands.
        case particles
        /// Lawn-kit pieces bent by the game's own `BackdropWarp` and
        /// `BackdropTouch` (SKWarpGeometry).
        case warp
        /// A level over its world's live backdrop, lit, with the edge blur:
        /// `world:reef-1` (or `world` with `-StartLevel`), the game's own
        /// `BackdropNode` in `WorldPreviewScene`.
        case world
    }

    /// The level `world` shows: `debug.switchlings.scene world:<id>`.
    public nonisolated(unsafe) static var worldLevel: String?

    public nonisolated(unsafe) static var scene: Scene = .level

    /// Reads the packed art, the fonts and the levels out of the APK, makes
    /// the rigs reachable, and settles which scene to draw. Call before the
    /// first frame: with no asset index every texture resolves to the white
    /// placeholder, with no fonts registered every label measures zero and
    /// draws nothing, with no rig bundle no Switchling moves, and with no
    /// levels the board falls back to the hand-laid preview.
    public static func prepare() {
        AssetBundle.installIndex()
        AssetBundle.installFonts()
        RigBundle.install()
        LevelBundle.install()

        // One monotonic clock for the whole port: the shell's, which is
        // `SDL_GetTicksNS`. The game reads `CACurrentMediaTime()` in 30
        // places — `MediaClock`, every shader's `u_time`,
        // `BandedLayerNode.hold` — so there has to be exactly one of it, and
        // two clocks with different origins would put the sky's bands on a
        // different second from the frame times that drive them.
        MediaTime.source = { TimeInterval(SDL_GetTicksNS()) / 1_000_000_000 }

        PlayScene.autoSolves = DebugProperty.string("debug.switchlings.autosolve") == "1"
            || ShellArguments.has("-AutoSolve")

        if let name = DebugProperty.string("debug.switchlings.scene") {
            let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
            if let picked = parts.first.flatMap(Scene.init(rawValue:)) {
                scene = picked
                if parts.count > 1 { worldLevel = parts[1] }
            }
        }
        // Per launch, so it never changes the scene another app on a shared
        // emulator picks up from the property.
        if ShellArguments.has("-WarpProbe") { scene = .warp }
        if let hide = ShellArguments.value(after: "-WorldHide") {
            WorldPreviewScene.hidden = Set(hide.split(whereSeparator: { $0 == "," || $0 == "+" }).map(String.init))
        }
        PNGFiles.install()
        PlayScene.options = playOptions()
    }

    /// What a cleared level's Share films, from the launch arguments: the share
    /// film's choices (the win card's form, until it's ported) and the
    /// scripted runs that film one unattended.
    ///
    ///     --esa args "-StartLevel,garden-3,-AutoSolve,-AutoShare,-ShareFrameRate,30"
    static func playOptions() -> PlayScene.Options {
        var options = PlayScene.Options()
        options.autoShare = ShellArguments.has("-AutoShare")
        options.share.picture = ShellArguments.value(after: "-ShareFormat") == "image"
        options.share.smooth = ShellArguments.value(after: "-ShareFrameRate") != "30"
        options.share.landscape = ShellArguments.value(after: "-ShareOrientation") == "landscape"
        options.share.includesLink = ShellArguments.value(after: "-ShareLink") != "NO"
        if options.autoShare {
            Log.info("share: \(options.share)")
        }
        return options
    }

    /// The renderer the shell draws with.
    public static func makeRenderer(_ context: RenderContext) -> FrameRenderer {
        let size = sceneSize(for: context.size)
        // How many pixels a point is worth, which is what the game reads to
        // decide the density of every texture it draws for itself
        // (`SurfaceTexture.renderScale`). It has to be right *before* the
        // scene builds, since that is when the surfaces are drawn.
        UITraitCollection.current.displayScale = Viewport(
            drawableSize: context.size, sceneSize: size, scaleMode: .aspectFill
        ).scale.x

        Log.info("scene: \(Self.scene.rawValue), \(Int(size.width))x\(Int(size.height)) pt")
        let renderer = SceneRenderer(
            drawableSize: context.size,
            pointScale: pointScale,
            pageLoader: AssetBundle.page
        ) { view in
            switch Self.scene {
            case .level:
                // A real level, opened the way the game opens one: through
                // `TransitionManager` and the loading screen. Else the
                // hand-laid preview, so a missing or broken level file shows
                // the pipeline still works rather than a blank screen.
                if AndroidLevels.present(levelID: ShellArguments.value(after: "-StartLevel"), in: view) { return }
                view.presentScene(aspectFill(BoardPreviewScene(size: size)))
            case .board:
                view.presentScene(aspectFill(BoardPreviewScene(size: size)))
            case .sky:
                view.presentScene(aspectFill(SkyBackdropScene(size: size, drawsBackdrop: true, banded: true)))
            case .skyBoardOnly:
                view.presentScene(aspectFill(SkyBackdropScene(size: size, drawsBackdrop: false, banded: true)))
            case .skyUnbanded:
                view.presentScene(aspectFill(SkyBackdropScene(size: size, drawsBackdrop: true, banded: false)))
            case .particles:
                view.presentScene(aspectFill(EmitterPreviewScene(size: size)))
            case .warp:
                view.presentScene(aspectFill(WarpProbeScene(size: size)))
            case .world:
                let id = Self.worldLevel ?? ShellArguments.value(after: "-StartLevel")
                if let scene = WorldPreviewScene(levelID: id, size: size) {
                    view.presentScene(aspectFill(scene))
                } else {
                    view.presentScene(aspectFill(BoardPreviewScene(size: size)))
                }
            }
        }
        renderer.reportLabel = Self.scene.rawValue
        if let slowdown = DebugProperty.string("debug.switchlings.transitionslowdown").flatMap(Double.init), slowdown > 1 {
            renderer.view.transitionSpeed = 1 / slowdown
            Log.info("transitions \(slowdown)x slower")
        }
        if let slowdown = DebugProperty.string("debug.switchlings.slowdown").flatMap(Double.init), slowdown > 1 {
            renderer.slowdown = slowdown
            Log.info("everything \(slowdown)x slower")
        }
        return renderer
    }

    private static func aspectFill(_ scene: SKScene) -> SKScene {
        scene.scaleMode = .aspectFill
        return scene
    }

    /// `DesignSystem.sceneSize(for:)`, in points, from a drawable in pixels.
    ///
    /// The drawable is physical pixels and the game thinks in points, so the
    /// density comes out of the asset index — the art is exported at one
    /// scale and a design point is a point at that scale. The sizing itself
    /// is the game's own, now that DesignSystem compiles here.
    static func sceneSize(for drawable: CGSize) -> CGSize {
        let scale = pointScale
        return AndroidLevels.sceneSize(
            forViewSize: CGSize(width: drawable.width / scale, height: drawable.height / scale)
        )
    }

    /// Pixels per point: the art is exported at one scale, and a design
    /// point is a point at that scale.
    static var pointScale: CGFloat { AssetIndex.shared?.scale ?? 3 }
}
