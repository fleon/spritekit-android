// Compiles only: game code in the Swift 5 language mode with the main actor
// as its default isolation, awaiting GameKit's asynchronous leaderboard
// calls from code it marks nonisolated, as against Apple's GameKit.
import Foundation
import GameKit
import UIKit

nonisolated func loadAll() async throws -> Int {
    try await GKLeaderboard.loadLeaderboards(IDs: nil).count
}

nonisolated func submitTo(_ board: GKLeaderboard) async throws {
    try await GKLeaderboard.submitScore(1, context: 0, player: GKLocalPlayer.local, leaderboardIDs: ["a"])
    try await board.submitScore(1, context: 0, player: GKLocalPlayer.local)
}

nonisolated func ranks(on board: GKLeaderboard) async throws -> Int {
    let (_, entries, _) = try await board.loadEntries(for: .global, timeScope: .allTime, range: NSRange(location: 1, length: 5))
    let (local, _) = try await board.loadEntries(for: [GKLocalPlayer.local], timeScope: .allTime)
    return (entries.first?.rank ?? 0) + (local?.rank ?? 0)
}

final class GameCenterHelper: NSObject, GKGameCenterControllerDelegate {
    func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
        gameCenterViewController.dismiss(animated: true, completion: nil)
    }
}
