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
    /// A phone: the Android port's only idiom so far.
    public var userInterfaceIdiom: UIUserInterfaceIdiom { .phone }

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

open class UIWindow {
    public var bounds: CGRect
    public var safeAreaInsets: UIEdgeInsets = .zero
    public var windowScene: UIWindowScene?
    public var traitCollection: UITraitCollection { UITraitCollection.current }

    public init(bounds: CGRect) {
        self.bounds = bounds
    }
}

/// SpriteKit's view is a UIKit one, and the game reads it as one: its
/// bounds, safe area, traits and window. `SKView` builds on this.
open class UIView {
    public var bounds: CGRect

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
    public func convert(_ rect: CGRect, to view: UIView?) -> CGRect {
        guard let view, view !== self else { return rect }
        return rect.offsetBy(dx: bounds.minX - view.bounds.minX, dy: bounds.minY - view.bounds.minY)
    }
}

#endif
