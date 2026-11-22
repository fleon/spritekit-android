#if SPRITEKIT_SHIM
import Foundation
import PlatformCore
import PlatformDisplay
import PlatformShim
import PlatformSprite
import SpriteKitShim

/// What an Android controller stands its game on in place of UIKit's view
/// controller: the game's one `SKView`, the window and window scene it
/// sits in and the screen, laid out as the shell reports the view, and the
/// launch (`StudioSplashLaunch`) until the first scene.
///
/// UIKit makes these for an Apple app; here it's the controller's job, the
/// same in every game: SpriteKit's code reads the view's safe area, its
/// window's scene (`SKStoreReviewController.requestReview(in:)`), the
/// screen's size and scale and the device's idiom as it does on Apple.
public final class GameHostSurface {
    public let view: SKView
    public let window: UIWindow
    public let screen: UIScreen
    /// Held here, as UIKit's application holds its scenes: the window's
    /// reference to it is weak.
    public let windowScene: UIWindowScene
    /// The launch splash (`StudioSplashLaunch`), which holds the view until
    /// it hands over to the first scene.
    public var launch: SceneLaunch?
    /// Set by the shell: takes the next frame drawn, for snapshots.
    public var captureFrame: ((@escaping (RasterImage?) -> Void) -> Void)?
    /// Whether the view has appeared (`didAppear`).
    public private(set) var hasAppeared = false

    /// A window of the game's own class (one that notes touches) may be
    /// handed in; else a plain one.
    public init(view: SKView, window: UIWindow? = nil) {
        self.view = view
        screen = UIScreen(bounds: view.bounds, nativeScale: view.contentScaleFactor)
        self.window = window ?? UIWindow(bounds: view.bounds)
        windowScene = UIWindowScene(screen: screen, interfaceOrientation: .portrait)
        self.window.windowScene = windowScene
        view.window = self.window
        view.ignoresSiblingOrder = true
    }

    /// The safe area the game lays out in: the device's, or in a debug
    /// build `-SafeAreaInsets top,left,bottom,right` (`SafeAreaOverride`),
    /// an iPhone's for comparing screens with it.
    public static func safeArea(_ device: UIEdgeInsets, defaults: UserDefaults = .standard) -> UIEdgeInsets {
        #if DEBUG
        if let forced = SafeAreaOverride.parse(defaults.string(forKey: SafeAreaOverride.argument)) {
            return UIEdgeInsets(top: forced.top, left: forced.left, bottom: forced.bottom, right: forced.right)
        }
        #endif
        return device
    }

    /// Copies the shell's layout into the view, the window, the screen,
    /// the device's idiom and `DisplaySettings.screenMaximum`: the part of
    /// `viewDidLayoutSubviews` UIKit does itself on Apple.
    public func apply(size: CGSize, safeArea deviceSafeArea: UIEdgeInsets, orientation: UIInterfaceOrientation, idiom: UIUserInterfaceIdiom, maximumFramesPerSecond: Int) {
        let safeArea = Self.safeArea(deviceSafeArea)
        let bounds = CGRect(origin: .zero, size: size)
        let scale = view.contentScaleFactor
        view.bounds = bounds
        view.safeAreaInsets = safeArea
        window.bounds = bounds
        window.safeAreaInsets = safeArea
        screen.bounds = bounds
        screen.nativeScale = scale
        screen.nativeBounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        windowScene.effectiveGeometry.interfaceOrientation = orientation
        HostIdiom.set(idiom)
        // The frame rates on offer follow it (`observeDisplayChoices`).
        if maximumFramesPerSecond != DisplaySettings.screenMaximum {
            DisplaySettings.screenMaximum = maximumFramesPerSecond
        }
    }

    /// `apply`, then the launch splash's turn: true when the game's own
    /// scene shows and should follow the view (the view has a size and the
    /// splash no longer holds it).
    @discardableResult
    public func layout(size: CGSize, safeArea: UIEdgeInsets, orientation: UIInterfaceOrientation, idiom: UIUserInterfaceIdiom, maximumFramesPerSecond: Int) -> Bool {
        apply(size: size, safeArea: safeArea, orientation: orientation, idiom: idiom, maximumFramesPerSecond: maximumFramesPerSecond)
        guard size.width > 0, size.height > 0 else { return false }
        if let launch, launch.layout(view) { return false }
        return view.scene != nil
    }

    /// `viewDidAppear`: the splash starts its clock and what it waits for.
    public func didAppear() {
        hasAppeared = true
        launch?.start()
    }

    /// For the shell's scene dump: the view's size and safe area and the
    /// scene's class and size.
    public var debugSummary: String {
        "view \(view.bounds.size) safe \(view.safeAreaInsets) scene \(view.scene.map { "\(type(of: $0)) \($0.size)" } ?? "none")"
    }

    /// A positive number given as a launch argument (`-FixedFrameStep
    /// 0.0333` or `1/30`, `-RenderScale 0.85`), as a number or as text read
    /// by `LaunchArgumentReader.fraction`; nil when it isn't given, isn't
    /// positive, or in a release build.
    public static func launchNumber(_ key: String, defaults: UserDefaults = .standard) -> Double? {
        #if DEBUG
        if let number = defaults.object(forKey: key) as? NSNumber {
            return number.doubleValue > 0 ? number.doubleValue : nil
        }
        return LaunchArgumentReader(defaults: defaults, enabled: true).fraction(key)
        #else
        return nil
        #endif
    }
}

/// The device's idiom, as `UIDevice.current` answers it. The shim leaves
/// UIKit's device glue out of a Mac host build, where the trait
/// collection's alone takes it.
enum HostIdiom {
    static func set(_ idiom: UIUserInterfaceIdiom) {
        #if canImport(Darwin)
        UITraitCollection.idiom = idiom
        #else
        UIDevice.current.userInterfaceIdiom = idiom
        #endif
    }
}
#endif
