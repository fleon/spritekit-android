import Foundation
import PlatformShim
import SpriteKitShim

/// What the shell asks of the game: the seam that keeps the runtime free of
/// any one game.
///
/// The game's controller adopts it (the Android counterpart of its Apple
/// view controller), and the game's own entry target hands its type to
/// `Shell.start(argc:argv:app:game:configure:)`. Nothing in
/// the shell imports the game; everything it needs from it is here.
@MainActor
public protocol GameHost: AnyObject {
    /// Made once the renderer's view exists; presents the first scene on
    /// its first `layout`.
    init(view: SKView)

    /// Starts what the Apple app delegate starts at launch, in its order.
    /// `link` is the URL the app was opened with, if any.
    static func launch(link: URL?)
    /// Hands the game the shell's audio once its device opens.
    static func useAudio(_ backend: AudioBackend)
    /// The scene's size in points for a view of `size` points.
    static func sceneSize(for size: CGSize) -> CGSize

    /// `-FixedFrameStep`: the clock moves on exactly this much a frame.
    static var fixedFrameStep: TimeInterval? { get }
    /// While true, frames draw but the clock doesn't move (a build off the
    /// main thread is holding the game's media clock).
    static var holdsFrameClock: Bool { get }

    /// The frame rate, the render scales on offer, whether Auto governs,
    /// and the scale Auto chose for this device, if it has.
    static var displayChoices: (rate: Int, scales: [Double], governs: Bool, decided: Double?) { get }
    /// A render scale the game pins (a capture running), if any.
    static var pinnedRenderScale: Double? { get }
    /// Calls `changed` whenever `displayChoices` changes.
    static func observeDisplayChoices(_ changed: @escaping @MainActor () -> Void)
    /// Whether Auto may measure frames while `scene` shows.
    static func isMeasured(_ scene: SKScene?) -> Bool
    /// The rate and scale the renderer is drawing at now.
    static func setRunning(rate: Int, scale: Double)
    /// Auto's choice for this device, to keep for good.
    static func noteAutoChosen(rate: Int, scale: Double)

    /// Set by the shell: takes the next frame drawn, for snapshots.
    var captureFrame: ((@escaping (RasterImage?) -> Void) -> Void)? { get set }
    /// `viewDidLayoutSubviews`: the view's size in points, its safe area,
    /// which way up, the idiom and the display's refresh rate.
    func layout(size: CGSize, safeArea: UIEdgeInsets, orientation: UIInterfaceOrientation, idiom: UIUserInterfaceIdiom, maximumFramesPerSecond: Int)
    /// `viewDidAppear`: once the first layout has presented a scene.
    func didAppear()
    /// Android's Back, as Escape: true if the game took it. False leaves
    /// the game (to the background).
    func handleBack() -> Bool
    /// A hardware key, by HID usage.
    func handleKey(_ key: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Bool
    /// A link the app was sent while running.
    func open(_ url: URL)
    /// A line about the game's state for the scene dump
    /// (`debug.<app>.dump`).
    var debugSummary: String { get }
}
