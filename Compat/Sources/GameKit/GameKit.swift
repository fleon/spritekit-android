// Stands in for GameKit on Android, for the one file that still imports it:
// the beta's solve log (`PlaytestLog`), which names a signed-in player by
// their id and alias. The game's own Game Center manager is a stand-in of
// its own (`Platform/GameCenterManager.swift`, on Play Games).
import Foundation

/// The player as the solve log asks: the one signed in to Play Games, by
/// their Play Games ID and name (set by `AndroidPlatformServices` from
/// `PlayGamesAchievements.identity`), so the log names them as it names a
/// Game Center player on iOS (`pg:<id>` rather than `gc:<id>`). Signed out,
/// a record names its install instead (`anon:<id>`), as an iOS build signed
/// out of Game Center does. Comes out with the solve log.
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
