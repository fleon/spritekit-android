import Foundation
import PlatformCore
import SpriteKitShim

/// Moves focus between a scene's controls (`SceneControls`) for the Apple
/// TV remote and gamepads (`GamepadInput`): a swipe, a press on the
/// clickpad's edge or the d-pad moves it to the nearest control that way,
/// a click presses the focused one. Focus starts where the scene or popup
/// on top says (`FocusDefaulting`), else on its first control; a popup's
/// controls take it while the popup is open, and it comes back where it was
/// once it closes. Apple TV's always runs; elsewhere one runs while a
/// gamepad drives focus, until touch or the pointer take over (`stop`;
/// `FocusDriver` does this).
public final class FocusNavigator {
    public enum Direction: Sendable {
        case up, down, left, right
    }

    /// How focus finds and moves between controls. Set it at launch.
    public static var configuration = FocusConfiguration()

    /// Whether the remote or a gamepad moves focus now: focus arriving then
    /// may select as it passes, which the Mac's pointer never does.
    public private(set) static var isDriving = false

    private weak var view: SKView?
    private weak var focused: SKNode?
    /// A control a scene asked focus to move to (`request`).
    private static weak var requested: SKNode?
    /// What focus is among: the popup on top, or the scene.
    private weak var context: SKNode?
    /// The scene's control focus left for a popup, to come back to.
    private weak var sceneFocus: SKNode?
    /// Focus took a stand-in while the context's own default wasn't on
    /// screen yet (a control still growing in); it moves there once it is,
    /// unless the player moved it first.
    private var isStandIn = false
    private var timer: Timer?

    public init(view: SKView) {
        self.view = view
        Self.isDriving = true
        // Controls come and go with scenes, popups and pages; focus follows.
        timer = Timer.scheduledTimer(withTimeInterval: Self.configuration.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    /// The control focus rests on, if any.
    public var focusedControl: SKNode? { focused }

    /// Hands focus back to touch or the pointer: nothing shows it any more.
    public func stop() {
        timer?.invalidate()
        timer = nil
        setFocused(nil)
        Self.isDriving = false
    }

    /// Asks focus to move to `node`, if it's on screen by the next check.
    /// Without a remote or gamepad driving focus nothing happens.
    public static func request(_ node: SKNode?) {
        requested = node
    }

    /// Moves focus to the nearest control in `direction`. Returns whether it moved.
    @discardableResult
    public func move(_ direction: Direction) -> Bool {
        let controls = refresh()
        guard let current = controls.first(where: { $0.node === focused }) else { return false }
        if (current.node as? any FocusSteering)?.steer(direction) == true { return true }
        let others = controls.filter { $0.node !== current.node }
        guard let index = Self.nearest(from: current.frame, among: others.map(\.frame), direction) else { return false }
        isStandIn = false
        focus(others[index])
        return true
    }

    /// The index of the frame in `frames` that focus moving `direction`
    /// from `from` lands on, if any lies that way. Frames are in view
    /// coordinates, y growing downwards.
    public static func nearest(from: CGRect, among frames: [CGRect], _ direction: Direction) -> Int? {
        let configuration = configuration
        var best: (index: Int, score: CGFloat)?
        for (index, to) in frames.enumerated() {
            // How far it lies that way (edge to edge), how far off to the
            // side, and how far its centre is from straight ahead.
            let ahead: CGFloat
            let aside: CGFloat
            let offCentre: CGFloat
            switch direction {
            case .left, .right:
                let sign: CGFloat = direction == .right ? 1 : -1
                guard (to.midX - from.midX) * sign > configuration.directionSlop else { continue }
                ahead = max(0, sign > 0 ? to.minX - from.maxX : from.minX - to.maxX)
                aside = max(0, max(to.minY - from.maxY, from.minY - to.maxY))
                offCentre = abs(to.midY - from.midY)
            case .up, .down:
                let sign: CGFloat = direction == .down ? 1 : -1
                guard (to.midY - from.midY) * sign > configuration.directionSlop else { continue }
                ahead = max(0, sign > 0 ? to.minY - from.maxY : from.minY - to.maxY)
                aside = max(0, max(to.minX - from.maxX, from.minX - to.maxX))
                offCentre = abs(to.midX - from.midX)
            }
            let score = ahead + aside * configuration.asideWeight + offCentre * configuration.centreWeight
            if best == nil || score < best?.score ?? 0 { best = (index, score) }
        }
        return best?.index
    }

    /// Presses the focused control. Returns whether one took the press.
    @discardableResult
    public func select() -> Bool {
        refresh()
        guard let focused = focused as? any Focusable else { return false }
        return focused.activate()
    }

    /// Keeps focus on a control that's on screen: in a popup that just
    /// opened, back where it was when one closed, or on the default when its
    /// control went away.
    @discardableResult
    public func refresh() -> [SceneControls.Control] {
        guard let view, let scene = view.scene else { return [] }
        let controls = SceneControls.collect(in: scene, bounds: view.bounds).filter { ($0.node as? any Focusable)?.canFocus == true }
        let context: SKNode = SceneControls.topOverlay(in: scene) ?? scene
        var returning: SKNode?
        if context !== self.context {
            if self.context?.scene !== scene {
                sceneFocus = nil
            } else if self.context === scene {
                sceneFocus = focused
            }
            self.context = context
            returning = context === scene ? sceneFocus : nil
        } else if let requested = Self.requested, let control = controls.first(where: { $0.node === requested }) {
            Self.requested = nil
            isStandIn = false
            focus(control)
            return controls
        } else if controls.contains(where: { $0.node === focused }) {
            if isStandIn, let preferred = preferredControl(in: context, among: controls) {
                isStandIn = false
                focus(preferred)
            }
            return controls
        }
        if let returning = controls.first(where: { $0.node === returning }) {
            isStandIn = false
            focus(returning)
        } else if let preferred = preferredControl(in: context, among: controls) {
            isStandIn = false
            focus(preferred)
        } else if let first = controls.first {
            isStandIn = (context as? any FocusDefaulting)?.defaultFocus != nil
            focus(first)
        } else {
            setFocused(nil)
        }
        return controls
    }

    /// The control the scene or popup says focus starts on, if it's on screen.
    private func preferredControl(in context: SKNode, among controls: [SceneControls.Control]) -> SceneControls.Control? {
        guard let preferred = (context as? any FocusDefaulting)?.defaultFocus else { return nil }
        return controls.first { $0.node === preferred }
    }

    private func focus(_ control: SceneControls.Control) {
        setFocused(control.node)
        // A control scrolled out of its list's view comes into it.
        control.scrollArea?.revealFocused(control.node)
    }

    private func setFocused(_ node: SKNode?) {
        guard node !== focused else { return }
        (focused as? any Focusable)?.setFocused(false)
        focused = node
        (node as? any Focusable)?.setFocused(true)
    }
}
