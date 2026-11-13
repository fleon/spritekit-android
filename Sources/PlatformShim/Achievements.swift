import Foundation

/// Reporting achievements, with GameKit taken out from under
/// `GameCenterManager`.
///
/// What the player has earned is the game's own saved data (board firsts are
/// a synced set; levels cleared are `Progress`), and `Achievement` works out
/// each achievement's percentage from it, as on Apple. A backend only keeps
/// or sends those percentages: `PlayGamesAchievements` (Play Games Services,
/// mapping each to Play's IDs as an unlock or steps) when the build carries
/// Play Games' IDs, `LocalAchievements` otherwise, which keeps them on the
/// device and sends them nowhere.
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

/// Keeps achievement progress on the device and sends it nowhere: an
/// Android build without Play Games, and the host tests. It behaves like a service
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
