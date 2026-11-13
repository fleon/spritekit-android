#if SPRITEKIT_SHIM
import Foundation

// What the game reads off its view as a UIKit view, rather than as
// SpriteKit's: `SceneLayout` takes the safe area, the trait collection and
// the window — the window for the display's rounded corners and which way
// the device is turned — and the loading screen builds its next scene with
// the view's traits current.
//
// On Android the view is the whole window, so the window is the view's own
// rectangle and the screen is the window's. There is no window yet: SDL
// owns the real one, and the corner radii the game keeps are measured off
// Apple's simulators, so `SceneLayout` takes its square-cornered path, as it
// does for a view that is not full screen. The safe area is whatever the
// shell sets.

public enum UIUserInterfaceIdiom: Int, Sendable {
    case unspecified = -1
    case phone, pad, tv, carPlay
    case mac = 5
    case vision = 6
}

public enum UIInterfaceOrientation: Int, Sendable {
    case unknown, portrait, portraitUpsideDown, landscapeLeft, landscapeRight

    public var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
    public var isPortrait: Bool { self == .portrait || self == .portraitUpsideDown }
}

extension UITraitCollection {
    /// A phone or a tablet, as the shell decides from the screen's
    /// smallest width (`UIDevice.current` says the same).
    public var userInterfaceIdiom: UIUserInterfaceIdiom { UITraitCollection.idiom }

    /// Set with `UIDevice.current.userInterfaceIdiom`.
    nonisolated(unsafe) public static var idiom: UIUserInterfaceIdiom = .phone

    /// Runs `actions` with this as `current`. A view's own traits already
    /// are current here, which is the call the game makes.
    public func performAsCurrent(_ actions: () throws -> Void) rethrows {
        guard self !== UITraitCollection.current else { return try actions() }
        let previous = UITraitCollection.current
        UITraitCollection.current = self
        defer { UITraitCollection.current = previous }
        try actions()
    }
}

@MainActor
public final class UIScreen {
    public var bounds: CGRect
    public var nativeBounds: CGRect
    public var nativeScale: CGFloat

    public init(bounds: CGRect, nativeScale: CGFloat) {
        self.bounds = bounds
        self.nativeScale = nativeScale
        nativeBounds = CGRect(
            x: 0, y: 0, width: bounds.width * nativeScale, height: bounds.height * nativeScale
        )
    }
}

@MainActor
open class UIWindowScene {
    public struct Geometry {
        public var interfaceOrientation: UIInterfaceOrientation
    }

    public let screen: UIScreen
    public var effectiveGeometry: Geometry

    public init(screen: UIScreen, interfaceOrientation: UIInterfaceOrientation = .unknown) {
        self.screen = screen
        effectiveGeometry = Geometry(interfaceOrientation: interfaceOrientation)
    }
}

@MainActor
open class UIWindow {
    public var bounds: CGRect
    public var safeAreaInsets: UIEdgeInsets = .zero
    public var windowScene: UIWindowScene?
    public var traitCollection: UITraitCollection { UITraitCollection.current }

    public init(bounds: CGRect) {
        self.bounds = bounds
    }

    /// Every touch event passes through here before the scene takes it
    /// (`SKScene.deliverTouch`); the game's `TouchOriginWindow` overrides it
    /// to note where the player touched.
    open func sendEvent(_ event: UIEvent) {
        observer?(event)
    }

    /// Hears every event that reaches the window's own `sendEvent`, after
    /// any subclass has: the port's controller takes focus back from a
    /// gamepad on a touch, as the Apple controller's `TouchWatcher` does.
    public var observer: ((UIEvent) -> Void)?
}

/// SpriteKit's view is a UIKit one, and the game reads it as one: its
/// bounds, safe area, traits and window. `SKView` builds on this.
@preconcurrency @MainActor
open class UIView {
    public var bounds: CGRect

    /// The layer the view draws into. On Apple an `SKView`'s is a
    /// `CAMetalLayer`, which `EdgeShade` asks for its drawable size; here
    /// there is no layer tree, so it is a plain one and the game falls back
    /// to `bounds` times `contentScaleFactor`, the same number.
    public let layer = CALayer()

    /// Carried: SpriteKit's view shows it only where no scene draws, and
    /// every scene here fills the view with its own colour.
    public var backgroundColor: UIColor?

    /// What system bars and cutouts cover, in points. The shell sets it.
    public var safeAreaInsets: UIEdgeInsets = .zero

    /// The window the view is in; none on Android yet (see above).
    public var window: UIWindow?

    public init(frame: CGRect) {
        bounds = CGRect(origin: .zero, size: frame.size)
    }

    /// The traits the game draws for: today's display scale.
    public var traitCollection: UITraitCollection { UITraitCollection.current }

    /// Rect conversion to another view's space; the view fills the window,
    /// so to the window (`nil`) it is the identity.
    /// Point conversion, as rects: the view fills the window.
    public func convert(_ point: CGPoint, to view: UIView?) -> CGPoint {
        guard let view, view !== self else { return point }
        return CGPoint(x: point.x + bounds.minX - view.bounds.minX, y: point.y + bounds.minY - view.bounds.minY)
    }

    public func convert(_ point: CGPoint, from view: UIView?) -> CGPoint {
        guard let view, view !== self else { return point }
        return view.convert(point, to: self)
    }

    public func convert(_ rect: CGRect, to view: UIView?) -> CGRect {
        guard let view, view !== self else { return rect }
        return rect.offsetBy(dx: bounds.minX - view.bounds.minX, dy: bounds.minY - view.bounds.minY)
    }
}

/// What the game names as the thing that presents: Game Center's sign-in
/// takes one, and the share sheet presents from one. On Android the
/// presenter is the activity, so this only carries the view.
@MainActor
open class UIViewController {
    open var view: UIView!

    public init() {}
}

#endif

#if SPRITEKIT_SHIM
/// Core Animation's layer, as far as the game asks after one.
open class CALayer {
    public init() {}
}

/// Named by `EdgeShade`'s `view.layer as? CAMetalLayer`; nothing is one here.
public final class CAMetalLayer: CALayer {
    public var drawableSize = CGSize.zero
}
#endif

