import Foundation
import Macros
import PlatformCore
import SpriteKitShim

/// How a press is tracked and shown by default. A game sets
/// `PressableNode.configuration` at launch.
public struct PressConfiguration {
    /// How far (in the control's points) a touch may stray outside its hit
    /// frame and still count as on it.
    public var touchSlop: CGFloat = 0
    /// The default pressed look: the control shrinks to this scale.
    public var pressedScale: CGFloat = 0.95
    /// How long the default pressed look takes to go down or come back.
    public var pressDuration: TimeInterval = 0.1
    /// How long a press without a touch (the remote, a gamepad, a key)
    /// shows before it lets go.
    public var flashDuration: TimeInterval = 0.2
    /// The default disabled look: the control fades to this alpha.
    public var disabledAlpha: CGFloat = 0.4
    /// How long the default disabled fade takes.
    public var disabledFadeDuration: TimeInterval = 0.2

    public init() {}
}

/// What pressed a control: a touch (where it let go, or landed for a
/// control that acts on touch down, in the control's own space), or the
/// remote, a gamepad or a key (`activate`).
public enum PressSource: Equatable, Sendable {
    case touch(CGPoint)
    case activation
}

/// A tap followed from touch down to touch up: it presses while the finger
/// is on the control, lets go while it strays off, and fires as it lifts on
/// it (or as it lands, for `.touchDown`). Whoever holds it says whether
/// each point is on the control; `PressableNode` holds one, and a control
/// that can't subclass it (a sprite, or one fed by a game's own touch
/// dispatch) may hold its own.
public nonisolated struct PressTracker: Sendable {
    public enum Trigger: Sendable {
        /// Fires when the touch lifts on the control, as a button does.
        case release
        /// Fires as the touch lands on it.
        case touchDown
    }

    /// What a touch changed: the press showing (`true`) or letting go
    /// (`false`), and whether the control fires now.
    public struct Step: Equatable, Sendable {
        public var pressed: Bool?
        public var fires: Bool

        public init(pressed: Bool? = nil, fires: Bool = false) {
            self.pressed = pressed
            self.fires = fires
        }
    }

    public var trigger: Trigger
    /// A touch that landed on the control is down.
    public private(set) var isTracking = false
    /// That touch is on the control now.
    public private(set) var isPressed = false

    public init(trigger: Trigger = .release) {
        self.trigger = trigger
    }

    /// A touch lands; one that lands off the control is never followed.
    public mutating func began(inside: Bool) -> Step {
        guard !isTracking, inside else { return Step() }
        isTracking = true
        isPressed = true
        return Step(pressed: true, fires: trigger == .touchDown)
    }

    public mutating func moved(inside: Bool) -> Step {
        guard isTracking, inside != isPressed else { return Step() }
        isPressed = inside
        return Step(pressed: inside)
    }

    public mutating func ended(inside: Bool) -> Step {
        guard isTracking else { return Step() }
        let fires = trigger == .release && isPressed && inside
        let wasPressed = isPressed
        isTracking = false
        isPressed = false
        return Step(pressed: wasPressed ? false : nil, fires: fires)
    }

    /// The system took the touch away, or the control stopped taking them.
    public mutating func cancelled() -> Step {
        guard isTracking else { return Step() }
        let wasPressed = isPressed
        isTracking = false
        isPressed = false
        return Step(pressed: wasPressed ? false : nil)
    }
}

/// A control a touch, the Apple TV remote, a gamepad or the Mac's pointer
/// presses: it follows one touch at a time (`PressTracker`), shows the
/// press, fades while disabled, takes focus (`Focusable`) and fires
/// `onTap`. Its look is the subclass's: it draws itself and overrides the
/// `show…` hooks (by default the press shrinks `pressScaleNode` and a
/// disabled control fades), and sounds and haptics go in `playFeedback` or
/// `PressableNode.feedback`.
@NSCodingUnsupported
open class PressableNode: SKNode, Focusable {
    /// The defaults every control starts with. Set it at launch.
    public static var configuration = PressConfiguration()
    /// Plays a game's press sound and haptic for every control that doesn't
    /// override `playFeedback`. Set it at launch.
    public static var feedback: ((PressableNode, PressSource) -> Void)?

    /// Runs when the control fires (unless a subclass overrides `perform`).
    public var onTap: (() -> Void)?
    /// Runs as the remote's or a gamepad's focus arrives (the Mac's pointer
    /// only shows focus, so it never runs this).
    public var onFocus: (() -> Void)?
    /// How far a touch may stray off `hitFrame` and still count.
    public var touchSlop = PressableNode.configuration.touchSlop
    /// Whether it fires as the touch lifts (the default) or as it lands.
    public var trigger: PressTracker.Trigger {
        get { tracker.trigger }
        set { tracker.trigger = newValue }
    }

    /// A disabled control still takes its touches (so they don't fall
    /// through to what's beneath) but never presses, fires or takes focus.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { cancelPress() }
            showEnabled(isEnabled, animated: scene?.view != nil)
        }
    }

    /// A touch is down on it now.
    public var isPressed: Bool { tracker.isPressed }
    /// The remote, a gamepad or the Mac's pointer rests on it.
    public private(set) var isFocused = false
    /// A ring (or any node) the default `showFocused` fades in and out with
    /// `fadeFocusRing`; the subclass draws it and adds it where it likes.
    public var focusRing: SKNode? {
        didSet { focusRing?.alpha = isFocused ? 1 : 0 }
    }

    private var tracker = PressTracker()
    private var touch: UITouch?

    private enum ActionKey {
        static let press = "pressable.press"
        static let flash = "pressable.flash"
        static let enabled = "pressable.enabled"
        static let focus = "pressable.focus"
    }

    public override init() {
        super.init()
        isUserInteractionEnabled = true
    }

    // MARK: Hooks for the subclass

    /// Where a touch counts as on the control, in its own space. By default
    /// everything its children draw.
    open var hitFrame: CGRect {
        let frames = children.map { $0.calculateAccumulatedFrame() }
        guard let first = frames.first else { return .zero }
        let minX = frames.reduce(first.minX) { min($0, $1.minX) }
        let minY = frames.reduce(first.minY) { min($0, $1.minY) }
        let maxX = frames.reduce(first.maxX) { max($0, $1.maxX) }
        let maxY = frames.reduce(first.maxY) { max($0, $1.maxY) }
        return rect(minX, minY, maxX - minX, maxY - minY)
    }

    /// Whether `point` (in its own space) is on the control: in `hitFrame`
    /// grown by `touchSlop`. A round control overrides it.
    open func isInside(_ point: CGPoint) -> Bool {
        hitFrame.insetBy(dx: -touchSlop, dy: -touchSlop).contains(point)
    }

    /// What the default pressed look shrinks: the whole control, unless a
    /// subclass names a part (its face, a switch's knob).
    open var pressScaleNode: SKNode { self }

    /// Shows the press or lets it go. By default `pressScaleNode` eases to
    /// `PressConfiguration.pressedScale` and back to 1.
    open func showPressed(_ pressed: Bool) {
        let configuration = Self.configuration
        let node = pressScaleNode
        let action = SKAction.scale(to: pressed ? configuration.pressedScale : 1, duration: configuration.pressDuration)
        action.timingMode = .easeOut
        node.removeAction(forKey: ActionKey.press)
        node.run(action, withKey: ActionKey.press)
    }

    /// Shows the control enabled or disabled; `animated` is false while it
    /// isn't in a view (a scene still loading). By default it fades to
    /// `PressConfiguration.disabledAlpha`.
    open func showEnabled(_ enabled: Bool, animated: Bool) {
        let configuration = Self.configuration
        let target = enabled ? 1 : configuration.disabledAlpha
        removeAction(forKey: ActionKey.enabled)
        guard animated else {
            alpha = target
            return
        }
        let fade = SKAction.fadeAlpha(to: target, duration: configuration.disabledFadeDuration)
        fade.timingMode = .easeInEaseOut
        run(fade, withKey: ActionKey.enabled)
    }

    /// Shows focus arriving or leaving. By default `focusRing` fades.
    open func showFocused(_ focused: Bool) {
        focusRing?.fadeFocusRing(focused, withKey: ActionKey.focus)
    }

    /// Plays the press's sound and haptic, just before it fires. By default
    /// `PressableNode.feedback`.
    open func playFeedback(_ source: PressSource) {
        Self.feedback?(self, source)
    }

    /// What firing does. By default `onTap`; a switch flips here, a
    /// segmented control reads where the touch let go.
    open func perform(_ source: PressSource) {
        onTap?()
    }

    // MARK: Touches

    open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard self.touch == nil, let touch = touches.first else { return }
        self.touch = touch
        pressBegan(at: touch.location(in: self))
        // A touch that landed off the control isn't followed.
        if !tracker.isTracking { self.touch = nil }
    }

    open override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        pressMoved(to: touch.location(in: self))
    }

    open override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        pressEnded(at: touch.location(in: self))
    }

    open override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        cancelPress()
    }

    /// A touch lands at `point` (in its own space). The touch handlers call
    /// these; a game that hands out touches its own way may too.
    public func pressBegan(at point: CGPoint) {
        guard isEnabled else { return }
        apply(tracker.began(inside: isInside(point)), at: point)
    }

    public func pressMoved(to point: CGPoint) {
        apply(tracker.moved(inside: isInside(point)), at: point)
    }

    public func pressEnded(at point: CGPoint) {
        apply(tracker.ended(inside: isInside(point)), at: point)
    }

    /// Lets go of a press without firing.
    public func cancelPress() {
        touch = nil
        apply(tracker.cancelled(), at: nil)
    }

    private func apply(_ step: PressTracker.Step, at point: CGPoint?) {
        if let pressed = step.pressed { showPressed(pressed) }
        guard step.fires, isEnabled, let point else { return }
        fire(.touch(point))
    }

    private func fire(_ source: PressSource) {
        playFeedback(source)
        perform(source)
    }

    /// Shows a press and lets it go, without a touch (a key, a demo).
    public func flashPress() {
        TouchOrigin.record(self)
        removeAction(forKey: ActionKey.flash)
        showPressed(true)
        run(.sequence([
            .wait(forDuration: Self.configuration.flashDuration),
            .run { [weak self] in
                guard let self, !tracker.isPressed else { return }
                showPressed(false)
            },
        ]), withKey: ActionKey.flash)
    }

    // MARK: Focusable

    /// Where focus finds it: `hitFrame`, without the slop.
    open var focusFrame: CGRect { hitFrame }

    open var canFocus: Bool { isEnabled }

    open func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        showFocused(focused)
        if focused, FocusNavigator.isDriving { onFocus?() }
    }

    /// The remote's click, a gamepad's A or a key presses it like a tap.
    open func activate() -> Bool {
        guard isEnabled, canFocus else { return false }
        flashPress()
        fire(.activation)
        return true
    }
}
