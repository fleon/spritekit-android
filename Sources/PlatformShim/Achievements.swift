import Foundation

/// Reporting achievements, with GameKit taken out from under
/// `GameCenterManager`.
///
/// ## What is real here and what is not
///
/// Real: what the player has earned. Board firsts are already kept in the
/// game's own saved data (a synced set), and how far each achievement has
/// come is worked out from them by `Achievement`, which is portable rules
/// code. So on Android the progress is right, it survives a launch, and it
/// is readable — `LocalAchievements` is a genuine store, not a hole.
///
/// Not real: Play Games Services. It needs a Play Console game with its
/// achievements created and an OAuth client tied to the app's signing
/// certificate, none of which exists yet — the app has a package name and a
/// store listing and nothing else (`Tools/Play/PLAY-CONSOLE-SETUP.md`). So
/// nothing is sent anywhere, there is no sign-in, and
/// `PlayGamesAchievements` is a name for the gap.
///
/// Two consequences that are decisions rather than gaps, both settled:
///   - There is no player name or photo on Android, so a shared level
///     carries no maker credit. `localPlayer()` returns nil for good, not
///     until something lands.
///   - Nothing here reaches the network, which is what keeps the Android
///     build's Data Safety answer as short as it is.
public protocol AchievementsBackend: AnyObject {
    var isSignedIn: Bool { get }
    /// Signs in if the service has one. `answered` runs once it has said
    /// yes, no, or failed — the launch splash waits on it, so a backend that
    /// cannot sign in must still call it.
    func start(answered: @escaping () -> Void)
    /// What the service holds for each achievement, as percentages.
    func load() async -> [String: Double]
    /// Sends those that have moved. Returns whether they arrived.
    func report(_ progress: [String: Double], showingBanners: Bool) async -> Bool
    /// Clears everything the service holds (`-ResetAchievements`).
    func reset() async -> Bool
    func showDashboard()
    /// The signed-in player's name and photo, for a shared level's credit.
    func localPlayer() async -> (name: String, photo: Data?)?
}

/// Keeps achievement progress on the device and sends it nowhere.
///
/// This is what an Android build reports to today. It behaves like a service
/// that is always reachable and always agrees: `load()` hands back what was
/// last reported, so the "only send what has moved" logic in
/// `GameCenterManager` runs exactly as it does on Apple and can be tested.
public final class LocalAchievements: AchievementsBackend {
    private enum Key {
        static let reported = "achievements.reported"
    }

    private let defaults: UserDefaults

    /// Nobody is signed in: there is no service to sign in to. The dashboard
    /// and the player's name follow from this, so every caller already
    /// handles it — the game is built to stay playable signed out.
    public var isSignedIn: Bool { false }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func start(answered: @escaping () -> Void) {
        answered()
    }

    public func load() async -> [String: Double] {
        defaults.dictionary(forKey: Key.reported) as? [String: Double] ?? [:]
    }

    public func report(_ progress: [String: Double], showingBanners: Bool) async -> Bool {
        var held = await load()
        for (id, percent) in progress {
            held[id] = max(held[id] ?? 0, percent)
        }
        defaults.set(held, forKey: Key.reported)
        return true
    }

    public func reset() async -> Bool {
        defaults.removeObject(forKey: Key.reported)
        return true
    }

    public func showDashboard() {}

    public func localPlayer() async -> (name: String, photo: Data?)? { nil }
}
