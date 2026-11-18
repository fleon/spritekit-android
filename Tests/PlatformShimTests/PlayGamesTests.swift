import Foundation
import Testing
@testable import PlatformShim

// Play Games behind the Game Center-shaped backend: the ID mapping, the
// percent-to-steps conversion, and the sign-in a game's launch may wait on.

private let mapping = PlayGamesMapping(applicationID: "123456789012", achievements: [
    "gc.levels.1": .init(id: "play-first"),
    "gc.world.first": .init(id: "play-world", steps: 30),
    "gc.levels.all": .init(id: "play-all", steps: 100),
])

@Suite("Play Games")
@MainActor
struct PlayGamesTests {
    @Test("The generated mapping reads, and an empty project ID means no Play Games")
    func mappingFile() {
        let json = #"{"applicationId":"123","achievements":{"a":{"id":"P1","steps":10},"b":{"id":"P2"},"c":{"id":""}}}"#
        let read = PlayGamesMapping(data: Data(json.utf8))
        #expect(read?.applicationID == "123")
        #expect(read?.achievements == ["a": .init(id: "P1", steps: 10), "b": .init(id: "P2")])
        #expect(PlayGamesMapping(data: Data(#"{"applicationId":"","achievements":{}}"#.utf8)) == nil)
    }

    @Test("Whole percentages turn back into the count that made them")
    func percentToSteps() {
        let world = mapping.achievements["gc.world.first"]!
        for cleared in 0...30 {
            let percent = (Double(cleared) / 30 * 100).rounded(.down)
            let report = mapping.report(percent, for: world)
            #expect(report?.steps ?? 0 == cleared)
        }
        let first = mapping.achievements["gc.levels.1"]!
        #expect(mapping.report(50, for: first) == nil)
        #expect(mapping.report(100, for: first)?.unlock == true)
        #expect(mapping.percent(unlocked: false, currentSteps: 7, of: world) == 23)
        #expect(mapping.percent(unlocked: true, currentSteps: 0, of: first) == 100)
    }

    @Test("Sign-in answers once at launch, and again when the player signs in later")
    func signIn() {
        let java = FakeJava()
        let games = PlayGamesAchievements(channel: java.channel, mapping: mapping)
        var answers = 0
        var signedIn: [Bool] = []
        games.signInChanged = { signedIn.append($0) }
        games.start { answers += 1 }
        #expect(java.names == ["games.available", "games.start"])
        java.send("games", "signIn", ["signedIn": false, "configured": true])
        #expect(answers == 1)
        #expect(!games.isSignedIn)
        java.send("games", "signIn", ["signedIn": false, "configured": true])
        #expect(answers == 1)
        java.send("games", "signIn", ["signedIn": true, "configured": true])
        #expect(answers == 2)
        #expect(games.isSignedIn)
        #expect(signedIn == [true])
    }

    @Test("Progress goes to Play as unlocks and steps, by Play's IDs")
    func report() async {
        let java = FakeJava()
        let games = PlayGamesAchievements(channel: java.channel, mapping: mapping)
        games.start {}
        java.send("games", "signIn", ["signedIn": true])
        let result = Task { await games.report(["gc.levels.1": 100, "gc.world.first": 23, "gc.unknown": 100], showingBanners: true) }
        await java.waitFor("games.report")
        let items = java.calls.last?.arguments["items"] as? [[String: Any]] ?? []
        #expect(items.count == 2)
        #expect(items.first { $0["id"] as? String == "play-first" }?["unlock"] as? Bool == true)
        #expect(items.first { $0["id"] as? String == "play-world" }?["steps"] as? Int == 7)
        let request = java.calls.last?.arguments["request"] as? Int ?? -1
        java.send("games", "reported", ["request": request, "ok": true])
        #expect(await result.value)
    }

    @Test("Signed out, nothing is sent and the report says it didn't arrive")
    func signedOut() async {
        let java = FakeJava()
        let games = PlayGamesAchievements(channel: java.channel, mapping: mapping)
        games.start {}
        java.send("games", "signIn", ["signedIn": false])
        #expect(await games.report(["gc.levels.1": 100], showingBanners: false) == false)
        #expect(await games.load().isEmpty)
        #expect(await games.localPlayer() == nil)
        #expect(java.count("games.report") == 0)
    }

    @Test("What Play holds comes back as Game Center percentages")
    func load() async {
        let java = FakeJava()
        let games = PlayGamesAchievements(channel: java.channel, mapping: mapping)
        games.start {}
        java.send("games", "signIn", ["signedIn": true])
        let held = Task { await games.load() }
        await java.waitFor("games.loadAchievements")
        java.send("games", "achievements", ["ok": true, "items": [
            ["id": "play-first", "unlocked": true],
            ["id": "play-world", "unlocked": false, "currentSteps": 15, "totalSteps": 30],
            ["id": "someone-else", "unlocked": true],
        ]])
        #expect(await held.value == ["gc.levels.1": 100, "gc.world.first": 50])
    }

    @Test("The player's ID and name follow sign-in")
    func identity() {
        let java = FakeJava()
        let games = PlayGamesAchievements(channel: java.channel, mapping: mapping)
        var changes: [String?] = []
        var players: [GamePlayer?] = []
        games.identityChanged = { changes.append($0?.id) }
        games.playerChanged = { players.append($0) }
        games.start {}
        java.send("games", "identity", ["id": "early", "name": "Nobody"])
        #expect(games.identity == nil)
        java.send("games", "signIn", ["signedIn": true])
        java.send("games", "identity", ["id": "g123", "name": "Zoë 🦊"])
        #expect(games.identity?.id == "g123")
        #expect(games.identity?.name == "Zoë 🦊")
        #expect(games.player == GamePlayer(id: "g123", name: "Zoë 🦊"))
        java.send("games", "signIn", ["signedIn": false])
        #expect(games.identity == nil)
        #expect(games.player == nil)
        #expect(changes == ["g123", nil])
        #expect(players == [GamePlayer(id: "g123", name: "Zoë 🦊"), nil])
    }

    @Test("The player's name and picture come through for a credit")
    func player() async {
        let java = FakeJava()
        let games = PlayGamesAchievements(channel: java.channel, mapping: mapping)
        games.start {}
        java.send("games", "signIn", ["signedIn": true])
        let player = Task { await games.localPlayer() }
        await java.waitFor("games.player")
        java.send("games", "player", ["ok": true, "name": "Zoë 🦊", "photo": Data([1, 2, 3]).base64EncodedString()])
        let answer = await player.value
        #expect(answer?.name == "Zoë 🦊")
        #expect(answer?.photo == Data([1, 2, 3]))
    }

    @Test("The dashboard stands where Play Games can run, and opens signed out")
    func dashboard() {
        let java = FakeJava()
        java.answers["games.available"] = ["available": true]
        let games = PlayGamesAchievements(channel: java.channel, mapping: mapping)
        #expect(java.names == ["games.available"])
        #expect(games.hasDashboard)
        games.start {}
        java.send("games", "signIn", ["signedIn": false, "configured": true])
        // Signed out, the game still opens it: Java signs the player in first.
        #expect(!games.isSignedIn)
        #expect(games.opensDashboard)
        games.showDashboard()
        #expect(java.names.last == "games.showAchievements")
    }

    @Test("Without Play Games on the device there's no dashboard to open")
    func noDashboard() {
        for answer in [nil, ["available": false]] as [[String: Any]?] {
            let java = FakeJava()
            if let answer { java.answers["games.available"] = answer }
            let games = PlayGamesAchievements(channel: java.channel, mapping: mapping)
            #expect(!games.hasDashboard)
            #expect(!games.opensDashboard)
            games.showDashboard()
            #expect(java.count("games.showAchievements") == 0)
            // A player signed in from Play Games' own app still counts as signed in.
            games.start {}
            java.send("games", "signIn", ["signedIn": true])
            #expect(games.opensDashboard)
        }
        let local = LocalAchievements(defaults: UserDefaults(suiteName: "no-dashboard")!)
        #expect(!local.hasDashboard)
        #expect(!local.opensDashboard)
    }
}
