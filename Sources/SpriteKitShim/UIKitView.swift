#if SPRITEKIT_SHIM
import Foundation

// What a game reads off its view as a UIKit view, rather than as
// SpriteKit's: the safe area, the trait collection and the window — the
// window for the display's rounded corners and which way the device is
// turned — and the view's traits current while a scene builds.
//
// On Android the view is the whole window, so the window is the view's own
// rectangle and the screen is the window's. There is no window yet: SDL
// owns the real one, so a game that keeps corner radii per screen finds
// none and takes its square-cornered path, as it does for a view that is
// not full screen. The safe area is whatever the
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
    /// UIKit's `coordinateSpace` kinds, as far as the game asks: bounds.
    public struct CoordinateSpace: Sendable {
        public let bounds: CGRect
    }

    /// The screen the game shows on: Android has one, the last made. A game
    /// reads its size here, where iOS finds it through its window scenes.
    /// Not optional, as UIKit's isn't: until the shell makes the window's
    /// screen, a placeholder (no size, one pixel a point) answers.
    public private(set) static var main = UIScreen(placeholder: ())

    public var bounds: CGRect
    public var nativeBounds: CGRect
    public var nativeScale: CGFloat

    /// Pixels a point. UIKit's is a whole 2 or 3 and its `nativeScale` the
    /// panel's own; an Android display has only its density, which is both.
    public var scale: CGFloat { nativeScale }

    /// Its bounds upright, whichever way it's turned, as UIKit's fixed
    /// coordinate space gives them.
    public var fixedCoordinateSpace: CoordinateSpace {
        CoordinateSpace(bounds: CGRect(x: 0, y: 0, width: min(bounds.width, bounds.height),
                                       height: max(bounds.width, bounds.height)))
    }

    private init(placeholder: Void) {
        bounds = .zero
        nativeScale = 1
        nativeBounds = .zero
    }

    public init(bounds: CGRect, nativeScale: CGFloat) {
        self.bounds = bounds
        self.nativeScale = nativeScale
        nativeBounds = CGRect(
            x: 0, y: 0, width: bounds.width * nativeScale, height: bounds.height * nativeScale
        )
        Self.main = self
    }
}

/// A scene the app shows, as `UIApplication.connectedScenes` lists it. Its
/// activation follows the app's (`UIApplication.applicationState`): Android
/// has one scene, in front while the game is.
@MainActor
open class UIScene: Hashable {
    public enum ActivationState: Int, Sendable {
        case unattached = -1
        case foregroundActive = 0
        case foregroundInactive = 1
        case background = 2
    }

    public var activationState: ActivationState {
        switch UIApplication.shared.applicationState {
        case .active: .foregroundActive
        case .inactive: .foregroundInactive
        case .background: .background
        }
    }

    public init() {}

    public nonisolated static func == (lhs: UIScene, rhs: UIScene) -> Bool { lhs === rhs }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

@MainActor
open class UIWindowScene: UIScene {
    public struct Geometry {
        public var interfaceOrientation: UIInterfaceOrientation
    }

    public let screen: UIScreen
    public var effectiveGeometry: Geometry
    /// The orientation the scene shows in (UIKit's older spelling of
    /// `effectiveGeometry.interfaceOrientation`).
    public var interfaceOrientation: UIInterfaceOrientation { effectiveGeometry.interfaceOrientation }

    /// Joins `UIApplication.shared.connectedScenes` for as long as whoever
    /// made it (the game's surface) keeps it.
    public init(screen: UIScreen, interfaceOrientation: UIInterfaceOrientation = .unknown) {
        self.screen = screen
        effectiveGeometry = Geometry(interfaceOrientation: interfaceOrientation)
        super.init()
        ConnectedScenes.add(self)
    }

    /// The scene's windows: those whose `windowScene` is this scene.
    public fileprivate(set) var windows: [UIWindow] = []

    /// The window the scene shows (Android has one).
    public var keyWindow: UIWindow? { windows.first }
}

/// What `UIImage` draws into a view; kept, not shown (see `addSubview`).
@MainActor
open class UIImageView: UIView {
    public var image: UIImage?

    public init(image: UIImage?) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: image?.size ?? .zero))
    }
}

@MainActor
open class UIWindow {
    public var bounds: CGRect
    public var safeAreaInsets: UIEdgeInsets = .zero
    /// Weak, as UIKit's: the scene holds its windows.
    public weak var windowScene: UIWindowScene? {
        didSet {
            oldValue?.windows.removeAll { $0 === self }
            if let windowScene, !windowScene.windows.contains(where: { $0 === self }) {
                windowScene.windows.append(self)
            }
        }
    }
    public var traitCollection: UITraitCollection { UITraitCollection.current }

    /// Whether this is its scene's key window.
    public var isKeyWindow: Bool { windowScene?.keyWindow === self }

    public init(bounds: CGRect) {
        self.bounds = bounds
    }

    /// Every touch event passes through here before the scene takes it
    /// (`SKScene.deliverTouch`); a window subclass may override it to note
    /// where the player touched.
    open func sendEvent(_ event: UIEvent) {
        observer?(event)
    }

    /// Hears every event that reaches the window's own `sendEvent`, after
    /// any subclass has: a game's controller may take focus back from a
    /// gamepad on a touch.
    public var observer: ((UIEvent) -> Void)?
}

/// SpriteKit's view is a UIKit one, and the game reads it as one: its
/// bounds, safe area, traits and window. `SKView` builds on this.
@preconcurrency @MainActor
open class UIView {
    public var bounds: CGRect

    /// The layer the view draws into. On Apple an `SKView`'s is a
    /// `CAMetalLayer`, which a game may ask for its drawable size; here
    /// there is no layer tree, so it is a plain one and the game falls back
    /// to `bounds` times `contentScaleFactor`, the same number.
    public let layer = CALayer()

    /// Carried: SpriteKit's view shows it only where no scene draws, and
    /// every scene here fills the view with its own colour.
    public var backgroundColor: UIColor?

    /// What system bars and cutouts cover, in points. The shell sets it.
    public var safeAreaInsets: UIEdgeInsets = .zero

    /// Points-to-pixels, as the display reports it (the shell sets the
    /// game's view's), as UIKit has it on every view.
    public var contentScaleFactor: CGFloat = 3

    /// The window the view is in; none on Android yet (see above).
    public var window: UIWindow?

    public init(frame: CGRect) {
        bounds = CGRect(origin: .zero, size: frame.size)
        origin = frame.origin
    }

    /// Where the view sits in its superview. Android shows one view, the
    /// game's, so this only keeps what is set, for code that reads it back.
    open var frame: CGRect {
        get { CGRect(origin: origin, size: bounds.size) }
        set {
            origin = newValue.origin
            bounds.size = newValue.size
        }
    }

    private var origin = CGPoint.zero

    public var isUserInteractionEnabled = true
    public var clipsToBounds = false
    public var contentMode: ContentMode = .scaleToFill
    public var autoresizingMask: AutoresizingMask = []
    public private(set) var subviews: [UIView] = []
    public private(set) weak var superview: UIView?

    public enum ContentMode: Int, Sendable {
        case scaleToFill, scaleAspectFit, scaleAspectFill, redraw, center
        case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
    }

    public struct AutoresizingMask: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let flexibleLeftMargin = AutoresizingMask(rawValue: 1 << 0)
        public static let flexibleWidth = AutoresizingMask(rawValue: 1 << 1)
        public static let flexibleRightMargin = AutoresizingMask(rawValue: 1 << 2)
        public static let flexibleTopMargin = AutoresizingMask(rawValue: 1 << 3)
        public static let flexibleHeight = AutoresizingMask(rawValue: 1 << 4)
        public static let flexibleBottomMargin = AutoresizingMask(rawValue: 1 << 5)
    }

    /// Kept, not shown: nothing composites views on Android but the game's
    /// own `SKView`, which draws through the shell.
    public func addSubview(_ view: UIView) {
        view.removeFromSuperview()
        subviews.append(view)
        view.superview = self
    }

    public func removeFromSuperview() {
        superview?.subviews.removeAll { $0 === self }
        superview = nil
    }

    /// No compositor to snapshot here: nil, as UIKit returns for a view it
    /// can't render, so callers take their own fallback.
    public func snapshotView(afterScreenUpdates afterUpdates: Bool) -> UIView? { nil }

    /// Draws nothing and says so, as UIKit does for a view not in a window.
    @discardableResult
    public func drawHierarchy(in rect: CGRect, afterScreenUpdates afterUpdates: Bool) -> Bool { false }

    /// The areas a device holds back from content (iOS 27.1: a foldable's
    /// hinge, `division`, and what covers the screen, `occlusion`). The
    /// shell sets `reservedRegionList` where Android reports them; none by
    /// default, as on a phone with neither.
    public func reservedRegions(
        kind: ReservedRegion.Kind, options: ReservedRegion.QueryOptions = []
    ) -> [ReservedRegion] {
        reservedRegionList.filter { $0.kind == kind && ($0.isActive || options.contains(.includeInactive)) }
    }

    /// Runtime seam, not UIKit API: what the shell reports.
    public var reservedRegionList: [ReservedRegion] = []

    public struct ReservedRegion: Equatable, Hashable, Identifiable {
        public struct ID: Equatable, Hashable {
            let value: Int
            public init(_ value: Int) { self.value = value }
        }

        public struct Kind: Equatable, Hashable {
            let name: String
            public static let occlusion = Kind(name: "occlusion")
            public static let division = Kind(name: "division")
        }

        public struct QueryOptions: OptionSet {
            public let rawValue: UInt
            public init(rawValue: UInt) { self.rawValue = rawValue }
            public static let includeInactive = QueryOptions(rawValue: 1 << 0)
        }

        public let id: ID
        public let kind: Kind
        public let frame: CGRect
        public let margins: UIEdgeInsets
        public let isActive: Bool

        /// Runtime seam, not UIKit API: how the shell makes one.
        public init(id: ID, kind: Kind, frame: CGRect, margins: UIEdgeInsets = .zero, isActive: Bool = true) {
            self.id = id
            self.kind = kind
            self.frame = frame
            self.margins = margins
            self.isActive = isActive
        }

        public static func == (a: ReservedRegion, b: ReservedRegion) -> Bool {
            a.id == b.id && a.kind == b.kind && a.frame == b.frame && a.margins == b.margins && a.isActive == b.isActive
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(kind)
        }
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
///
/// Presenting draws nothing: it calls the presented controller's
/// `viewDidAppear(_:)` at once, so a stand-in for a system controller (Game
/// Center's) can open the Android counterpart from there.
@preconcurrency @MainActor
open class UIViewController {
    open var view: UIView!

    public private(set) var presentedViewController: UIViewController?
    public private(set) weak var presentingViewController: UIViewController?

    public init() {}

    open func viewDidAppear(_ animated: Bool) {}

    open func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        presentedViewController = viewControllerToPresent
        viewControllerToPresent.presentingViewController = self
        viewControllerToPresent.viewDidAppear(flag)
        completion?()
    }

    /// Dismisses what this controller presented, or, presenting nothing,
    /// this controller itself, as UIKit does.
    open func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        let presenter = presentedViewController == nil ? presentingViewController : self
        presenter?.presentedViewController?.presentingViewController = nil
        presenter?.presentedViewController = nil
        completion?()
    }
}

#endif

#if SPRITEKIT_SHIM
/// Core Animation's layer, as far as the game asks after one.
open class CALayer {
    public init() {}
}

/// Named by a game's `view.layer as? CAMetalLayer`; nothing is one here.
public final class CAMetalLayer: CALayer {
    public var drawableSize = CGSize.zero
}
#endif

