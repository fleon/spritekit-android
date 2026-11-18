// Compiles only: game code in the Swift 5 language mode, as against Apple's
// GameKit: a delegate object dismissing Game Center's controller, and the
// asynchronous leaderboard calls awaited from nonisolated code.
import Foundation
import GameKit
import UIKit

final class GameCenterHelper: NSObject, GKGameCenterControllerDelegate {
    func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
        gameCenterViewController.dismiss(animated: true, completion: nil)
    }
}

func makeHelper() -> GameCenterHelper { GameCenterHelper() }

func loadAndSubmit() async throws -> Int {
    let boards = try await GKLeaderboard.loadLeaderboards(IDs: ["a"])
    guard let board = boards.first else { return 0 }
    try await GKLeaderboard.submitScore(1, context: 0, player: GKLocalPlayer.local, leaderboardIDs: ["a"])
    try await board.submitScore(1, context: 0, player: GKLocalPlayer.local)
    let (_, entries, total) = try await board.loadEntries(for: .global, timeScope: .allTime, range: NSRange(location: 1, length: 10))
    let (local, _) = try await board.loadEntries(for: [GKLocalPlayer.local], timeScope: .allTime)
    return entries.count + total + (local?.rank ?? 0)
}

func withHandlers() {
    GKLeaderboard.loadLeaderboards(IDs: nil) { boards, error in
        guard error == nil, let board = boards?.first else { return }
        board.loadEntries(for: .global, timeScope: .week, range: NSRange(location: 1, length: 10)) { _, entries, _, _ in
            print(entries?.count ?? 0)
        }
        board.loadEntries(for: [GKLocalPlayer.local], timeScope: .today) { local, _, _ in
            print(local?.rank ?? 0)
        }
        board.submitScore(1, context: 0, player: GKLocalPlayer.local) { _ in }
    }
}
