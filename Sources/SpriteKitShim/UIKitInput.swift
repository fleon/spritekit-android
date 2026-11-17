#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

// The rest of UIKit the game's scenes name: keyboard keys (the Android back
// button and a hardware keyboard reach scenes as these), the device, the
// pasteboard, haptics and the application's extras. Each is the game's
// spelling over whatever Android offers through the shell, or, where Android
// has nothing to say, the answer a device without the feature gives. Every
// stand-in is listed in Android/README.md.

/// USB HID usage codes, as UIKit names them. The raw values are the HID
/// table's, so a keyboard event from SDL (whose scancodes are the same
/// table) maps across by number.
public enum UIKeyboardHIDUsage: Int, Sendable {
    case keyboardA = 4, keyboardB, keyboardC, keyboardD, keyboardE, keyboardF, keyboardG,
         keyboardH, keyboardI, keyboardJ, keyboardK, keyboardL, keyboardM, keyboardN,
         keyboardO, keyboardP, keyboardQ, keyboardR, keyboardS, keyboardT, keyboardU,
         keyboardV, keyboardW, keyboardX, keyboardY, keyboardZ
    case keyboard1 = 30, keyboard2, keyboard3, keyboard4, keyboard5, keyboard6,
         keyboard7, keyboard8, keyboard9, keyboard0
    case keyboardReturnOrEnter = 40, keyboardEscape, keyboardDeleteOrBackspace, keyboardTab, keyboardSpacebar
    case keyboardRightArrow = 79, keyboardLeftArrow, keyboardDownArrow, keyboardUpArrow
}

public struct UIKeyModifierFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let alphaShift = UIKeyModifierFlags(rawValue: 1 << 16)
    public static let shift = UIKeyModifierFlags(rawValue: 1 << 17)
    public static let control = UIKeyModifierFlags(rawValue: 1 << 18)
    public static let alternate = UIKeyModifierFlags(rawValue: 1 << 19)
    public static let command = UIKeyModifierFlags(rawValue: 1 << 20)
    public static let numericPad = UIKeyModifierFlags(rawValue: 1 << 21)
}

/// The device, as the game asks: a phone or a tablet (the shell decides
/// from the screen's smaller side, as Android's own resource buckets do).
@MainActor
public final class UIDevice {
    public static let current = UIDevice()

    public var userInterfaceIdiom: UIUserInterfaceIdiom = .phone {
        didSet { UITraitCollection.idiom = userInterfaceIdiom }
    }
    /// The beta's solve log and `-FrameLog` read it; Android's comes
    /// through BatteryManager (`SystemServices.batteryLevel`). With no
    /// platform services (a host test) it reports unknown, as a simulator does.
    public var isBatteryMonitoringEnabled = false
    public var batteryLevel: Float { SystemServices.batteryLevel() }

    private init() {}
}

public extension ProcessInfo {
    /// Android's battery saver (`PowerManager.isPowerSaveMode`), as the
    /// platform services last reported it (`SystemServices.lowPowerMode`).
    var isLowPowerModeEnabled: Bool { SystemServices.lowPowerMode }
}

public extension Notification.Name {
    static let NSProcessInfoPowerStateDidChange = Notification.Name("NSProcessInfoPowerStateDidChangeNotification")
}

/// What the shell does for UIKit's calls that leave the game: opening a
/// link (`SDL_OpenURL`) and the clipboard (`SDL_GetClipboardText`). Unset,
/// they do nothing, as on a host test.
public enum SystemServices {
    nonisolated(unsafe) public static var openURL: (URL) -> Bool = { _ in false }
    nonisolated(unsafe) public static var clipboard: (get: () -> String?, set: (String?) -> Void) = ({ nil }, { _ in })
    /// Keeps the screen on while true (`SDL_DisableScreenSaver`).
    nonisolated(unsafe) public static var keepAwake: (Bool) -> Void = { _ in }
    /// Plays one of the feedback generators' kinds on the phone's vibrator:
    /// `light`, `medium`, `soft`, `selection`, `success` or `warning`.
    nonisolated(unsafe) public static var haptic: (String) -> Void = { _ in }
    /// The device has a vibrator to play them on (`Vibrator.hasVibrator()`).
    nonisolated(unsafe) public static var hasVibrator = false
    /// Battery saver is on. Whoever sets it posts
    /// `NSProcessInfoPowerStateDidChange`, as iOS does.
    nonisolated(unsafe) public static var lowPowerMode = false
    /// The battery's charge from 0 to 1, or -1 where it can't be read.
    nonisolated(unsafe) public static var batteryLevel: () -> Float = { -1 }
    /// How the device reaches the internet (`wifi`, `cellular`, `wired`,
    /// `other` or `none`), or nil where it can't be told: the beta's solve
    /// log's `NWPathMonitor`.
    nonisolated(unsafe) public static var connection: () -> String? = { nil }
}

public extension UIApplication {
    func open(_ url: URL, options: [String: Any] = [:], completionHandler: ((Bool) -> Void)? = nil) {
        let opened = SystemServices.openURL(url)
        completionHandler?(opened)
    }

    /// The async spelling.
    @discardableResult
    func open(_ url: URL, options: [String: Any] = [:]) async -> Bool {
        SystemServices.openURL(url)
    }

    /// The app's own page in the system settings (its notifications among
    /// them): `SystemServices.openURL` hands this to the app, which opens
    /// Android's app details there.
    static let openSettingsURLString = "app-settings:"

    func canOpenURL(_ url: URL) -> Bool { true }

    var isIdleTimerDisabled: Bool {
        get { idleTimer.disabled }
        set {
            idleTimer.disabled = newValue
            SystemServices.keepAwake(newValue)
        }
    }

    /// Android has one window and no scenes to list.
    var connectedScenes: Set<UIWindowSceneHandle> { [] }
}

/// What `connectedScenes` holds; nothing on Android.
public struct UIWindowSceneHandle: Hashable, Sendable {}

private nonisolated(unsafe) let idleTimer = IdleTimer()
private final class IdleTimer { var disabled = false }

@MainActor
public final class UIPasteboard {
    public static let general = UIPasteboard()

    public var string: String? {
        get { SystemServices.clipboard.get() }
        set { SystemServices.clipboard.set(newValue) }
    }

    private init() {}
}

/// Haptics, played on the phone's vibrator by the platform services
/// (`DeviceServices.java`): each generator names its kind and
/// `SystemServices.haptic` does the rest. `prepare()` has nothing to warm.
@MainActor
open class UIFeedbackGenerator {
    public init() {}
    open func prepare() {}
}

@MainActor
public final class UIImpactFeedbackGenerator: UIFeedbackGenerator {
    public enum FeedbackStyle: Int, Sendable { case light, medium, heavy, soft, rigid }
    private let style: FeedbackStyle
    public init(style: FeedbackStyle) {
        self.style = style
        super.init()
    }
    public func impactOccurred() {
        switch style {
        case .light: SystemServices.haptic("light")
        case .soft: SystemServices.haptic("soft")
        case .medium, .heavy, .rigid: SystemServices.haptic("medium")
        }
    }
    public func impactOccurred(intensity: CGFloat) { impactOccurred() }
}

@MainActor
public final class UINotificationFeedbackGenerator: UIFeedbackGenerator {
    public enum FeedbackType: Int, Sendable { case success, warning, error }
    public func notificationOccurred(_ notificationType: FeedbackType) {
        SystemServices.haptic(notificationType == .success ? "success" : "warning")
    }
}

@MainActor
public final class UISelectionFeedbackGenerator: UIFeedbackGenerator {
    public func selectionChanged() { SystemServices.haptic("selection") }
}
#endif
