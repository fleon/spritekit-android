import Foundation

/// What a game's Game Center code asks of leaderboards, in Game Center's own
/// terms: a score sent to one or more leaderboards by their Game Center IDs,
/// the leaderboards and their scores loaded, and the leaderboards shown over
/// the game.
///
/// On Apple the backend is GameKit (`GameKitLeaderboards`, in Platform's
/// `PlatformGameCenter`); on Android it is Play Games
/// (`PlayGamesLeaderboards`, in PlatformShim); with neither it is
/// `LocalLeaderboards`, which keeps nothing.
/// Every call answers, success or `LeaderboardError`, so a Game Center
/// completion handler always runs.
public protocol LeaderboardsBackend: AnyObject {
    /// Sends `score` to each leaderboard in `ids` (Game Center IDs). Returns
    /// once they all arrived.
    func submitScore(_ score: Int, context: Int, to ids: [String]) async throws(LeaderboardError)
    /// The leaderboards in `ids` that this backend knows, or all of them for
    /// nil.
    func loadLeaderboards(_ ids: [String]?) async throws(LeaderboardError) -> [LeaderboardInfo]
    /// One leaderboard's scores at the positions in `range` (1-based), the
    /// local player's, and how many there are. A nil range loads only the
    /// local player's.
    func loadScores(
        _ id: String, timeSpan: LeaderboardTimeSpan, collection: LeaderboardCollection, range: ClosedRange<Int>?
    ) async throws(LeaderboardError) -> LeaderboardScores
    /// Whether `showLeaderboards` can show anything here.
    var hasDashboard: Bool { get }
    /// The leaderboards over the game: one by its Game Center ID, or all of
    /// them for nil.
    func showLeaderboards(_ id: String?, timeSpan: LeaderboardTimeSpan, collection: LeaderboardCollection)
}

public extension LeaderboardsBackend {
    /// Whether the score arrived, for a caller with no use for the reason.
    func submit(_ score: Int, context: Int, to ids: [String]) async -> Bool {
        do {
            try await submitScore(score, context: context, to: ids)
            return true
        } catch {
            return false
        }
    }

    func showDashboard(leaderboardID: String?) {
        showLeaderboards(leaderboardID, timeSpan: .allTime, collection: .public)
    }
}

/// Why a leaderboard call failed. GameKit reports each as a `GKError`.
public enum LeaderboardError: Error, Equatable, Sendable {
    /// Nobody is signed in (`.notAuthenticated`).
    case signedOut
    /// The service can't run on this device, or there is none
    /// (`.notSupported`).
    case unavailable
    /// A leaderboard the backend has no counterpart for
    /// (`.invalidParameter`).
    case unknownLeaderboard
    /// The service said no, or didn't answer in time
    /// (`.communicationsFailure`).
    case failed
}

/// Game Center's time scope, as Play names it.
public enum LeaderboardTimeSpan: String, Sendable {
    case daily, weekly, allTime
}

/// Game Center's player scope, as Play names it.
public enum LeaderboardCollection: String, Sendable {
    case `public`, friends
}

/// A leaderboard by its Game Center ID, with the title the service gives it.
public struct LeaderboardInfo: Equatable, Sendable {
    public var id: String
    public var title: String?

    public init(id: String, title: String?) {
        self.id = id
        self.title = title
    }
}

/// One player's score on a leaderboard.
public struct LeaderboardScore: Equatable, Sendable {
    public var rank: Int
    public var score: Int
    public var formattedScore: String
    public var context: Int
    public var date: Date
    public var playerID: String
    public var playerName: String

    public init(
        rank: Int, score: Int, formattedScore: String, context: Int, date: Date, playerID: String, playerName: String
    ) {
        self.rank = rank
        self.score = score
        self.formattedScore = formattedScore
        self.context = context
        self.date = date
        self.playerID = playerID
        self.playerName = playerName
    }
}

public struct LeaderboardScores: Equatable, Sendable {
    public var local: LeaderboardScore?
    public var entries: [LeaderboardScore]
    public var total: Int

    public init(local: LeaderboardScore?, entries: [LeaderboardScore], total: Int) {
        self.local = local
        self.entries = entries
        self.total = total
    }
}

/// No leaderboards at all.
public final class LocalLeaderboards: LeaderboardsBackend {
    public init() {}

    public func submitScore(_ score: Int, context: Int, to ids: [String]) async throws(LeaderboardError) {
        throw .unavailable
    }

    public func loadLeaderboards(_ ids: [String]?) async throws(LeaderboardError) -> [LeaderboardInfo] {
        throw .unavailable
    }

    public func loadScores(
        _ id: String, timeSpan: LeaderboardTimeSpan, collection: LeaderboardCollection, range: ClosedRange<Int>?
    ) async throws(LeaderboardError) -> LeaderboardScores {
        throw .unavailable
    }

    public var hasDashboard: Bool { false }
    public func showLeaderboards(_ id: String?, timeSpan: LeaderboardTimeSpan, collection: LeaderboardCollection) {}
}
