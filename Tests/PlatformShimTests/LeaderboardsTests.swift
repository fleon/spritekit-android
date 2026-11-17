import Foundation
import Testing
@testable import PlatformShim

// Play Games leaderboards behind the Game Center-shaped backend: Game Center
// IDs mapped to Play's, a context kept as Play's score tag, answers matched
// to their requests, and every request answered.

private let mapping = PlayGamesMapping(
    applicationID: "123456789012",
    achievements: [:],
    leaderboards: ["leaderboard.high-score": "play-high-score", "leaderboard.levels": "play-levels"]
)

/// Play Games with a clock the test runs by hand.
@MainActor
private final class FakePlayGames {
    let java = FakeJava()
    private(set) var later: [(delay: TimeInterval, work: () -> Void)] = []
    private(set) lazy var boards = PlayGamesLeaderboards(channel: java.channel, mapping: mapping) { [unowned self] delay, work in
        later.append((delay, work))
    }

    init(available: Bool = true) {
        if available { java.answers["games.available"] = ["available": true] }
        // Listening from the start, as the game installs it at launch.
        _ = boards
    }

    func signIn(_ signedIn: Bool) {
        java.send("games", "signIn", ["signedIn": signedIn])
    }

    var lastRequest: Int { java.calls.last?.arguments["request"] as? Int ?? -1 }

    /// Lets every timeout pass.
    func timeOut() {
        let work = later
        later = []
        work.forEach { $0.work() }
    }
}

/// What `work` failed with, or nil once it succeeded.
private func failure(_ work: @escaping @MainActor () async throws -> Void) -> Task<LeaderboardError?, Never> {
    Task { @MainActor in
        do {
            try await work()
            return nil
        } catch {
            return error as? LeaderboardError
        }
    }
}

@Suite("Play Games leaderboards")
@MainActor
struct LeaderboardsTests {
    @Test("The generated mapping reads leaderboards beside achievements, and a game without them reads as before")
    func mappingFile() {
        let json = #"{"applicationId":"123","achievements":{"a":{"id":"P1"}},"leaderboards":{"leaderboard.high-score":{"id":"L1"},"leaderboard.empty":{"id":""}}}"#
        let read = PlayGamesMapping(data: Data(json.utf8))
        #expect(read?.leaderboards == ["leaderboard.high-score": "L1"])
        let old = PlayGamesMapping(data: Data(#"{"applicationId":"123","achievements":{}}"#.utf8))
        #expect(old?.leaderboards == [:])
    }

    @Test("A score goes to every named leaderboard by Play's ID, and arrives when Java says so")
    func submit() async {
        let play = FakePlayGames()
        let result = failure {
            try await play.boards.submitScore(42, context: 7, to: ["leaderboard.high-score", "leaderboard.levels"])
        }
        await play.java.waitFor("games.submitScores")
        let items = play.java.calls.last?.arguments["items"] as? [[String: Any]] ?? []
        #expect(items.compactMap { $0["id"] as? String } == ["play-high-score", "play-levels"])
        #expect(items.allSatisfy { $0["score"] as? Int == 42 && $0["tag"] as? String == "7" })
        let request = play.lastRequest
        play.java.send("games", "scoresSubmitted", ["request": request + 1, "ok": false])
        play.java.send("games", "scoresSubmitted", ["request": request, "ok": true])
        #expect(await result.value == nil)
        #expect(play.later.map(\.delay) == [PlayGamesLeaderboards.timeout])
        // The timeout after the answer changes nothing.
        play.timeOut()
    }

    @Test("Known signed out, a submission fails at once without asking Java")
    func signedOut() async {
        let play = FakePlayGames()
        play.signIn(false)
        let error = await failure {
            try await play.boards.submitScore(1, context: 0, to: ["leaderboard.high-score"])
        }.value
        #expect(error == .signedOut)
        #expect(play.java.count("games.submitScores") == 0)
        #expect(await play.boards.submit(1, context: 0, to: ["leaderboard.high-score"]) == false)
    }

    @Test("Java's signed-out answer fails the submission as signed out; any other no as failed")
    func javaSaysNo() async {
        let play = FakePlayGames()
        let first = failure {
            try await play.boards.submitScore(1, context: 0, to: ["leaderboard.high-score"])
        }
        await play.java.waitFor("games.submitScores")
        #expect((play.java.calls.last?.arguments["items"] as? [[String: Any]])?.first?["tag"] as? String == "")
        play.java.send("games", "scoresSubmitted", ["request": play.lastRequest, "ok": false, "reason": "signedOut"])
        #expect(await first.value == .signedOut)

        play.signIn(true)
        let second = failure {
            try await play.boards.submitScore(1, context: 0, to: ["leaderboard.high-score"])
        }
        await play.java.waitFor("games.submitScores", times: 2)
        play.java.send("games", "scoresSubmitted", ["request": play.lastRequest, "ok": false])
        #expect(await second.value == .failed)
    }

    @Test("A submission Java never answers fails once the timeout passes")
    func timeout() async {
        let play = FakePlayGames()
        play.signIn(true)
        let result = failure {
            try await play.boards.submitScore(3, context: 0, to: ["leaderboard.high-score"])
        }
        await play.java.waitFor("games.submitScores")
        play.timeOut()
        #expect(await result.value == .failed)
        // A late answer finds nothing waiting.
        play.java.send("games", "scoresSubmitted", ["request": play.lastRequest, "ok": true])
    }

    @Test("Signing out fails every submission still waiting")
    func signOutWhileWaiting() async {
        let play = FakePlayGames()
        play.signIn(true)
        let first = failure {
            try await play.boards.submitScore(1, context: 0, to: ["leaderboard.high-score"])
        }
        let second = failure {
            try await play.boards.submitScore(2, context: 0, to: ["leaderboard.levels"])
        }
        await play.java.waitFor("games.submitScores", times: 2)
        play.signIn(false)
        #expect(await first.value == .signedOut)
        #expect(await second.value == .signedOut)
    }

    @Test("Without Play Games on the device, a submission fails at once as unavailable")
    func unavailable() async {
        let play = FakePlayGames(available: false)
        let error = await failure {
            try await play.boards.submitScore(1, context: 0, to: ["leaderboard.high-score"])
        }.value
        #expect(error == .unavailable)
        #expect(play.java.count("games.submitScores") == 0)
    }

    @Test("A leaderboard Play doesn't know is not sent, and the submission says so")
    func unknownLeaderboard() async {
        let play = FakePlayGames()
        let none = await failure {
            try await play.boards.submitScore(5, context: 0, to: ["leaderboard.unknown"])
        }.value
        #expect(none == .unknownLeaderboard)
        #expect(play.java.count("games.submitScores") == 0)
        let some = failure {
            try await play.boards.submitScore(5, context: 0, to: ["leaderboard.high-score", "leaderboard.unknown"])
        }
        await play.java.waitFor("games.submitScores")
        play.java.send("games", "scoresSubmitted", ["request": play.lastRequest, "ok": true])
        #expect(await some.value == .unknownLeaderboard)
    }

    @Test("Leaderboards load by Game Center ID, titled by Play")
    func loadLeaderboards() async throws {
        let play = FakePlayGames()
        let all = Task { try await play.boards.loadLeaderboards(nil) }
        await play.java.waitFor("games.loadLeaderboards")
        #expect(play.java.calls.last?.arguments["ids"] == nil)
        play.java.send("games", "leaderboards", [
            "request": play.lastRequest, "ok": true,
            "items": [["id": "play-levels", "title": "Levels"], ["id": "play-other", "title": "Other"]],
        ])
        #expect(try await all.value == [
            LeaderboardInfo(id: "leaderboard.high-score", title: nil),
            LeaderboardInfo(id: "leaderboard.levels", title: "Levels"),
        ])

        let some = Task { try await play.boards.loadLeaderboards(["leaderboard.high-score", "leaderboard.unknown"]) }
        await play.java.waitFor("games.loadLeaderboards", times: 2)
        #expect(play.java.calls.last?.arguments["ids"] as? [String] == ["play-high-score"])
        play.java.send("games", "leaderboards", [
            "request": play.lastRequest, "ok": true, "items": [["id": "play-high-score", "title": "High Score"]],
        ])
        #expect(try await some.value == [LeaderboardInfo(id: "leaderboard.high-score", title: "High Score")])
    }

    @Test("Scores load for a range of ranks, with the local player's and the total")
    func loadScores() async throws {
        let play = FakePlayGames()
        func score(_ rank: Int, _ player: String) -> [String: Any] {
            ["rank": rank, "score": 1000 - rank, "formattedScore": "\(1000 - rank) pts", "tag": "9",
             "time": 1_790_000_000_000.0, "playerId": player, "name": "Player \(rank)"]
        }
        let result = Task {
            try await play.boards.loadScores("leaderboard.levels", timeSpan: .weekly, collection: .friends, range: 2...3)
        }
        await play.java.waitFor("games.loadScores")
        let arguments = play.java.calls.last?.arguments ?? [:]
        #expect(arguments["id"] as? String == "play-levels")
        #expect(arguments["timeSpan"] as? String == "weekly")
        #expect(arguments["collection"] as? String == "friends")
        #expect(arguments["count"] as? Int == 3)
        play.java.send("games", "scores", [
            "request": play.lastRequest, "ok": true, "total": 40,
            "items": [score(1, "p1"), score(2, "p2"), score(3, "p3")], "local": score(2, "p2"),
        ])
        let scores = try await result.value
        #expect(scores.entries.map(\.playerID) == ["p2", "p3"])
        #expect(scores.entries.first == LeaderboardScore(
            rank: 2, score: 998, formattedScore: "998 pts", context: 9,
            date: Date(timeIntervalSince1970: 1_790_000_000), playerID: "p2", playerName: "Player 2"
        ))
        #expect(scores.local?.playerID == "p2")
        #expect(scores.total == 40)

        let localOnly = Task {
            try await play.boards.loadScores("leaderboard.levels", timeSpan: .allTime, collection: .public, range: nil)
        }
        await play.java.waitFor("games.loadScores", times: 2)
        #expect(play.java.calls.last?.arguments["count"] as? Int == 0)
        play.java.send("games", "scores", ["request": play.lastRequest, "ok": true, "items": [[String: Any]](), "total": -1])
        let none = try await localOnly.value
        #expect(none == LeaderboardScores(local: nil, entries: [], total: 0))
    }

    @Test("Loads answer like submissions: unknown, signed out, timed out")
    func loadFailures() async {
        let play = FakePlayGames()
        let unknown = Task { try await play.boards.loadScores("leaderboard.unknown", timeSpan: .allTime, collection: .public, range: 1...10) }
        #expect(await unknown.result.leaderboardError == .unknownLeaderboard)
        let waiting = Task { try await play.boards.loadLeaderboards(nil) }
        await play.java.waitFor("games.loadLeaderboards")
        play.timeOut()
        #expect(await waiting.result.leaderboardError == .failed)
        play.signIn(false)
        let signedOut = Task { try await play.boards.loadScores("leaderboard.levels", timeSpan: .allTime, collection: .public, range: 1...10) }
        #expect(await signedOut.result.leaderboardError == .signedOut)
    }

    @Test("The leaderboards open one, with its time span and collection, or all, and only where Play Games runs")
    func dashboard() {
        let play = FakePlayGames()
        let java = play.java
        #expect(play.boards.hasDashboard)
        play.boards.showLeaderboards("leaderboard.levels", timeSpan: .daily, collection: .friends)
        #expect(java.calls.last?.name == "games.showLeaderboards")
        #expect(java.calls.last?.arguments["id"] as? String == "play-levels")
        #expect(java.calls.last?.arguments["timeSpan"] as? String == "daily")
        #expect(java.calls.last?.arguments["collection"] as? String == "friends")
        play.boards.showDashboard(leaderboardID: nil)
        #expect(java.calls.last?.arguments.isEmpty == true)
        play.boards.showDashboard(leaderboardID: "leaderboard.unknown")
        #expect(java.count("games.showLeaderboards") == 2)

        let offline = FakePlayGames(available: false)
        #expect(!offline.boards.hasDashboard)
        offline.boards.showDashboard(leaderboardID: nil)
        #expect(offline.java.count("games.showLeaderboards") == 0)
    }

    @Test("Without Play Games nothing is kept, and every call answers unavailable")
    func local() async {
        let local = LocalLeaderboards()
        #expect(await local.submit(1, context: 0, to: ["leaderboard.high-score"]) == false)
        let error = await failure {
            try await local.submitScore(1, context: 0, to: ["leaderboard.high-score"])
        }.value
        #expect(error == .unavailable)
        #expect(!local.hasDashboard)
    }

    @Test("A context travels as its digits, and comes back")
    func context() {
        #expect(PlayGamesLeaderboards.tag(0) == "")
        #expect(PlayGamesLeaderboards.tag(Int.max) == String(Int.max))
        #expect(PlayGamesLeaderboards.context(PlayGamesLeaderboards.tag(-5)) == -5)
        #expect(PlayGamesLeaderboards.context(nil) == 0)
        #expect(PlayGamesLeaderboards.context("not-a-number") == 0)
    }
}

private extension Result {
    var leaderboardError: LeaderboardError? {
        if case .failure(let error) = self { return error as? LeaderboardError }
        return nil
    }
}
