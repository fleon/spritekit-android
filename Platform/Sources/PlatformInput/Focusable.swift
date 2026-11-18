import Foundation
import PlatformCore
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
#endif

/// A control the Apple TV remote, gamepads and the Mac's pointer can rest
/// on (`SceneControls`); it shows when it has focus, each its own way.
public protocol Focusable: SKNode {
    /// Where it sits, in its own space.
    var focusFrame: CGRect { get }
    /// Whether it takes focus now (a disabled button doesn't).
    var canFocus: Bool { get }
    func setFocused(_ focused: Bool)
    /// Presses it. Returns whether it took the press.
    func activate() -> Bool
}

/// A focused control that takes some of the remote's moves itself (a list's
/// scroll arrow scrolls instead of letting focus go).
public protocol FocusSteering: Focusable {
    /// Returns whether it took the move; if not, focus moves on.
    func steer(_ direction: FocusNavigator.Direction) -> Bool
}

/// Scenes and popups that say which control focus starts on.
public protocol FocusDefaulting: AnyObject {
    var defaultFocus: SKNode? { get }
}

/// A popup over the scene (a direct child of it): while one is open, focus
/// and the pointer stay among its controls. The topmost by `zPosition`
/// that isn't on its way out wins.
public protocol FocusOverlay: SKNode {
    var isDismissing: Bool { get }
}

/// A list that scrolls its controls: those out of its view still take
/// focus from the remote and gamepads, which scroll them in, but not from
/// the pointer.
public protocol FocusScrollArea: SKNode {
    /// What it shows, in its own space.
    var focusViewport: CGRect { get }
    /// Scrolls `control` into view, if it scrolls with the list (not, say,
    /// the list's own arrows, which stand over it).
    func revealFocused(_ control: SKNode)
}

/// How focus finds and moves between controls, and how a focus ring
/// fades. A game sets `FocusNavigator.configuration` at launch.
public struct FocusConfiguration {
    /// How often focus and the pointer check the controls again as they
    /// come and go.
    public var refreshInterval: TimeInterval = 0.2
    /// How far (in view points) a control's centre must lie the way focus
    /// moves to count as that way.
    public var directionSlop: CGFloat = 1
    /// How much distance off to the side counts against a control, against
    /// distance ahead.
    public var asideWeight: CGFloat = 2
    /// How much a centre's distance from straight ahead counts (which
    /// settles a tie between controls that both overlap).
    public var centreWeight: CGFloat = 0.25
    /// Controls whose centres lie within this of a row's first (in view
    /// points) join its row.
    public var rowTolerance: CGFloat = 16
    /// Nodes fainter than this hold no controls.
    public var minAlpha: CGFloat = 0.05
    /// A focus ring's fade in or out (`fadeFocusRing`).
    public var ringFadeDuration: TimeInterval = 0.15
    /// One glow of a focus ring that stays, dimmer and back.
    public var ringPulseDuration: TimeInterval = 1.4
    /// How dim a staying ring glows down to.
    public var ringPulseDimAlpha: CGFloat = 0.55

    public init() {}
}

extension SKNode {
    /// Fades a focus ring in, glowing brighter and dimmer while it stays,
    /// or out.
    public func fadeFocusRing(_ focused: Bool, withKey key: String) {
        let configuration = FocusNavigator.configuration
        removeAction(forKey: key)
        let fade = SKAction.fadeAlpha(to: focused ? 1 : 0, duration: configuration.ringFadeDuration)
        guard focused else {
            run(fade, withKey: key)
            return
        }
        let dim = configuration.ringPulseDimAlpha
        let pulse = SKAction.pingPong(duration: configuration.ringPulseDuration) { node, progress in
            node.alpha = progress.lerp(1, dim)
        }
        run(.sequence([fade, pulse]), withKey: key)
    }
}
