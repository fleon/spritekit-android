import Foundation
import Testing
@testable import PlatformShim

// Play Games leaderboards behind the Game Center-shaped backend: Game Center
// IDs mapped to Play's, a context kept as Play's score tag, and answers
// matched to their requests.

private let mapping = PlayGamesMapping(
    applicationID: "123456789012",
    achievements: [:],
    leaderboards: ["gc.stars": "play-stars", "gc.levels": "play-levels"]
)

@Suite("Play Games leaderboards")
@MainActor
struct LeaderboardsTests {
    @Test("The generated mapping reads leaderboards beside achievements, and a game without them reads as before")
    func mappingFile() {
        let json = #"{"applicationId":"123","achievements":{"a":{"id":"P1"}},"leaderboards":{"gc.stars":{"id":"L1"},"gc.empty":{"id":""}}}"#
        let read = PlayGamesMapping(data: Data(json.utf8))
        #expect(read?.leaderboards == ["gc.stars": "L1"])
        let old = PlayGamesMapping(data: Data(#"{"applicationId":"123","achievements":{}}"#.utf8))
        #expect(old?.leaderboards == [:])
    }

    @Test("A score goes to every named leaderboard by Play's ID, and arrives when Java says so")
    func submit() async {
        let java = FakeJava()
        java.answers["games.available"] = ["available": true]
        let boards = PlayGamesLeaderboards(channel: java.channel, mapping: mapping)
        let result = Task { await boards.submit(42, context: 7, to: ["gc.stars", "gc.levels"]) }
        await java.waitFor("games.submitScores")
        let arguments = java.calls.last?.arguments ?? [:]
        let items = arguments["items"] as? [[String: Any]] ?? []
        #expect(items.compactMap { $0["id"] as? String } == ["play-stars", "play-levels"])
        #expect(items.allSatisfy { $0["score"] as? Int == 42 && $0["tag"] as? String == "7" })
        let request = arguments["request"] as? Int ?? -1
        java.send("games", "scoresSubmitted", ["request": request + 1, "ok": false])
        java.send("games", "scoresSubmitted", ["request": request, "ok": true])
        #expect(await result.value)
    }

    @Test("Signed out, Java answers no, and so does the submission")
    func signedOut() async {
        let java = FakeJava()
        let boards = PlayGamesLeaderboards(channel: java.channel, mapping: mapping)
        let result = Task { await boards.submit(1, context: 0, to: ["gc.stars"]) }
        await java.waitFor("games.submitScores")
        let request = java.calls.last?.arguments["request"] as? Int ?? -1
        #expect((java.calls.last?.arguments["items"] as? [[String: Any]])?.first?["tag"] as? String == "")
        java.send("games", "scoresSubmitted", ["request": request, "ok": false])
        #expect(await result.value == false)
    }

    @Test("A leaderboard Play doesn't know is not sent, and the submission says it didn't all arrive")
    func unknownLeaderboard() async {
        let java = FakeJava()
        let boards = PlayGamesLeaderboards(channel: java.channel, mapping: mapping)
        #expect(await boards.submit(5, context: 0, to: ["gc.unknown"]) == false)
        #expect(java.count("games.submitScores") == 0)
        let result = Task { await boards.submit(5, context: 0, to: ["gc.stars", "gc.unknown"]) }
        await java.waitFor("games.submitScores")
        let request = java.calls.last?.arguments["request"] as? Int ?? -1
        java.send("games", "scoresSubmitted", ["request": request, "ok": true])
        #expect(await result.value == false)
    }

    @Test("The dashboard opens one leaderboard or all, and only where Play Games runs")
    func dashboard() {
        let java = FakeJava()
        java.answers["games.available"] = ["available": true]
        let boards = PlayGamesLeaderboards(channel: java.channel, mapping: mapping)
        #expect(boards.hasDashboard)
        boards.showDashboard(leaderboardID: "gc.levels")
        #expect(java.calls.last?.name == "games.showLeaderboards")
        #expect(java.calls.last?.arguments["id"] as? String == "play-levels")
        boards.showDashboard(leaderboardID: nil)
        #expect(java.calls.last?.arguments.isEmpty == true)
        boards.showDashboard(leaderboardID: "gc.unknown")
        #expect(java.count("games.showLeaderboards") == 2)

        let offline = FakeJava()
        let none = PlayGamesLeaderboards(channel: offline.channel, mapping: mapping)
        #expect(!none.hasDashboard)
        none.showDashboard(leaderboardID: nil)
        #expect(offline.count("games.showLeaderboards") == 0)
    }

    @Test("Without Play Games nothing is kept")
    func local() async {
        let local = LocalLeaderboards()
        #expect(await local.submit(1, context: 0, to: ["gc.stars"]) == false)
        #expect(!local.hasDashboard)
    }
}
