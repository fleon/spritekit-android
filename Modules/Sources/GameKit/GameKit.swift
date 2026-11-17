// Stands in for GameKit on Android: the signed-in player by their id and
// alias, and leaderboard scores (`GKLeaderboard`) through PlatformShim's
// `LeaderboardsBackend` (Play Games). Achievements and sign-in go through
// PlatformShim's `AchievementsBackend` instead.
import Foundation
import PlatformShim

/// A Game Center player: here, the one signed in to Play Games.
@MainActor
open class GKPlayer {
    public internal(set) var gamePlayerID = ""
    public internal(set) var alias = ""
    public var displayName: String { alias }

    init() {}
}

/// The local player: the one signed in to Play Games, by their Play Games ID
/// and name (set by the platform layer from
/// `PlayGamesAchievements.identity`), so a game can name them as it names a
/// Game Center player on iOS. Signed out, `isAuthenticated` is false, as on
/// iOS.
@MainActor
public final class GKLocalPlayer: GKPlayer {
    public static let local = GKLocalPlayer()

    public private(set) var isAuthenticated = false

    private override init() {}

    /// The Play Games player now signed in, or nil once nobody is.
    public func update(_ identity: (id: String, name: String)?) {
        isAuthenticated = identity != nil
        gamePlayerID = identity?.id ?? ""
        alias = identity?.name ?? ""
    }
}

/// GameKit's errors, by Apple's codes, for the few a stand-in reports.
public struct GKError: Error, Equatable, Sendable {
    public enum Code: Int, Sendable {
        case unknown = 1
        case cancelled = 2
        case communicationsFailure = 3
        case notAuthenticated = 6
    }

    public static let errorDomain = "GKErrorDomain"

    public let code: Code

    public init(_ code: Code) {
        self.code = code
    }

    public static var unknown: Code { .unknown }
    public static var cancelled: Code { .cancelled }
    public static var communicationsFailure: Code { .communicationsFailure }
    public static var notAuthenticated: Code { .notAuthenticated }
}

/// A leaderboard, for sending scores to: `submitScore` as Game Center has
/// it, on `backend` (Play Games once the game installs it, else nowhere).
@MainActor
public final class GKLeaderboard {
    /// Where scores go. The game installs `PlayGamesLeaderboards` at launch.
    public static var backend: LeaderboardsBackend = LocalLeaderboards()

    private init() {}

    /// Sends `score` to the leaderboards in `leaderboardIDs` for `player`
    /// (always the local player: Game Center accepts no other, and Play Games
    /// knows only the one signed in). The handler runs on the main actor with
    /// nil once they arrived, or `.communicationsFailure` when they didn't —
    /// signed out included, since Play answers that rather than the player.
    public static func submitScore(
        _ score: Int,
        context: Int,
        player: GKPlayer,
        leaderboardIDs: [String],
        completionHandler: @escaping @MainActor (Error?) -> Void
    ) {
        Task { @MainActor in
            do {
                try await submitScore(score, context: context, player: player, leaderboardIDs: leaderboardIDs)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    public static func submitScore(
        _ score: Int,
        context: Int,
        player: GKPlayer,
        leaderboardIDs: [String]
    ) async throws {
        guard await backend.submit(score, context: context, to: leaderboardIDs) else {
            throw GKError(.communicationsFailure)
        }
    }
}
