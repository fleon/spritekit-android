import Foundation

/// The buttons a game reads off an extended gamepad (Xbox, PlayStation,
/// MFi; SDL's on Android).
public enum GamepadButton: CaseIterable, Sendable {
    case a, b, x, y, leftShoulder, rightShoulder, menu
}

/// How gamepads steer focus. A game passes its own to `GamepadInput`.
public struct GamepadConfiguration {
    /// How far the d-pad or stick must lean (0…1) for a way to count.
    public var stickPress: Float = 0.5
    /// How far back a stick already leaning must come to let its way go,
    /// so it doesn't flicker on the edge.
    public var stickRelease: Float = 0.3
    /// How long a way is held before it repeats.
    public var repeatDelay: TimeInterval = 0.45
    /// How often it repeats after that.
    public var repeatInterval: TimeInterval = 0.15
    /// Apple TV: how close in time the remote's press must come to a
    /// gamepad's to be the system's echo of it.
    public var echoWindow: TimeInterval = 0.1

    public init() {}
}

/// The gamepads connected and the way they steer, whatever reads them
/// (GameController on Apple, the shell's events on Android): the d-pad or
/// the left stick points a way, the pad that last pointed one holds it, and
/// a held way repeats; each button sends one press as it goes down.
final class GamepadPads {
    enum Event: Equatable {
        case move(FocusNavigator.Direction)
        case press(GamepadButton)
    }

    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    var configuration: GamepadConfiguration
    var emit: ((Event) -> Void)?
    /// A way was first held (not its repeats), just before its move.
    var onHold: ((FocusNavigator.Direction) -> Void)?
    /// The last pad was disconnected.
    var onDisconnectAll: (() -> Void)?

    private let schedule: Schedule
    private var pads: [AnyHashable: Pad] = [:]
    /// The way held, by the pad that last pointed one, and a count of holds
    /// so a repeat from an earlier one stops.
    private var held: FocusNavigator.Direction?
    private weak var steering: Pad?
    private var hold = 0

    init(configuration: GamepadConfiguration, schedule: @escaping Schedule) {
        self.configuration = configuration
        self.schedule = schedule
    }

    var isConnected: Bool { !pads.isEmpty }

    func contains(_ id: AnyHashable) -> Bool { pads[id] != nil }

    /// Returns whether the pad is new.
    @discardableResult
    func connect(_ id: AnyHashable) -> Bool {
        guard pads[id] == nil else { return false }
        pads[id] = Pad()
        return true
    }

    func disconnect(_ id: AnyHashable) {
        guard let pad = pads.removeValue(forKey: id) else { return }
        if pad === steering { setHeld(nil) }
        if pads.isEmpty { onDisconnectAll?() }
    }

    func dpad(_ id: AnyHashable, x: Float, y: Float) {
        guard let pad = pads[id] else { return }
        pad.dpad = Self.direction(x, y, past: configuration.stickPress)
        steer(by: pad)
    }

    func stick(_ id: AnyHashable, x: Float, y: Float) {
        guard let pad = pads[id] else { return }
        let threshold = pad.stick == nil ? configuration.stickPress : configuration.stickRelease
        pad.stick = Self.direction(x, y, past: threshold)
        steer(by: pad)
    }

    func button(_ id: AnyHashable, _ button: GamepadButton, pressed: Bool) {
        guard let pad = pads[id] else { return }
        if pressed {
            guard pad.pressed.insert(button).inserted else { return }
            emit?(.press(button))
        } else {
            pad.pressed.remove(button)
        }
    }

    /// Whether any pad points `direction` now.
    func holds(_ direction: FocusNavigator.Direction) -> Bool {
        pads.values.contains { $0.dpad == direction || $0.stick == direction }
    }

    /// Whether any pad holds `button` down now.
    func holds(_ button: GamepadButton) -> Bool {
        pads.values.contains { $0.pressed.contains(button) }
    }

    /// The way `x`, `y` point once past `threshold` (the farther axis wins).
    static func direction(_ x: Float, _ y: Float, past threshold: Float) -> FocusNavigator.Direction? {
        guard max(abs(x), abs(y)) > threshold else { return nil }
        if abs(x) > abs(y) { return x > 0 ? .right : .left }
        return y > 0 ? .up : .down
    }

    /// Another pad letting go leaves the hold to the one that made it.
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
        onHold?(direction)
        emit?(.move(direction))
        repeatMove(hold, after: configuration.repeatDelay)
    }

    private func repeatMove(_ hold: Int, after delay: TimeInterval) {
        schedule(delay) { [weak self] in
            guard let self, hold == self.hold, let held = self.held else { return }
            emit?(.move(held))
            repeatMove(hold, after: configuration.repeatInterval)
        }
    }

    /// A connected gamepad: the ways its d-pad and stick point, and the
    /// buttons it holds down.
    private final class Pad {
        var dpad: FocusNavigator.Direction?
        var stick: FocusNavigator.Direction?
        var pressed: Set<GamepadButton> = []
    }
}

/// `-GamepadScript`-style steps a game plays on a pretend gamepad, since a
/// simulator or emulator can't be sent a real one's presses: `up`, `down`,
/// `left`, `right` (the d-pad), `stickup`… (the left stick), `a`, `b`, `x`,
/// `y`, `lb`, `rb` or `menu`, each held `pressDuration` or as long as a
/// `:seconds` suffix says (`down:2`); `connect` and `disconnect` come and
/// go. Anything else (`wait`) is a beat with nothing in it.
public enum GamepadScript {
    public enum Control: Equatable, Sendable {
        case dpad(FocusNavigator.Direction)
        case stick(FocusNavigator.Direction)
        case button(GamepadButton)
    }

    public enum Step: Equatable, Sendable {
        case connect
        case disconnect
        case press(Control, seconds: TimeInterval)
    }

    /// Each step's meaning, nil for a beat with nothing in it.
    public static func parse(_ steps: [String], pressDuration: TimeInterval) -> [Step?] {
        steps.map { step in
            let parts = step.split(separator: ":")
            let name = parts.first.map { String($0).lowercased() } ?? ""
            let seconds = parts.count > 1 ? Double(parts[1]) ?? 0 : pressDuration
            switch name {
            case "connect": return .connect
            case "disconnect": return .disconnect
            default: return control(named: name).map { .press($0, seconds: seconds) }
            }
        }
    }

    static func control(named name: String) -> Control? {
        if let way = ways[name] { return .dpad(way) }
        if name.hasPrefix("stick"), let way = ways[String(name.dropFirst("stick".count))] { return .stick(way) }
        return buttons[name].map(Control.button)
    }

    /// A way as an axis pair, x right and y up.
    static func axes(_ direction: FocusNavigator.Direction) -> (x: Float, y: Float) {
        switch direction {
        case .up: return (0, 1)
        case .down: return (0, -1)
        case .left: return (-1, 0)
        case .right: return (1, 0)
        }
    }

    private static let ways: [String: FocusNavigator.Direction] = ["up": .up, "down": .down, "left": .left, "right": .right]
    private static let buttons: [String: GamepadButton] = [
        "a": .a, "b": .b, "x": .x, "y": .y, "lb": .leftShoulder, "rb": .rightShoulder, "menu": .menu,
    ]
}
