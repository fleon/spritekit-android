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
                // Again when already started: SDL then shows the keyboard
                // if Android's back put it away. The field's own settings
                // pick the keyboard: the code prompt's capitals, no
                // corrections.
                let field = MainActor.assumeIsolated { UITextField.firstResponder }
                let properties = SDL_CreateProperties()
                defer { SDL_DestroyProperties(properties) }
                _ = SDL_SetNumberProperty(properties, SDL_PROP_TEXTINPUT_ANDROID_INPUTTYPE_NUMBER, Int64(MainActor.assumeIsolated { AndroidInputType.of(field) }))
                // Where the field is, for the keyboard's own use (its
                // candidates), in the window's coordinates.
                if let frame {
                    let scale = CGFloat(SDL_GetWindowDisplayScale(window)) / CGFloat(max(SDL_GetWindowPixelDensity(window), 1))
                    var area = SDL_Rect(x: Int32(frame.minX * scale), y: Int32(frame.minY * scale), w: Int32(frame.width * scale), h: Int32(frame.height * scale))
                    _ = SDL_SetTextInputArea(window, &area, 0)
                }
                _ = SDL_StartTextInputWithProperties(window, properties)
            }
        }
        TextInput.offerPaste = { point in
            let scale = CGFloat(SDL_GetWindowDisplayScale(window))
            _ = switchlings_offer_paste(Float(point.x * scale), Float(point.y * scale))
        }
    }
}

/// Android's `InputType` for a field, from what UIKit's field asks for: the
/// code prompt's capitals, with no corrections or suggestions (UIKit's
/// `.no`), which SDL's own properties can't say (it has no flag for
/// suggestions). Gboard takes `NO_SUGGESTIONS` as a hint and still offers
/// words for letters, and a word picked from its strip would arrive as one
/// insertion of several letters, so such a field is also a visible
/// password, which no keyboard suggests for; the field capitalises what it's
/// given itself.
@MainActor
enum AndroidInputType {
    static let classText = 0x1
    static let capCharacters = 0x1000
    static let capWords = 0x2000
    static let capSentences = 0x4000
    static let autoCorrect = 0x8000
    static let noSuggestions = 0x80000
    static let visiblePassword = 0x90

    static func of(_ field: UITextField?) -> Int {
        var type = classText
        switch field?.autocapitalizationType ?? .sentences {
        case .allCharacters: type |= capCharacters
        case .words: type |= capWords
        case .sentences: type |= capSentences
        case .none: break
        }
        type |= field?.autocorrectionType == .no ? noSuggestions | visiblePassword : autoCorrect
        return type
    }
}

/// What `MainActivity` hands the game outside SDL's events, taken once a
/// frame on the game's thread: a link opened while the game runs (a cold
/// start's comes as `-LaunchLink` instead), text picked from Paste, and the
/// soft keyboard's height from Android's insets, posted as UIKit's keyboard
/// notifications (`SoftKeyboard`).
@MainActor
enum SystemInbox {
    static func drain(into renderer: FrameRenderer, window: OpaquePointer) {
        while let link = switchlings_take_link() {
            defer { free(link) }
            let text = String(cString: link)
            if let url = URL(string: text) {
                Log.info("link: \(text)")
                _ = renderer.receive(.link(url))
            }
        }
        while let paste = switchlings_take_paste() {
            defer { free(paste) }
            _ = renderer.receive(.text(String(cString: paste)))
        }
        var height: Int32 = 0, viewHeight: Int32 = 0
        if switchlings_take_keyboard(&height, &viewHeight) {
            let scale = CGFloat(SDL_GetWindowDisplayScale(window))
            var w: Int32 = 0, h: Int32 = 0
            SDL_GetWindowSizeInPixels(window, &w, &h)
            guard scale > 0 else { return }
            let bottom = CGFloat(viewHeight > 0 ? viewHeight : h) / scale
            SoftKeyboard.frameDidChange(height > 0
                ? CGRect(x: 0, y: bottom - CGFloat(height) / scale, width: CGFloat(w) / scale, height: CGFloat(height) / scale)
                : nil)
        }
    }
}
