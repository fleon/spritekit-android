import Foundation
#if canImport(UIKit) && !SPRITEKIT_SHIM
import UIKit
#endif

/// The settings' status bar switch: whether the system's status bar shows
/// over the game, saved on the device (hidden until the player turns it on,
/// unless the game says otherwise). On Apple the game's view controller
/// answers `prefersStatusBarHidden` from `isHidden` and calls
/// `follow(_:)` once; on Android `AndroidPlatformServices` shows or hides
/// the bar as it changes (`.toolkit(statusBar: true)`).
public enum StatusBarSetting {
    /// Where the switch is kept and how it starts. Set it at launch, before
    /// anything reads it.
    public struct Configuration {
        public var defaults: UserDefaults = .standard
        public var key = "settings.statusBarVisible"
        /// Whether the bar shows before the player picks.
        public var defaultVisible = false
        /// Called with the key each time the switch is saved, for a game
        /// that syncs its settings; `savedDataDidSync` hears it coming back.
        public var didSave: ((String) -> Void)?

        public init() {}
    }

    public static var configuration = Configuration()

    /// Posted on the main thread whenever the switch changes.
    public static let didChange = Notification.Name("StatusBarSetting.didChange")

    public static var isVisible: Bool {
        get { configuration.defaults.object(forKey: configuration.key) as? Bool ?? configuration.defaultVisible }
        set {
            configuration.defaults.set(newValue, forKey: configuration.key)
            configuration.didSave?(configuration.key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// What a view controller's `prefersStatusBarHidden` answers.
    public static var isHidden: Bool { !isVisible }

    /// Runs `changed` with the switch each time it changes; keep the token
    /// for as long as it should.
    public static func observe(_ changed: @escaping @MainActor (Bool) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: didChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { changed(isVisible) }
        }
    }

    /// Hears another device's switch, when the game syncs its settings.
    public static func savedDataDidSync(_ keys: Set<String>) {
        guard keys.contains(configuration.key) else { return }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    #if os(iOS) && !SPRITEKIT_SHIM
    nonisolated(unsafe) private static var follower: NSObjectProtocol?

    /// Has `controller` ask UIKit for its status bar again whenever the
    /// switch changes, and once now. Its `prefersStatusBarHidden` answers
    /// `StatusBarSetting.isHidden`.
    public static func follow(_ controller: UIViewController) {
        follower.map(NotificationCenter.default.removeObserver)
        follower = observe { [weak controller] _ in controller?.setNeedsStatusBarAppearanceUpdate() }
        controller.setNeedsStatusBarAppearanceUpdate()
    }
    #endif
}
