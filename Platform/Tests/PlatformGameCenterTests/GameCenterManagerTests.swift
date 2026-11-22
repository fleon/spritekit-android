import Foundation
import Testing
@testable import PlatformGameCenter
import PlatformTestSupport

// The manager over fake services: sign-in, catching up, reporting only what
// moved, moments, banners, resets, and leaderboards.

/// Lets the manager's tasks run.
private func settle() async {
    for _ in 0..<50 {
        await Task.yield()
    }
}

private final class FakeAchievements: AchievementsBackend {
    var isSignedIn = true
    var held: [String: Double] = [:]
    var reports: [(progress: [String: Double], banners: Bool)] = []
    var accepts = true
    var resets = 0
    var dashboards = 0
    var answered: (() -> Void)?
    var player: GamePlayer?
    var playerChanged: ((GamePlayer?) -> Void)?
    var hasDashboard = false

    func start(answered: @escaping () -> Void) {
        self.answered = answered
    }

    func load() async -> [String: Double] { held }

    func report(_ progress: [String: Double], showingBanners: Bool) async -> Bool {
        reports.append((progress, showingBanners))
        guard accepts else { return false }
        held.merge(progress, uniquingKeysWith: max)
        return true
    }

    func reset() async -> Bool {
        resets += 1
        held = [:]
        return true
    }

    func showDashboard() {
        dashboards += 1
    }

    func localPlayer() async -> (name: String, photo: Data?)? {
        isSignedIn ? ("Ann", nil) : nil
    }
}

private final class FakeLeaderboards: LeaderboardsBackend {
    var submitted: [(score: Int, context: Int, ids: [String])] = []
    var scores = LeaderboardScores(local: nil, entries: [], total: 0)
    var shown: [String?] = []

    func submitScore(_ score: Int, context: Int, to ids: [String]) async throws(LeaderboardError) {
        submitted.append((score, context, ids))
    }

    func loadLeaderboards(_ ids: [String]?) async throws(LeaderboardError) -> [LeaderboardInfo] { [] }

    func loadScores(
        _ id: String, timeSpan: LeaderboardTimeSpan, collection: LeaderboardCollection, range: ClosedRange<Int>?
    ) async throws(LeaderboardError) -> LeaderboardScores {
        scores
    }

    var hasDashboard: Bool { true }

    func showLeaderboards(_ id: String?, timeSpan: LeaderboardTimeSpan, collection: LeaderboardCollection) {
        shown.append(id)
    }
}

/// Levels cleared, and two moments, as a game might count them.
nonisolated private final class Progress {
    var cleared = 0

    func achievements(_ moments: Set<String>) -> [String: Double] {
        [
            "levels.10": GameCenterManager.percent(cleared, of: 10),
            "first.bump": GameCenterManager.percent(when: moments.contains("bump")),
            "first.wake": GameCenterManager.percent(when: moments.contains("wake")),
        ]
    }
}

@Suite("Game Center manager")
@MainActor
struct GameCenterManagerTests {
    private func manager(
        _ service: FakeAchievements,
        progress: Progress = Progress(),
        defaults: UserDefaults = scratchDefaults(),
        configure: (inout GameCenterManager.Configuration) -> Void = { _ in }
    ) -> GameCenterManager {
        var configuration = GameCenterManager.Configuration(
            progress: progress.achievements, logSubsystem: "test", defaults: defaults
        )
        configure(&configuration)
        return GameCenterManager(configuration: configuration, achievements: service, leaderboards: FakeLeaderboards())
    }

    @Test("A launch waits for the first answer; a later caller gets it at once")
    func answered() async {
        let service = FakeAchievements()
        let center = manager(service)
        var answers = 0
        center.start(answered: { answers += 1 })
        #expect(answers == 0)
        service.answered?()
        await settle()
        #expect(answers == 1)
        center.start(answered: { answers += 1 })
        #expect(answers == 2)
    }

    @Test("A sign-in sends only what the service is missing, quietly")
    func catchUp() async {
        let service = FakeAchievements()
        service.held = ["levels.10": 30]
        let progress = Progress()
        progress.cleared = 5
        let center = manager(service, progress: progress)
        center.start()
        service.answered?()
        await settle()
        #expect(service.reports.count == 1)
        #expect(service.reports.first?.progress == ["levels.10": 50])
        #expect(service.reports.first?.banners == false)

        // Nothing moved: nothing sent.
        center.reportProgress()
        await settle()
        #expect(service.reports.count == 1)

        progress.cleared = 6
        center.reportProgress()
        await settle()
        #expect(service.reports.last?.progress == ["levels.10": 60])
        #expect(service.reports.last?.banners == true)
    }

    @Test("Moments are kept, reported once and with banners")
    func moments() async {
        let defaults = scratchDefaults()
        let service = FakeAchievements()
        let center = manager(service, defaults: defaults)
        center.start()
        service.answered?()
        await settle()
        #expect(center.record(["bump"]) == ["bump"])
        await settle()
        #expect(service.reports.last?.progress == ["first.bump": 100])
        #expect(service.reports.last?.banners == true)
        #expect(center.record(["bump"]).isEmpty)
        #expect(Set(defaults.stringArray(forKey: "gameCenter.moments") ?? []) == ["bump"])

        // A relaunch reads them back.
        #expect(manager(FakeAchievements(), defaults: defaults).moments == ["bump"])
    }

    @Test("A game that syncs its moments saves them itself")
    func savedByTheGame() async {
        let defaults = scratchDefaults()
        var saved: [Set<String>] = []
        let center = manager(FakeAchievements(), defaults: defaults) { $0.saveMoments = { saved.append($0) } }
        center.record(["bump", "wake"])
        center.record(["wake"])
        #expect(saved == [["bump", "wake"]])
        #expect(defaults.stringArray(forKey: "gameCenter.moments") == nil)
    }

    @Test("What didn't arrive is sent again")
    func retries() async {
        let service = FakeAchievements()
        service.accepts = false
        let center = manager(service)
        center.start()
        service.answered?()
        await settle()
        center.record(["bump"])
        await settle()
        service.accepts = true
        center.reportProgress()
        await settle()
        #expect(service.reports.last?.progress == ["first.bump": 100])
        #expect(service.held == ["first.bump": 100])
    }

    @Test("Another device's moments are reported quietly")
    func synced() async {
        let defaults = scratchDefaults()
        let service = FakeAchievements()
        let center = manager(service, defaults: defaults)
        center.start()
        service.answered?()
        await settle()
        defaults.set(["wake"], forKey: "gameCenter.moments")
        center.savedDataDidSync()
        await settle()
        #expect(center.moments == ["wake"])
        #expect(service.reports.last?.progress == ["first.wake": 100])
        #expect(service.reports.last?.banners == false)
    }

    @Test("Banners follow the policy")
    func bannerPolicy() async {
        let service = FakeAchievements()
        let progress = Progress()
        progress.cleared = 1
        let center = manager(service, progress: progress) { $0.banners = .always }
        center.start()
        service.answered?()
        await settle()
        #expect(service.reports.last?.banners == true)

        let quiet = FakeAchievements()
        let never = manager(quiet) { $0.banners = .never }
        never.record(["bump"])
        await settle()
        #expect(quiet.reports.last?.banners == false)
    }

    @Test("A debug reset clears the service and the moments")
    func reset() async {
        let defaults = scratchDefaults()
        defaults.set(["bump"], forKey: "gameCenter.moments")
        let service = FakeAchievements()
        service.held = ["first.bump": 100]
        var resetByGame = false
        let center = manager(service, defaults: defaults) {
            $0.resetsOnSignIn = true
            $0.resetMoments = { resetByGame = true }
        }
        center.start()
        service.answered?()
        await settle()
        #expect(service.resets == 1)
        #expect(center.moments.isEmpty)
        #expect(resetByGame)
        #expect(service.reports.isEmpty)
    }

    @Test("Sign-in and the player are passed on")
    func signInAndPlayer() async {
        let service = FakeAchievements()
        service.isSignedIn = false
        let center = manager(service)
        var signIns: [Bool] = []
        var players: [GamePlayer?] = []
        center.signInChanged = { signIns.append($0) }
        center.playerChanged = { players.append($0) }
        center.start()
        service.answered?()
        await settle()
        #expect(signIns.isEmpty)
        #expect(await center.localPlayer() == nil)

        service.isSignedIn = true
        service.player = GamePlayer(id: "p1", name: "Ann")
        service.playerChanged?(service.player)
        service.answered?()
        await settle()
        #expect(signIns == [true])
        #expect(players == [GamePlayer(id: "p1", name: "Ann")])
        #expect(center.player?.id == "p1")
        #expect(await center.localPlayer()?.name == "Ann")
    }

    @Test("The dashboard opens through the service")
    func dashboard() {
        let service = FakeAchievements()
        let center = manager(service)
        service.isSignedIn = false
        #expect(!center.opensDashboard)
        service.hasDashboard = true
        #expect(center.opensDashboard)
        center.showDashboard()
        center.showAchievements()
        #expect(service.dashboards == 2)
    }

    @Test("Whole percentages, rounded down")
    func percentages() {
        #expect(GameCenterManager.percent(1, of: 3) == 33)
        #expect(GameCenterManager.percent(2, of: 3) == 66)
        #expect(GameCenterManager.percent(5, of: 3) == 100)
        #expect(GameCenterManager.percent(-1, of: 3) == 0)
        #expect(GameCenterManager.percent(1, of: 0) == 0)
        #expect(GameCenterManager.percent(when: true) == 100)
    }

    @Test("On the device alone, a relaunch sends nothing already kept")
    func localService() async {
        let defaults = scratchDefaults()
        let progress = Progress()
        progress.cleared = 10
        let first = LocalAchievements(defaults: defaults)
        let center = manager(FakeAchievements(), progress: progress, defaults: defaults)
        center.achievementService = first
        var answered = false
        center.start(answered: { answered = true })
        await settle()
        #expect(answered)
        #expect(await first.load() == ["levels.10": 100])

        // A fake over the same kept progress sees nothing new to send.
        let again = FakeAchievements()
        again.held = await LocalAchievements(defaults: defaults).load()
        let relaunched = manager(again, progress: progress, defaults: defaults)
        relaunched.start()
        again.answered?()
        await settle()
        #expect(again.reports.isEmpty)
    }
}

@Suite("Game Center leaderboards")
@MainActor
struct GameCenterLeaderboardTests {
    private func manager(_ boards: LeaderboardsBackend) -> GameCenterManager {
        GameCenterManager(
            configuration: .init(progress: { _ in [:] }, logSubsystem: "test", defaults: scratchDefaults()),
            achievements: FakeAchievements(),
            leaderboards: boards
        )
    }

    @Test("A score goes to every leaderboard named, with its context")
    func submit() async {
        let boards = FakeLeaderboards()
        let center = manager(boards)
        #expect(await center.submitScore(120, context: 7, to: ["high", "daily"]))
        #expect(boards.submitted.first?.score == 120)
        #expect(boards.submitted.first?.context == 7)
        #expect(boards.submitted.first?.ids == ["high", "daily"])
    }

    @Test("The player's standing is their rank among everyone")
    func standing() async {
        let boards = FakeLeaderboards()
        let center = manager(boards)
        #expect(await center.standing(on: "high") == nil)
        let mine = LeaderboardScore(
            rank: 4, score: 900, formattedScore: "900", context: 0, date: Date(timeIntervalSince1970: 0),
            playerID: "p1", playerName: "Ann"
        )
        boards.scores = LeaderboardScores(local: mine, entries: [], total: 52)
        #expect(await center.standing(on: "high") == .init(rank: 4, playerCount: 52, score: mine))
        center.showLeaderboards("high")
        #expect(boards.shown == ["high"])
    }

    @Test("Without leaderboards nothing arrives and nothing stands")
    func none() async {
        let center = manager(LocalLeaderboards())
        #expect(!center.hasLeaderboards)
        #expect(await center.submitScore(1, to: ["high"]) == false)
        #expect(await center.standing(on: "high") == nil)
    }
}
