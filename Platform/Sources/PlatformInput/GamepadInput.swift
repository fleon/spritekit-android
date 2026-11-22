import Foundation
import PlatformCore
import SpriteKitShim
#if !SPRITEKIT_SHIM
import GameController
#endif

/// Plays a game with a gamepad (Xbox, PlayStation or MFi: GameController's
/// extended profile on Apple; SDL's gamepads on Android, through the
/// shell's `GamepadEvents`), through the focus the Apple TV remote moves
/// (`FocusNavigator`, `FocusDriver`): the d-pad or left stick moves it
/// (held, again and again), and each button sends a press, which the game
/// maps (A presses and B goes back, by convention). Gamepads come and go
/// at any time. On Apple the Siri Remote, a gamepad to GameController too,
/// keeps its own way in (UIKit's presses and swipes), so only extended
/// gamepads are read here; Apple TV also turns a gamepad's presses into the
/// remote's, which `routeRemotePress` tells apart.
public final class GamepadInput {
    public enum Action: Equatable, Sendable {
        case move(FocusNavigator.Direction)
        case press(GamepadButton)
    }

    /// Whether a gamepad is connected.
    public private(set) static var isConnected = false

    public var onAction: ((Action) -> Void)?
    /// The last gamepad was disconnected.
    public var onDisconnectAll: (() -> Void)?

    private let pads: GamepadPads
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    #if SPRITEKIT_SHIM
    /// The pretend pad's id, past any SDL hands out.
    private static let scriptedPad = UInt32.max
    #else
    private let observers = ObserverBag()
    /// The controllers read, by the ids their pads go by.
    private var controllers: [ObjectIdentifier: GCController] = [:]
    #if os(tvOS)
    /// When the remote's Menu press last arrived, and when a gamepad last
    /// sent each press Apple TV echoes.
    private var menuArrival = -TimeInterval.infinity
    private var sent: [UIPress.PressType: TimeInterval] = [:]
    #endif
    #if os(iOS) && !targetEnvironment(macCatalyst)
    private var virtualGamepad: GCVirtualController?
    #endif
    #endif

    /// `schedule` runs work on the main thread after a delay (held ways
    /// repeating, Apple TV's echo window); tests pass their own clock.
    public init(
        configuration: GamepadConfiguration = GamepadConfiguration(),
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        }
    ) {
        self.schedule = schedule
        pads = GamepadPads(configuration: configuration, schedule: schedule)
        pads.emit = { [weak self] in self?.emit($0) }
        #if os(tvOS)
        // Only a way's first move, not its repeats: while it's held,
        // `isEcho` sees the hold itself.
        pads.onHold = { [weak self] in self?.sent[$0.press] = CACurrentMediaTime() }
        #endif
        pads.onDisconnectAll = { [weak self] in
            self?.updateConnected()
            self?.onDisconnectAll?()
        }
        #if SPRITEKIT_SHIM
        GamepadEvents.sink = { [weak self] in self?.receive($0) }
        for id in GamepadEvents.connected.sorted() { receive(.connected(id: id)) }
        #else
        observers.observe(.GCControllerDidConnect, queue: .main) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            MainActor.assumeIsolated { self?.attach(controller) }
        }
        observers.observe(.GCControllerDidDisconnect, queue: .main) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            MainActor.assumeIsolated { self?.detach(controller) }
        }
        GCController.controllers().forEach(attach)
        #endif
    }

    private func emit(_ event: GamepadPads.Event) {
        switch event {
        case .move(let direction):
            onAction?(.move(direction))
        case .press(let button):
            #if os(tvOS)
            let now = CACurrentMediaTime()
            if let echo = button.echo { sent[echo] = now }
            if button.echo == .menu {
                // Apple TV takes it for the remote's Menu first (the way
                // back, and from the first screen out of the game): it goes
                // that way alone.
                let window = pads.configuration.echoWindow
                schedule(window) { [weak self] in
                    guard let self, abs(menuArrival - now) >= window else { return }
                    onAction?(.press(button))
                }
                return
            }
            #endif
            onAction?(.press(button))
        }
    }

    private func updateConnected() {
        Self.isConnected = pads.isConnected
    }

    // MARK: Android

    #if SPRITEKIT_SHIM
    private func receive(_ event: GamepadEvent) {
        switch event {
        case let .connected(id):
            pads.connect(id)
            updateConnected()
        case let .disconnected(id):
            pads.disconnect(id)
            updateConnected()
        case let .dpad(id, x, y):
            pads.dpad(id, x: x, y: y)
        case let .stick(id, x, y):
            pads.stick(id, x: x, y: y)
        case let .button(id, button, pressed):
            pads.button(id, Self.button(button), pressed: pressed)
        }
    }

    private static func button(_ button: GamepadEvent.Button) -> GamepadButton {
        switch button {
        case .a: return .a
        case .b: return .b
        case .x: return .x
        case .y: return .y
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .menu: return .menu
        }
    }

    /// Plays `steps` (`GamepadScript`) on a pretend pad, connected as the
    /// script starts, one step every `interval` after `delay`.
    public func playScript(_ steps: [String], delay: TimeInterval, interval: TimeInterval, pressDuration: TimeInterval) {
        let script = GamepadScript.parse(steps, pressDuration: pressDuration)
        guard !script.isEmpty else { return }
        let pad = Self.scriptedPad
        receive(.connected(id: pad))
        for (index, step) in script.enumerated() {
            guard let step else { continue }
            schedule(delay + interval * Double(index)) { [weak self] in
                guard let self else { return }
                switch step {
                case .connect: receive(.connected(id: pad))
                case .disconnect: receive(.disconnected(id: pad))
                case let .press(control, seconds):
                    receive(Self.event(control, pad: pad, pressed: true))
                    schedule(seconds) { [weak self] in self?.receive(Self.event(control, pad: pad, pressed: false)) }
                }
            }
        }
    }

    private static func event(_ control: GamepadScript.Control, pad: UInt32, pressed: Bool) -> GamepadEvent {
        switch control {
        case .dpad(let way):
            let axes = GamepadScript.axes(way)
            return .dpad(id: pad, x: pressed ? axes.x : 0, y: pressed ? axes.y : 0)
        case .stick(let way):
            let axes = GamepadScript.axes(way)
            return .stick(id: pad, x: pressed ? axes.x : 0, y: pressed ? axes.y : 0)
        case .button(let button):
            let shell: GamepadEvent.Button = switch button {
            case .a: .a
            case .b: .b
            case .x: .x
            case .y: .y
            case .leftShoulder: .leftShoulder
            case .rightShoulder: .rightShoulder
            case .menu: .menu
            }
            return .button(id: pad, shell, pressed: pressed)
        }
    }
    #endif

    // MARK: Apple

    #if !SPRITEKIT_SHIM
    private func attach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard let gamepad = controller.extendedGamepad, !pads.contains(id) else { return }
        pads.connect(id)
        controllers[id] = controller
        updateConnected()
        gamepad.dpad.valueChangedHandler = { [weak self] _, x, y in
            self?.pads.dpad(id, x: x, y: y)
        }
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.pads.stick(id, x: x, y: y)
        }
        for button in GamepadButton.allCases {
            button.input(of: gamepad).pressedChangedHandler = { [weak self] _, _, pressed in
                self?.pads.button(id, button, pressed: pressed)
            }
        }
    }

    private func detach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard let controller = controllers.removeValue(forKey: id) else { return }
        if let gamepad = controller.extendedGamepad {
            gamepad.dpad.valueChangedHandler = nil
            gamepad.leftThumbstick.valueChangedHandler = nil
            for button in GamepadButton.allCases {
                button.input(of: gamepad).pressedChangedHandler = nil
            }
        }
        pads.disconnect(id)
        updateConnected()
    }

    #if os(tvOS)
    /// The remote's presses a gamepad's also turn into (all but Menu, which
    /// stays the remote's way back for both).
    public static let echoedPresses: Set<UIPress.PressType> = [.upArrow, .downArrow, .leftArrow, .rightArrow, .select, .playPause]

    /// The remote's Menu press (or a gamepad's echo of it) arrived.
    public func menuArrived() {
        menuArrival = CACurrentMediaTime()
    }

    /// Whether a press of the remote's kind that arrived at `time` was a
    /// gamepad's echo: one of its controls that Apple TV turns into that
    /// press went down then, or is still held.
    public func isEcho(_ type: UIPress.PressType, at time: TimeInterval) -> Bool {
        if let sent = sent[type], abs(sent - time) < pads.configuration.echoWindow { return true }
        let ways: [FocusNavigator.Direction] = [.up, .down, .left, .right]
        return ways.contains { $0.press == type && pads.holds($0) }
            || GamepadButton.allCases.contains { $0.echo == type && pads.holds($0) }
    }

    /// Hands a press of the remote's (`pressesBegan`) to `handle`: at once,
    /// or, while a gamepad is connected and the press is one Apple TV makes
    /// of a gamepad's too, a moment later, unless it was that echo (which
    /// `onAction` has taken already). Returns whether the press is the
    /// game's: what `handle` returns, or true for one held back.
    public func routeRemotePress(_ type: UIPress.PressType, handle: @escaping (UIPress.PressType) -> Bool) -> Bool {
        if type == .menu { menuArrived() }
        guard Self.isConnected, Self.echoedPresses.contains(type) else { return handle(type) }
        let arrival = CACurrentMediaTime()
        schedule(pads.configuration.echoWindow) { [weak self] in
            guard let self, !isEcho(type, at: arrival) else { return }
            _ = handle(type)
        }
        return true
    }
    #endif

    /// iPhone and iPad: Apple's on-screen gamepad, which connects as a real
    /// one does (a test run's, where no gamepad is at hand).
    public func showVirtualGamepad() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard virtualGamepad == nil else { return }
        let configuration = GCVirtualController.Configuration()
        configuration.elements = [
            GCInputDirectionPad, GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY,
            GCInputLeftShoulder, GCInputRightShoulder,
        ]
        let gamepad = GCVirtualController(configuration: configuration)
        gamepad.connect()
        virtualGamepad = gamepad
        #endif
    }

    /// Plays `steps` (`GamepadScript`), one every `interval` after `delay`:
    /// on Apple's virtual gamepad while it's up (connected and pressed as a
    /// real one is), else on a snapshot gamepad, whose controls can be set,
    /// announced as connecting now.
    public func playScript(_ steps: [String], delay: TimeInterval, interval: TimeInterval, pressDuration: TimeInterval) {
        let script = GamepadScript.parse(steps, pressDuration: pressDuration)
        guard !script.isEmpty, let gamepad = scriptedGamepad() else { return }
        for (index, step) in script.enumerated() {
            guard let step else { continue }
            schedule(delay + interval * Double(index)) { [schedule] in
                switch step {
                case .connect: gamepad.connect(true)
                case .disconnect: gamepad.connect(false)
                case let .press(control, seconds):
                    guard let set = gamepad.control(control) else { return }
                    set(true)
                    schedule(seconds) { set(false) }
                }
            }
        }
    }

    private typealias ScriptedGamepad = (connect: (Bool) -> Void, control: (GamepadScript.Control) -> ((Bool) -> Void)?)

    private func scriptedGamepad() -> ScriptedGamepad? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 17, *), let virtual = virtualGamepad {
            return ({ $0 ? virtual.connect() : virtual.disconnect() }, { Self.scriptControl($0, on: virtual) })
        }
        #endif
        let controller = GCController.withExtendedGamepad()
        guard let gamepad = controller.extendedGamepad else { return nil }
        let connect: (Bool) -> Void = {
            NotificationCenter.default.post(name: $0 ? .GCControllerDidConnect : .GCControllerDidDisconnect, object: controller)
        }
        connect(true)
        return (connect, { Self.scriptControl($0, on: gamepad) })
    }

    /// Presses (true) or lets go of (false) a control on a snapshot.
    private static func scriptControl(_ control: GamepadScript.Control, on gamepad: GCExtendedGamepad) -> ((Bool) -> Void)? {
        switch control {
        case .dpad(let way):
            let axes = GamepadScript.axes(way)
            return { gamepad.dpad.setValueForXAxis($0 ? axes.x : 0, yAxis: $0 ? axes.y : 0) }
        case .stick(let way):
            let axes = GamepadScript.axes(way)
            return { gamepad.leftThumbstick.setValueForXAxis($0 ? axes.x : 0, yAxis: $0 ? axes.y : 0) }
        case .button(let button):
            let input = button.input(of: gamepad)
            return { input.setValue($0 ? 1 : 0) }
        }
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// The same on Apple's virtual gamepad (which has no stick or Menu
    /// here; it takes scripted presses from iOS 17).
    @available(iOS 17, *)
    private static func scriptControl(_ control: GamepadScript.Control, on gamepad: GCVirtualController) -> ((Bool) -> Void)? {
        switch control {
        case .dpad(let way):
            let axes = GamepadScript.axes(way)
            let position = CGPoint(x: CGFloat(axes.x), y: CGFloat(axes.y))
            return { gamepad.setPosition($0 ? position : .zero, forDirectionPadElement: GCInputDirectionPad) }
        case .stick:
            return nil
        case .button(let button):
            let elements: [GamepadButton: String] = [
                .a: GCInputButtonA, .b: GCInputButtonB, .x: GCInputButtonX, .y: GCInputButtonY,
                .leftShoulder: GCInputLeftShoulder, .rightShoulder: GCInputRightShoulder,
            ]
            guard let element = elements[button] else { return nil }
            return { gamepad.setValue($0 ? 1 : 0, forButtonElement: element) }
        }
    }
    #endif
    #endif
}

#if !SPRITEKIT_SHIM
private extension GamepadButton {
    func input(of gamepad: GCExtendedGamepad) -> GCControllerButtonInput {
        switch self {
        case .a: return gamepad.buttonA
        case .b: return gamepad.buttonB
        case .x: return gamepad.buttonX
        case .y: return gamepad.buttonY
        case .leftShoulder: return gamepad.leftShoulder
        case .rightShoulder: return gamepad.rightShoulder
        case .menu: return gamepad.buttonMenu
        }
    }

    #if os(tvOS)
    /// The remote's press Apple TV also turns it into (WWDC 2016,
    /// "Mastering UIKit on tvOS"), if any.
    var echo: UIPress.PressType? {
        switch self {
        case .a: return .select
        case .b, .menu: return .menu
        case .x: return .playPause
        case .leftShoulder: return .leftArrow
        case .rightShoulder: return .rightArrow
        case .y: return nil
        }
    }
    #endif
}

#if os(tvOS)
private extension FocusNavigator.Direction {
    /// The remote's press for this way.
    var press: UIPress.PressType {
        switch self {
        case .up: return .upArrow
        case .down: return .downArrow
        case .left: return .leftArrow
        case .right: return .rightArrow
        }
    }
}
#endif
#endif
