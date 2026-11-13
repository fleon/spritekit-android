import UIKit

/// Android's counterpart of `Source/Utils/GamepadInput.swift`, which cannot
/// compile here: it hears gamepads come and go through
/// `NotificationCenter.addObserver(_:selector:…)`, and `#selector` needs the
/// Objective-C runtime. Everything else is that file's: the same `Action`s,
/// the same mapping (A presses, B goes back, X or the left shoulder undoes,
/// Y restarts, the right shoulder hints, Menu toggles the settings), the d-pad
/// or the left stick moving focus with the stick's press and release
/// thresholds, a held way repeating, and the last pad going telling the
/// controller. Its input is SDL's gamepads (`GamepadEvents`, posted by the
/// shell) rather than GameController's. Keep the two in step.
///
/// Left out, as Apple TV's alone: the remote's echoes (`menuArrived`,
/// `isEcho`). And for now `-VirtualGamepad` and `-GamepadScript`, which drive
/// a simulator.
final class GamepadInput {
    enum Action: Equatable {
        case move(FocusNavigator.Direction)
        case select, back, undo, restart, hint, menu
    }

    /// Whether a gamepad is connected.
    private(set) static var isConnected = false

    var onAction: ((Action) -> Void)?
    /// The last gamepad was disconnected.
    var onDisconnectAll: (() -> Void)?

    private var pads: [UInt32: Pad] = [:]
    private var held: FocusNavigator.Direction?
    private weak var steering: Pad?
    private var hold = 0

    init() {
        GamepadEvents.sink = { [weak self] in self?.receive($0) }
        for id in GamepadEvents.connected.sorted() { receive(.connected(id: id)) }
    }

    private func receive(_ event: GamepadEvent) {
        switch event {
        case let .connected(id):
            guard pads[id] == nil else { return }
            pads[id] = Pad()
            Self.isConnected = true
        case let .disconnected(id):
            guard let pad = pads.removeValue(forKey: id) else { return }
            if pad === steering { setHeld(nil) }
            Self.isConnected = !pads.isEmpty
            if pads.isEmpty { onDisconnectAll?() }
        case let .dpad(id, x, y):
            guard let pad = pads[id] else { return }
            pad.dpad = Self.direction(x, y, past: DesignSystem.gamepadStickPress)
            steer(by: pad)
        case let .stick(id, x, y):
            guard let pad = pads[id] else { return }
            let threshold = pad.stick == nil ? DesignSystem.gamepadStickPress : DesignSystem.gamepadStickRelease
            pad.stick = Self.direction(x, y, past: threshold)
            steer(by: pad)
        case let .button(id, button, pressed):
            guard pads[id] != nil, pressed else { return }
            onAction?(Self.action(of: button))
        }
    }

    /// The way `x`, `y` point once past `threshold` (the farther axis wins).
    private static func direction(_ x: Float, _ y: Float, past threshold: Float) -> FocusNavigator.Direction? {
        guard max(abs(x), abs(y)) > threshold else { return nil }
        if abs(x) > abs(y) { return x > 0 ? .right : .left }
        return y > 0 ? .up : .down
    }

    private func steer(by pad: Pad) {
        let direction = pad.dpad ?? pad.stick
        guard pad === steering || direction != nil else { return }
        steering = pad
        setHeld(direction)
    }

    private func setHeld(_ direction: FocusNavigator.Direction?) {
        guard direction != held else { return }
        held = direction
        hold += 1
        guard let direction else { return }
        onAction?(.move(direction))
        repeatMove(hold, after: DesignSystem.gamepadRepeatDelay)
    }

    private func repeatMove(_ hold: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, hold == self.hold, let held = self.held else { return }
            onAction?(.move(held))
            repeatMove(hold, after: DesignSystem.gamepadRepeatInterval)
        }
    }

    private static func action(of button: GamepadEvent.Button) -> Action {
        switch button {
        case .a: return .select
        case .b: return .back
        case .x, .leftShoulder: return .undo
        case .y: return .restart
        case .rightShoulder: return .hint
        case .menu: return .menu
        }
    }

    private final class Pad {
        var dpad: FocusNavigator.Direction?
        var stick: FocusNavigator.Direction?
    }
}
