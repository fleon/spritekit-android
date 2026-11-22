import Foundation
import SpriteKitShim
#if os(iOS)
import UIKit.UIGestureRecognizerSubclass
#endif

// UIKit's keys exist on Apple and in the shim on Android; a Mac host test
// build has neither.
#if !SPRITEKIT_SHIM || !canImport(Darwin)
/// Scenes that respond to a hardware keyboard (iPad, Mac, Android). The
/// Apple TV remote's Back button and Android's back reach them as Escape.
public protocol KeyboardControllable: AnyObject {
    func handleKey(_ keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Bool
}
#endif

#if !SPRITEKIT_SHIM
extension KeyboardControllable {
    /// Hands each key press among `presses` on (`pressesBegan`). Returns
    /// whether any was taken; the controller hands the rest to `super`.
    public func handlePresses(_ presses: Set<UIPress>) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            handled = handleKey(key.keyCode, modifiers: key.modifierFlags) || handled
        }
        return handled
    }
}
#endif

/// Scenes whose settings (or pause menu) a gamepad's Menu button opens, and
/// closes again.
public protocol MenuToggling: AnyObject {
    func toggleMenu()
}

#if os(iOS)
/// Notices every touch (or click) on its view without taking it: a touch
/// takes focus back from a gamepad (`FocusDriver.release`).
public final class TouchWatcher: UIGestureRecognizer {
    public var onTouch: (() -> Void)?

    public override init(target: Any? = nil, action: Selector? = nil) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch?()
        state = .failed
    }
}
#endif
