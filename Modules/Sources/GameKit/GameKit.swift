// Stands in for GameKit on Android, as far as naming the signed-in player by
// their id and alias goes. Achievements and sign-in go through PlatformShim's
// `AchievementsBackend` (Play Games) instead.
import Foundation

/// The local player: the one signed in to Play Games, by their Play Games ID
/// and name (set by the platform layer from
/// `PlayGamesAchievements.identity`), so a game can name them as it names a
/// Game Center player on iOS. Signed out, `isAuthenticated` is false, as on
/// iOS.
@MainActor
public final class GKLocalPlayer {
    public static let local = GKLocalPlayer()

    public private(set) var isAuthenticated = false
    public private(set) var gamePlayerID = ""
    public private(set) var alias = ""

    private init() {}

    /// The Play Games player now signed in, or nil once nobody is.
    public func update(_ identity: (id: String, name: String)?) {
        isAuthenticated = identity != nil
        gamePlayerID = identity?.id ?? ""
        alias = identity?.name ?? ""
    }
}
