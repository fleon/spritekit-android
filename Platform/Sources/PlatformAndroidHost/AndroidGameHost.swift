#if SPRITEKIT_SHIM
import Foundation
import PlatformAudio
import PlatformDisplay
import PlatformShim
import SpriteKitShim

/// The members of the shell's `GameHost` that every game's Android
/// controller answers alike, answered from its `GameHostSurface`, the
/// shared `AudioManager` and `DisplaySettings` (`DisplaySettingsHost`). A
/// controller that adopts this as well as `GameHost` writes only its
/// `surface`, `init(view:)`, `launch(link:)` and `sceneSize(for:)`, and
/// whatever it does differently (its own members win):
///
///     public final class AndroidGameController {
///         public let surface: GameHostSurface
///         public init(view: SKView) {
///             surface = GameHostSurface(view: view)
///             surface.launch = StudioSplashLaunch(style: ..., firstScene: .built { ... })
///         }
///         ...
///     }
///     extension AndroidGameController: GameHost, AndroidGameHost {}
///
/// What the defaults do: `layout` lays the surface out, lets the splash
/// take the view while it holds it, then sizes the scene to
/// `sceneSize(for:)` and calls `didLayout(_:)`; `didAppear` starts the
/// splash; Back, keys and links go untaken (Back then leaves the game, as
/// it leaves any Android app); `-FixedFrameStep` steps the clock in a
/// debug build.
public protocol AndroidGameHost: AnyObject, DisplaySettingsHost {
    var surface: GameHostSurface { get }
    /// The scene's size in points for a view of `size` points.
    static func sceneSize(for size: CGSize) -> CGSize
    /// Called after each layout that sized the game's scene to the view
    /// (a scene told its safe area, say).
    func didLayout(_ scene: SKScene)
}

extension AndroidGameHost {
    public var view: SKView { surface.view }

    public var captureFrame: ((@escaping (RasterImage?) -> Void) -> Void)? {
        get { surface.captureFrame }
        set { surface.captureFrame = newValue }
    }

    public static func useAudio(_ backend: AudioBackend) {
        AudioManager.shared.use(backend)
    }

    /// `-FixedFrameStep 0.0333` or `1/30` (debug builds): the clock moves
    /// on exactly this much a frame, for a parity capture.
    public static var fixedFrameStep: TimeInterval? { GameHostSurface.launchNumber("FixedFrameStep") }

    public static var holdsFrameClock: Bool { false }

    public func layout(size: CGSize, safeArea: UIEdgeInsets, orientation: UIInterfaceOrientation, idiom: UIUserInterfaceIdiom, maximumFramesPerSecond: Int) {
        guard surface.layout(size: size, safeArea: safeArea, orientation: orientation, idiom: idiom, maximumFramesPerSecond: maximumFramesPerSecond),
              let scene = surface.view.scene
        else { return }
        let sceneSize = Self.sceneSize(for: size)
        if scene.size != sceneSize { scene.size = sceneSize }
        didLayout(scene)
    }

    public func didLayout(_ scene: SKScene) {}

    public func didAppear() {
        surface.didAppear()
    }

    public func handleBack() -> Bool { false }

    #if !canImport(Darwin)
    // The shim's keys are Android's alone: a Mac host build has none.
    public func handleKey(_ key: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Bool { false }
    #endif

    public func open(_ url: URL) {}

    public var debugSummary: String { surface.debugSummary }
}
#endif
