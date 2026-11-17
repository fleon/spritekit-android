import Foundation

/// Reporting achievements, with GameKit taken out from under a game's Game
/// Center code.
///
/// What the player has earned is the game's own saved data, and the game
/// works out each achievement's percentage from it, as on Apple. A backend
/// only keeps or sends those percentages: `PlayGamesAchievements` (Play Games Services,
/// mapping each to Play's IDs as an unlock or steps) when the build carries
/// Play Games' IDs, `LocalAchievements` otherwise, which keeps them on the
/// device and sends them nowhere.
public protocol AchievementsBackend: AnyObject {
    var isSignedIn: Bool { get }
    /// Signs in if the service has one. `answered` runs once it has said
    /// yes, no, or failed — a game's launch may wait on it, so a backend that
    /// cannot sign in must still call it.
    func start(answered: @escaping () -> Void)
    /// What the service holds for each achievement, as percentages.
    func load() async -> [String: Double]
    /// Sends those that have moved. Returns whether they arrived.
    func report(_ progress: [String: Double], showingBanners: Bool) async -> Bool
    /// Clears everything the service holds (a game's debug reset).
    func reset() async -> Bool
    /// Whether the service has a dashboard of its own, which signs a
    /// signed-out player in before it opens: a game's dashboard button (Game
    /// Center's on Apple) shows only then.
    var hasDashboard: Bool { get }
    /// Opens the dashboard, signing the player in first if need be.
    func showDashboard()
    /// The signed-in player's name and photo, for the game to credit them.
    func localPlayer() async -> (name: String, photo: Data?)?
}

public extension AchievementsBackend {
    /// Whether a dashboard button opens the dashboard: when the player is
    /// signed in, or when the dashboard signs them in itself. Otherwise a
    /// game would tell them to sign in from Game Center's settings.
    var opensDashboard: Bool { isSignedIn || hasDashboard }
}

/// Keeps achievement progress on the device and sends it nowhere: an
/// Android build without Play Games, and the host tests. It behaves like a service
/// that is always reachable and always agrees: `load()` hands back what was
/// last reported, so a game's "only send what has moved" logic runs exactly
/// as it does on Apple and can be tested.
public final class LocalAchievements: AchievementsBackend {
    private enum Key {
        static let reported = "achievements.reported"
    }

    private let defaults: UserDefaults

    /// Nobody is signed in: there is no service to sign in to. The dashboard
    /// and the player's name follow from this, so every caller already
    /// handles it — a game must stay playable signed out anyway.
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

    public var hasDashboard: Bool { false }

    public func showDashboard() {}

    public func localPlayer() async -> (name: String, photo: Data?)? { nil }
}
