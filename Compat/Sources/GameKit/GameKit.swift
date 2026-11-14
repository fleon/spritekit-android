// Stands in for GameKit on Android, for the one file that still imports it:
// the beta's solve log (`PlaytestLog`), which names a Game Center player by
// their id and alias. The game's own Game Center manager is a stand-in of
// its own (`Platform/GameCenterManager.swift`, on Play Games).
import Foundation

/// The player as the solve log asks. Play Games hands the port no player id
/// (only a name and photo for a credit, asynchronously), so nobody is signed
/// in here and every record names its install instead (`anon:<id>`), as an
/// iOS build signed out of Game Center does. Comes out with the solve log.
@MainActor
public final class GKLocalPlayer {
    public static let local = GKLocalPlayer()

    public let isAuthenticated = false
    public let gamePlayerID = ""
    public let alias = ""

    private init() {}
}
