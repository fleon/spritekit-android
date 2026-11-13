import CAndroidShell
import Foundation
import PlatformShim
import ShellCore
import SpriteKitShim

/// SDL's gamepads in GameController's terms (`GamepadEvent`): an extended
/// gamepad's d-pad, left stick and the buttons the game reads. Opens each
/// pad as it arrives, as SDL needs before it sends a pad's events.
final class GamepadBridge {
    private var pads: [SDL_JoystickID: OpaquePointer] = [:]
    /// The d-pad's buttons held, per pad, as x right and y up.
    private var dpads: [SDL_JoystickID: (x: Float, y: Float)] = [:]
    private var sticks: [SDL_JoystickID: (x: Float, y: Float)] = [:]

    func translate(_ event: SDL_Event) -> [GamepadEvent] {
        switch event.type {
        case SDL_EVENT_GAMEPAD_ADDED.rawValue:
            let id = event.gdevice.which
            guard pads[id] == nil, let pad = SDL_OpenGamepad(id) else { return [] }
            pads[id] = pad
            return [.connected(id: id)]
        case SDL_EVENT_GAMEPAD_REMOVED.rawValue:
            let id = event.gdevice.which
            guard let pad = pads.removeValue(forKey: id) else { return [] }
            SDL_CloseGamepad(pad)
            dpads[id] = nil
            sticks[id] = nil
            return [.disconnected(id: id)]
        case SDL_EVENT_GAMEPAD_BUTTON_DOWN.rawValue, SDL_EVENT_GAMEPAD_BUTTON_UP.rawValue:
            let id = event.gbutton.which
            let pressed = event.gbutton.down
            let button = SDL_GamepadButton(rawValue: Int32(event.gbutton.button))
            var dpad = dpads[id] ?? (0, 0)
            switch button {
            case SDL_GAMEPAD_BUTTON_DPAD_UP: dpad.y = pressed ? 1 : (dpad.y > 0 ? 0 : dpad.y)
            case SDL_GAMEPAD_BUTTON_DPAD_DOWN: dpad.y = pressed ? -1 : (dpad.y < 0 ? 0 : dpad.y)
            case SDL_GAMEPAD_BUTTON_DPAD_LEFT: dpad.x = pressed ? -1 : (dpad.x < 0 ? 0 : dpad.x)
            case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: dpad.x = pressed ? 1 : (dpad.x > 0 ? 0 : dpad.x)
            default:
                guard let mapped = Self.button(button) else { return [] }
                return [.button(id: id, mapped, pressed: pressed)]
            }
            dpads[id] = dpad
            return [.dpad(id: id, x: dpad.x, y: dpad.y)]
        case SDL_EVENT_GAMEPAD_AXIS_MOTION.rawValue:
            let id = event.gaxis.which
            let value = max(-1, Float(event.gaxis.value) / 32767)
            var stick = sticks[id] ?? (0, 0)
            switch SDL_GamepadAxis(rawValue: Int32(event.gaxis.axis)) {
            case SDL_GAMEPAD_AXIS_LEFTX: stick.x = value
            // SDL's y runs down; GameController's up.
            case SDL_GAMEPAD_AXIS_LEFTY: stick.y = -value
            default: return []
            }
            sticks[id] = stick
            return [.stick(id: id, x: stick.x, y: stick.y)]
        default:
            return []
        }
    }

    /// As the console puzzle games map them (`GamepadInput`): SDL names
    /// buttons by where they sit, GameController by Xbox's letters.
    private static func button(_ button: SDL_GamepadButton) -> GamepadEvent.Button? {
        switch button {
        case SDL_GAMEPAD_BUTTON_SOUTH: return .a
        case SDL_GAMEPAD_BUTTON_EAST: return .b
        case SDL_GAMEPAD_BUTTON_WEST: return .x
        case SDL_GAMEPAD_BUTTON_NORTH: return .y
        case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return .leftShoulder
        case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return .rightShoulder
        case SDL_GAMEPAD_BUTTON_START: return .menu
        default: return nil
        }
    }
}

/// What UIKit's calls that leave the game do on Android, through SDL:
/// opening a link, the clipboard, keeping the screen on and the keyboard.
enum SystemBridge {
    static func install(window: OpaquePointer) {
        SystemServices.openURL = { url in SDL_OpenURL(url.absoluteString) }
        SystemServices.clipboard = (
            get: {
                guard SDL_HasClipboardText(), let text = SDL_GetClipboardText() else { return nil }
                defer { SDL_free(text) }
                return String(cString: text)
            },
            set: { text in _ = SDL_SetClipboardText(text ?? "") }
        )
        SystemShare.pasteboard = { text in _ = SDL_SetClipboardText(text) }
        SystemServices.keepAwake = { awake in
            _ = awake ? SDL_DisableScreenSaver() : SDL_EnableScreenSaver()
        }
        TextInput.show = { frame in
            if frame == nil {
                _ = SDL_StopTextInput(window)
            } else {
                _ = SDL_StartTextInput(window)
            }
        }
    }
}
