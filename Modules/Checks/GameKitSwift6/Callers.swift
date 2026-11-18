// Compiles only: game code in the Swift 6 language mode awaiting each of
// GameKit's asynchronous leaderboard calls from nonisolated code, as it can
// against Apple's GameKit.
import Foundation
import GameKit
import UIKit

nonisolated func loadAll() async throws -> [GKLeaderboard] {
    try await GKLeaderboard.loadLeaderboards(IDs: nil)
}

nonisolated func submitEverywhere(_ score: Int) async throws {
    try await GKLeaderboard.submitScore(score, context: 0, player: GKLocalPlayer.local, leaderboardIDs: ["a", "b"])
}

nonisolated func submit(_ score: Int, to board: GKLeaderboard) async throws {
    try await board.submitScore(score, context: 7, player: GKLocalPlayer.local)
}

nonisolated func top(of board: GKLeaderboard) async throws -> (GKLeaderboard.Entry?, [GKLeaderboard.Entry], Int) {
    try await board.loadEntries(for: .global, timeScope: .allTime, range: NSRange(location: 1, length: 10))
}

nonisolated func mine(on board: GKLeaderboard) async throws -> GKLeaderboard.Entry? {
    let (local, _) = try await board.loadEntries(for: [GKLocalPlayer.local], timeScope: .week)
    return local
}

nonisolated func firstRank() async throws -> Int {
    guard let board = try await GKLeaderboard.loadLeaderboards(IDs: ["a"]).first else { return 0 }
    let (_, entries, _) = try await board.loadEntries(for: .friendsOnly, timeScope: .today, range: NSRange(1...25))
    try await board.submitScore(1, context: 0, player: GKLocalPlayer.local)
    return entries.first?.rank ?? 0
}

nonisolated func signedOut() async -> Bool {
    do {
        try await GKLeaderboard.submitScore(1, context: 0, player: GKLocalPlayer.local, leaderboardIDs: ["a"])
        return false
    } catch GKError.notAuthenticated {
        return true
    } catch {
        return false
    }
}

// On the main actor, the leaderboards and entries stay usable across awaits.
@MainActor func fromMain() async throws -> Int {
    var ranks = 0
    for board in try await GKLeaderboard.loadLeaderboards(IDs: nil) {
        let (local, entries, total) = try await board.loadEntries(for: .global, timeScope: .allTime, range: NSRange(location: 1, length: 5))
        let (mine, _) = try await board.loadEntries(for: [GKLocalPlayer.local], timeScope: .allTime)
        try await board.submitScore(100, context: 7, player: GKLocalPlayer.local)
        board.submitScore(100, context: 0, player: GKLocalPlayer.local) { _ in }
        ranks += (local?.rank ?? 0) + entries.count + total + (mine?.rank ?? 0)
    }
    return ranks
}

@MainActor final class Controller: UIViewController, GKGameCenterControllerDelegate {
    func show() {
        let controller = GKGameCenterViewController(leaderboardID: "a", playerScope: .global, timeScope: .week)
        controller.gameCenterDelegate = self
        present(controller, animated: true)
    }

    nonisolated func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
        MainActor.assumeIsolated { gameCenterViewController.dismiss(animated: true) }
    }
}

final class Delegate: NSObject, GKGameCenterControllerDelegate {
    nonisolated func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
        Task { @MainActor in gameCenterViewController.dismiss(animated: true, completion: nil) }
    }
}
