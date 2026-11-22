#if SPRITEKIT_SHIM
import Foundation

/// Whether the game is in front, as the game asks UIKit. The shell sets it
/// from SDL's background and foreground events and posts the notifications
/// UIKit would (an offscreen render may wait for the game to come back
/// before it draws another frame, since nothing draws while it's away).
public final class UIApplication: @unchecked Sendable {
    public enum State: Int, Sendable {
        case active, inactive, background
    }

    public nonisolated(unsafe) static let shared = UIApplication()

    public private(set) var applicationState: State = .active

    public static let willResignActiveNotification = Notification.Name("UIApplicationWillResignActiveNotification")
    public static let didBecomeActiveNotification = Notification.Name("UIApplicationDidBecomeActiveNotification")
    public static let didEnterBackgroundNotification = Notification.Name("UIApplicationDidEnterBackgroundNotification")
    public static let willEnterForegroundNotification = Notification.Name("UIApplicationWillEnterForegroundNotification")

    private init() {}

    /// The app is leaving the screen. Posted on the calling thread, which
    /// is the game's.
    public func resignActive() {
        guard applicationState == .active else { return }
        applicationState = .inactive
        NotificationCenter.default.post(name: Self.willResignActiveNotification, object: self)
        applicationState = .background
        NotificationCenter.default.post(name: Self.didEnterBackgroundNotification, object: self)
    }

    /// The app is back in front.
    public func becomeActive() {
        guard applicationState != .active else { return }
        applicationState = .inactive
        NotificationCenter.default.post(name: Self.willEnterForegroundNotification, object: self)
        applicationState = .active
        NotificationCenter.default.post(name: Self.didBecomeActiveNotification, object: self)
    }
}

public extension UIApplication {
    /// The scenes the app shows: on Android the one window scene the game's
    /// surface made (`GameHostSurface`), while it's kept.
    @MainActor var connectedScenes: Set<UIScene> { ConnectedScenes.live }
}

/// The window scenes made so far, held weakly: a scene is listed while its
/// maker keeps it, as UIKit lists a scene until it disconnects.
@MainActor
enum ConnectedScenes {
    private final class Weak {
        weak var scene: UIScene?
        init(_ scene: UIScene) { self.scene = scene }
    }

    private static var scenes: [Weak] = []

    static func add(_ scene: UIScene) {
        scenes.removeAll { $0.scene == nil }
        scenes.append(Weak(scene))
    }

    static var live: Set<UIScene> {
        Set(scenes.compactMap(\.scene))
    }
}
#endif
