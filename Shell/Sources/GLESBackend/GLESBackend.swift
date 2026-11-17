import CAndroidShell
import Foundation
import GameCompat
import GLESRenderer
import PlatformShim
import ShellCore
import SpriteKitShim

/// How the shell gets a renderer.
///
/// The dependency runs one way: `AndroidShell` imports this, loads the art
/// and hands `makeRenderer` to `Shell.run`. This module knows nothing about
/// the shell beyond `ShellCore`'s seam types, and the shell knows nothing
/// about sprites, textures or shaders.
public enum GLESBackend {

    /// The game's controller, once the view exists.
    @MainActor static var controller: AndroidGameController?

    /// Reads the packed art and the fonts out of the APK, makes the game's
    /// resources reachable through `Bundle.main`, starts what the game
    /// starts at launch, and settles which scene to draw. Call before the
    /// first frame: with no asset index every texture resolves to the white
    /// placeholder, with no fonts registered every label measures zero and
    /// draws nothing, and with no resources no level, rig or string loads.
    @MainActor
    public static func prepare() {
        AssetBundle.installIndex()
        AssetBundle.installFonts()
        ResourceBundle.install()

        // One monotonic clock for the whole port: the shell's, which is
        // `SDL_GetTicksNS`. The game reads `CACurrentMediaTime()` in 30
        // places — `MediaClock`, every shader's `u_time`,
        // `BandedLayerNode.hold` — so there has to be exactly one of it.
        MediaTime.source = { TimeInterval(SDL_GetTicksNS()) / 1_000_000_000 }
        // `-FixedFrameStep`: the shell moves that clock on a step a frame
        // instead, from 0, before the game reads it.
        MediaTime.fixedStep = AndroidGameController.fixedFrameStep

        // Banded layers (`BandedLayerNode`): `debug.switchlings.bands`
        // `whole` draws them unbanded, a number in that many bands, for
        // measuring.
        if let bands = DebugProperty.string("debug.switchlings.bands") {
            if bands == "whole" {
                AndroidGameController.drawsBandedLayersWhole = true
            } else if let count = Int(bands), count > 0 {
                AndroidGameController.bandedLayerBands = count
            }
            Log.info("banded layers: \(bands)")
        }

        PNGFiles.install()
        AndroidGameController.launch(link: ShellArguments.value(after: LaunchLinks.launchLinkArgument).flatMap(URL.init(string:)))
    }

    /// Hands the game the shell's audio once its device is open.
    @MainActor
    public static func useAudio(_ audio: AudioBackend) {
        AndroidGameController.useAudio(audio)
    }

    /// The renderer the shell draws with.
    @MainActor
    public static func makeRenderer(_ context: RenderContext) -> FrameRenderer {
        if context.displayScale > 0 { pointScale = context.displayScale }
        let size = sceneSize(for: context.size)
        // How many pixels a point is worth, which is what the game reads to
        // decide the density of every texture it draws for itself
        // (`SurfaceTexture.renderScale`). It has to be right *before* the
        // scene builds, since that is when the surfaces are drawn.
        UITraitCollection.current.displayScale = Viewport(
            drawableSize: context.size, sceneSize: size, scaleMode: .aspectFill
        ).scale.x

        Log.info("scene: \(Int(size.width))x\(Int(size.height)) pt")
        let renderer = SceneRenderer(
            drawableSize: context.size,
            pointScale: pointScale,
            pageLoader: AssetBundle.page
        ) { _ in
            // The controller presents the splash on the first layout, once
            // the safe area is known (`windowMetricsDidChange`).
        }
        renderer.reportLabel = "game"
        controller = AndroidGameController(view: renderer.view)
        renderer.clockHold = { AndroidGameController.holdsFrameClock }
        if let controller {
            controller.captureFrame = { done in renderer.captureNextFrame(done) }
            renderer.onInput = { input in handle(input, controller: controller) }
            renderer.onMetrics = { metrics, view in
                controller.layout(
                    size: view.bounds.size,
                    safeArea: UIEdgeInsets(
                        top: metrics.safeArea.top / view.contentScaleFactor,
                        left: metrics.safeArea.left / view.contentScaleFactor,
                        bottom: metrics.safeArea.bottom / view.contentScaleFactor,
                        right: metrics.safeArea.right / view.contentScaleFactor
                    ),
                    orientation: orientation(metrics.orientation),
                    idiom: idiom(points: view.bounds.size),
                    maximumFramesPerSecond: metrics.refreshRate
                )
            }
            // Once the first layout has presented the splash: the Apple
            // controller's `viewDidAppear`.
            renderer.onAppear = { controller.didAppear() }
        }
        if let slowdown = DebugProperty.string("debug.switchlings.transitionslowdown").flatMap(Double.init), slowdown > 1 {
            renderer.view.transitionSpeed = 1 / slowdown
            Log.info("transitions \(slowdown)x slower")
        }
        // `-RenderScale`, or a capture running: every pixel, or the pin's.
        if let pinned = AndroidGameController.pinnedRenderScale {
            renderer.renderScale = CGFloat(pinned)
            renderer.pinsRenderScale = true
            Log.info("render scale held at \(pinned)")
        }
        if let scale = DebugProperty.string("debug.switchlings.renderscale").flatMap(Double.init), scale > 0 {
            renderer.renderScale = scale
            renderer.pinsRenderScale = true
            Log.info("render scale held at \(scale)")
        }
        // The frame rate and render scale: what the player picked, else
        // Auto's rate and the scale the renderer's governor chooses once for
        // this device (kept); a pick applies at once.
        renderer.measuresScene = { AndroidGameController.isMeasured($0) }
        renderer.onRunning = { AndroidGameController.setRunning(rate: $0, scale: $1) }
        renderer.onChosen = { AndroidGameController.noteAutoChosen(rate: $0, scale: $1) }
        let choices = AndroidGameController.displayChoices
        renderer.configure(rate: choices.rate, scales: choices.scales, governs: choices.governs, decided: choices.decided)
        AndroidGameController.observeDisplayChoices { [weak renderer] in
            let choices = AndroidGameController.displayChoices
            renderer?.configure(rate: choices.rate, scales: choices.scales, governs: choices.governs, decided: choices.decided, fromCurrent: true)
        }
        if let slowdown = DebugProperty.string("debug.switchlings.slowdown").flatMap(Double.init), slowdown > 1 {
            renderer.slowdown = slowdown
            Log.info("everything \(slowdown)x slower")
        }
        if DebugProperty.string("debug.switchlings.bandblur") == "off" {
            renderer.blursBandsOnly = false
            Log.info("edge blur through the whole backdrop")
        }
        return renderer
    }

    /// What the player did besides touching, handed to the game as the
    /// Apple controller hands it on.
    @MainActor
    private static func handle(_ input: InputEvent, controller: AndroidGameController) -> Bool {
        switch input {
        case .back:
            return controller.handleBack()
        case let .key(usage, modifiers):
            if UITextField.firstResponder != nil {
                switch usage {
                case UIKeyboardHIDUsage.keyboardDeleteOrBackspace.rawValue: UITextField.receive(.backspace)
                case UIKeyboardHIDUsage.keyboardReturnOrEnter.rawValue: UITextField.receive(.return)
                // A hardware keyboard's paste, as UIKit's field takes it.
                case UIKeyboardHIDUsage.keyboardV.rawValue where UIKeyModifierFlags(rawValue: modifiers).contains(.control) || UIKeyModifierFlags(rawValue: modifiers).contains(.command):
                    if let text = SystemServices.clipboard.get(), !text.isEmpty { UITextField.receive(.insert(text)) }
                default: break
                }
                return true
            }
            guard let key = UIKeyboardHIDUsage(rawValue: usage) else { return false }
            return controller.handleKey(key, modifiers: UIKeyModifierFlags(rawValue: modifiers))
        case let .text(text):
            UITextField.receive(.insert(text))
            return true
        case let .gamepad(event):
            GamepadEvents.post(event)
            return true
        case let .link(url):
            controller.open(url)
            return true
        }
    }

    /// SDL's `SDL_DisplayOrientation` as UIKit's.
    private static func orientation(_ sdl: Int) -> UIInterfaceOrientation {
        switch sdl {
        case Int(SDL_ORIENTATION_LANDSCAPE.rawValue): return .landscapeRight
        case Int(SDL_ORIENTATION_LANDSCAPE_FLIPPED.rawValue): return .landscapeLeft
        case Int(SDL_ORIENTATION_PORTRAIT_FLIPPED.rawValue): return .portraitUpsideDown
        default: return .portrait
        }
    }

    /// A tablet by Android's own rule: a smallest width of 600 dp or more
    /// (a point is a dp here).
    private static func idiom(points: CGSize) -> UIUserInterfaceIdiom {
        min(points.width, points.height) >= 600 ? .pad : .phone
    }

    @MainActor
    private static func aspectFill(_ scene: SKScene) -> SKScene {
        scene.scaleMode = .aspectFill
        return scene
    }

    /// `DesignSystem.sceneSize(for:)`, in points, from a drawable in pixels.
    @MainActor
    static func sceneSize(for drawable: CGSize) -> CGSize {
        AndroidGameController.sceneSize(for: CGSize(width: drawable.width / pointScale, height: drawable.height / pointScale))
    }

    /// Pixels per point: the display's density (`SDL_GetWindowDisplayScale`,
    /// dpi / 160), as an iOS point is a screen's — not the art's export
    /// scale, which made a 420 dpi phone 360 points wide where the same
    /// phone is 411 dp, and every popup 12% wider than on an iPhone.
    @MainActor static var pointScale: CGFloat = 3
}
