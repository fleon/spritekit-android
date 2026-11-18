import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
import UIKit
#endif

/// Who shows focus in a game's view, as its view controller decides: on
/// Apple TV the remote's focus always shows; elsewhere a gamepad's first
/// press only brings focus up where the screen starts it, so it shows
/// before it acts, and a touch or click, the Mac's pointer moving (which
/// shows focus of its own, `HoverFocus`, standing aside meanwhile) or the
/// last gamepad going hide it again.
public final class FocusDriver {
    /// The focus the remote or a gamepad moves, while it shows.
    public private(set) var navigator: FocusNavigator?
    private weak var view: SKView?
    private let alwaysOn: Bool
    #if targetEnvironment(macCatalyst)
    /// The pointer's focus on the control under it.
    public private(set) var hover: HoverFocus?
    #endif

    /// `alwaysOn`: focus shows from the start and never hides (Apple TV,
    /// where the scene takes no touches). `pointer`: on the Mac, where the
    /// pointer starts before it moves (a test run may place it).
    public init(view: SKView, alwaysOn: Bool = FocusDriver.isRemoteOnly, pointer: CGPoint? = nil) {
        self.view = view
        self.alwaysOn = alwaysOn
        if alwaysOn {
            navigator = FocusNavigator(view: view)
            return
        }
        #if os(iOS)
        let touches = TouchWatcher()
        touches.onTouch = { [weak self] in self?.release() }
        view.addGestureRecognizer(touches)
        #endif
        #if targetEnvironment(macCatalyst)
        hover = HoverFocus(view: view, pointer: pointer)
        hover?.onMove = { [weak self] in self?.release() }
        #endif
    }

    /// Whether the platform has only the remote's focus to go by (Apple TV).
    public static var isRemoteOnly: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    /// Focus for a gamepad to move or press: nil the first time, as focus
    /// only comes up then.
    public func take() -> FocusNavigator? {
        if let navigator { return navigator }
        guard let view else { return nil }
        #if targetEnvironment(macCatalyst)
        hover?.isSuspended = true
        #endif
        navigator = FocusNavigator(view: view)
        navigator?.refresh()
        return nil
    }

    /// Touch or the pointer take over from a gamepad: focus no longer shows.
    public func release() {
        guard !alwaysOn, let navigator else { return }
        navigator.stop()
        self.navigator = nil
        #if targetEnvironment(macCatalyst)
        hover?.isSuspended = false
        #endif
    }

    /// Has `gamepads` drive focus: the d-pad and stick move it and A
    /// presses the focused control, as the remote's clickpad does; every
    /// other button goes to `onPress`. The last gamepad going hides focus.
    public func connect(_ gamepads: GamepadInput, onPress: @escaping (GamepadButton) -> Void) {
        gamepads.onAction = { [weak self] action in
            switch action {
            case .move(let direction): self?.take()?.move(direction)
            case .press(.a): self?.take()?.select()
            case .press(let button): onPress(button)
            }
        }
        gamepads.onDisconnectAll = { [weak self] in self?.release() }
    }

    #if SPRITEKIT_SHIM
    /// Android: a touch through `window` hides focus.
    public func watchTouches(in window: UIWindow) {
        window.observer = { [weak self] event in
            if event.allTouches?.contains(where: { $0.phase == .began }) == true { self?.release() }
        }
    }
    #endif
}
