#if SPRITEKIT_SHIM
import Foundation

/// A gamepad's input as the shell reads it from SDL (`SDL_EVENT_GAMEPAD_*`),
/// in GameController's terms: an extended gamepad's d-pad, left stick and
/// the buttons the game reads. The game's `GamepadInput` reads these on
/// Android where it reads `GCController` on Apple.
public enum GamepadEvent: Equatable, Sendable {
    public enum Button: Sendable {
        case a, b, x, y, leftShoulder, rightShoulder, menu
    }

    case connected(id: UInt32)
    case disconnected(id: UInt32)
    /// The d-pad, x right and y up, each −1, 0 or 1.
    case dpad(id: UInt32, x: Float, y: Float)
    /// The left stick, x right and y up, each −1…1.
    case stick(id: UInt32, x: Float, y: Float)
    case button(id: UInt32, Button, pressed: Bool)
}

/// Where the shell sends gamepad events: whoever reads them installs a sink.
@MainActor
public enum GamepadEvents {
    public static var sink: ((GamepadEvent) -> Void)?
    /// Pads connected before anyone listened, so a reader that arrives late
    /// (the game's controller is made after the first frame) still hears them.
    public private(set) static var connected: Set<UInt32> = []

    public static func post(_ event: GamepadEvent) {
        switch event {
        case let .connected(id): connected.insert(id)
        case let .disconnected(id): connected.remove(id)
        default: break
        }
        sink?(event)
    }
}
#endif
