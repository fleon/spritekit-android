#if !SPRITEKIT_SHIM
import Foundation
import GameKit
import UIKit

/// GameKit behind `LeaderboardsBackend`: scores sent and loaded, and Game
/// Center's leaderboards over the game.
public final class GameKitLeaderboards: LeaderboardsBackend {
    /// Where the access point opens its overlay; the key window when nil.
    public var dashboardWindow: UIWindow?

    public init() {}

    public func submitScore(_ score: Int, context: Int, to ids: [String]) async throws(LeaderboardError) {
        let local = GKLocalPlayer.local
        guard local.isAuthenticated else { throw .signedOut }
        do {
            try await GKLeaderboard.submitScore(score, context: context, player: local, leaderboardIDs: ids)
        } catch {
            throw Self.leaderboardError(error)
        }
    }

    public func loadLeaderboards(_ ids: [String]?) async throws(LeaderboardError) -> [LeaderboardInfo] {
        guard GKLocalPlayer.local.isAuthenticated else { throw .signedOut }
        do {
            return try await GKLeaderboard.loadLeaderboards(IDs: ids).map {
                LeaderboardInfo(id: $0.baseLeaderboardID, title: $0.title)
            }
        } catch {
            throw Self.leaderboardError(error)
        }
    }

    /// A nil range loads the local player's score alone, with the count.
    public func loadScores(
        _ id: String, timeSpan: LeaderboardTimeSpan, collection: LeaderboardCollection, range: ClosedRange<Int>?
    ) async throws(LeaderboardError) -> LeaderboardScores {
        guard GKLocalPlayer.local.isAuthenticated else { throw .signedOut }
        do {
            guard let board = try await GKLeaderboard.loadLeaderboards(IDs: [id]).first else { throw LeaderboardError.unknownLeaderboard }
            let span = range ?? 1...1
            let (local, entries, total) = try await board.loadEntries(
                for: Self.playerScope(collection),
                timeScope: Self.timeScope(timeSpan),
                range: NSRange(location: span.lowerBound, length: span.count)
            )
            return LeaderboardScores(
                local: local.map(Self.score),
                entries: range == nil ? [] : entries.map(Self.score),
                total: total
            )
        } catch let error as LeaderboardError {
            throw error
        } catch {
            throw Self.leaderboardError(error)
        }
    }

    public var hasDashboard: Bool { GKLocalPlayer.local.isAuthenticated }

    public func showLeaderboards(_ id: String?, timeSpan: LeaderboardTimeSpan, collection: LeaderboardCollection) {
        guard hasDashboard else { return }
        let accessPoint = GKAccessPoint.shared
        accessPoint.parentWindow = dashboardWindow ?? TopViewController.keyWindow
        guard let id else {
            accessPoint.trigger(state: .leaderboards) {}
            return
        }
        if #available(iOS 18.0, tvOS 18.0, macCatalyst 18.0, *) {
            accessPoint.trigger(leaderboardID: id, playerScope: Self.playerScope(collection), timeScope: Self.timeScope(timeSpan)) {}
            return
        }
        let controller = GKGameCenterViewController(
            leaderboardID: id, playerScope: Self.playerScope(collection), timeScope: Self.timeScope(timeSpan)
        )
        controller.gameCenterDelegate = Dismisser.shared
        TopViewController.present(controller)
    }

    private static func playerScope(_ collection: LeaderboardCollection) -> GKLeaderboard.PlayerScope {
        switch collection {
        case .public: .global
        case .friends: .friendsOnly
        }
    }

    private static func timeScope(_ span: LeaderboardTimeSpan) -> GKLeaderboard.TimeScope {
        switch span {
        case .daily: .today
        case .weekly: .week
        case .allTime: .allTime
        }
    }

    private static func score(_ entry: GKLeaderboard.Entry) -> LeaderboardScore {
        LeaderboardScore(
            rank: entry.rank,
            score: entry.score,
            formattedScore: entry.formattedScore,
            context: entry.context,
            date: entry.date,
            playerID: entry.player.gamePlayerID,
            playerName: entry.player.displayName
        )
    }

    private static func leaderboardError(_ error: Error) -> LeaderboardError {
        guard let error = error as? GKError else { return .failed }
        switch error.code {
        case .notAuthenticated: return .signedOut
        case .notSupported, .apiNotAvailable: return .unavailable
        case .invalidParameter: return .unknownLeaderboard
        default: return .failed
        }
    }
}

/// Closes the leaderboard sheet shown before iOS 18's access point could.
private final class Dismisser: NSObject, GKGameCenterControllerDelegate {
    static let shared = Dismisser()

    func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
        gameCenterViewController.dismiss(animated: true)
    }
}
#endif
