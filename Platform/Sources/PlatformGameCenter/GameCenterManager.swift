import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import UIKit
#endif

/// A game's Game Center: signs the player in at launch, reports
/// achievements, sends scores and opens the dashboard and leaderboards. It
/// never holds up play: signed out or offline nothing is sent, and the next
/// sign-in reports whatever the service missed, from the game's saved
/// progress.
///
/// The game says where each achievement stands (`Configuration.progress`),
/// worked out from its own saved data and the moments it records here
/// (firsts that saved progress can't tell, such as a board's first bump).
/// The manager loads what the service holds at each sign-in and sends only
/// what has moved past it.
///
/// Behind it are two backends: GameKit on Apple (`GameKitAchievements`,
/// `GameKitLeaderboards`), Play Games on Android (`usePlayGames`), or
/// `LocalAchievements` and `LocalLeaderboards` where there is neither.
public final class GameCenterManager {
    /// When a report shows the service's completion banner.
    public enum BannerPolicy: Sendable {
        /// For what the player earns on this device; not for what a
        /// sign-in catches up or another device earned.
        case whenEarnedHere
        case always
        case never
    }

    public struct Configuration {
        /// Each achievement's percentage (0 to 100) by its ID, from the
        /// game's saved progress and the moments recorded so far.
        public var progress: (_ moments: Set<String>) -> [String: Double]
        public var banners: BannerPolicy
        /// The unified log's subsystem (Apple): the game's bundle ID.
        public var logSubsystem: String
        /// Where moments are kept in user defaults, as a string array.
        public var momentsKey: String
        /// Saves moments recorded here, for a game whose synced saved data
        /// keeps them under `momentsKey` (a set every device adds to).
        /// Without it the manager keeps them in user defaults itself.
        public var saveMoments: ((_ added: Set<String>) -> Void)?
        /// Clears the moments for a debug reset, for a game that saves them
        /// itself.
        public var resetMoments: (() -> Void)?
        /// Debug: each sign-in resets what the service holds, and the
        /// moments with it, instead of catching up.
        public var resetsOnSignIn: Bool
        public var defaults: UserDefaults

        public init(
            progress: @escaping (_ moments: Set<String>) -> [String: Double],
            banners: BannerPolicy = .whenEarnedHere,
            logSubsystem: String,
            momentsKey: String = "gameCenter.moments",
            saveMoments: ((_ added: Set<String>) -> Void)? = nil,
            resetMoments: (() -> Void)? = nil,
            resetsOnSignIn: Bool = false,
            defaults: UserDefaults = .standard
        ) {
            self.progress = progress
            self.banners = banners
            self.logSubsystem = logSubsystem
            self.momentsKey = momentsKey
            self.saveMoments = saveMoments
            self.resetMoments = resetMoments
            self.resetsOnSignIn = resetsOnSignIn
            self.defaults = defaults
        }
    }

    /// Where a player stands on a leaderboard.
    public struct LeaderboardStanding: Equatable, Sendable {
        public var rank: Int
        public var playerCount: Int
        public var score: LeaderboardScore

        public init(rank: Int, playerCount: Int, score: LeaderboardScore) {
            self.rank = rank
            self.playerCount = playerCount
            self.score = score
        }
    }

    public let configuration: Configuration
    /// Where achievements and sign-in go. Set before `start`.
    public var achievementService: AchievementsBackend
    /// Where scores go.
    public var leaderboardService: LeaderboardsBackend

    /// Called whenever the player signs in or out, after the first answer.
    public var signInChanged: ((Bool) -> Void)?
    /// Called whenever the signed-in player changes.
    public var playerChanged: ((GamePlayer?) -> Void)?

    /// The moments recorded so far, on this device and others.
    public private(set) var moments: Set<String>

    private let log: ServiceLog
    /// What the service holds for each achievement, as last loaded or sent.
    private var reported: [String: Double] = [:]
    private var hasStarted = false
    private var hasAnswered = false
    private var answerHandlers: [() -> Void] = []
    private var wasSignedIn = false

    public init(
        configuration: Configuration,
        achievements: AchievementsBackend? = nil,
        leaderboards: LeaderboardsBackend? = nil
    ) {
        self.configuration = configuration
        achievementService = achievements ?? Self.platformAchievements()
        leaderboardService = leaderboards ?? Self.platformLeaderboards()
        log = ServiceLog(subsystem: configuration.logSubsystem, category: "GameCenter")
        moments = Self.savedMoments(configuration)
    }

    // MARK: - Sign-in

    /// Signs the player in. Where the service has a sign-in sheet (GameKit),
    /// it goes to `presentSignIn`, once a launch, or over the top view
    /// controller without one. `answered` runs once the service first
    /// answers: signed in, offering its sheet, or failed (a launch screen
    /// may wait on it); at once if it already has.
    public func start(presentSignIn: ((UIViewController) -> Void)? = nil, answered: (() -> Void)? = nil) {
        if let answered {
            if hasAnswered { answered() } else { answerHandlers.append(answered) }
        }
        guard !hasStarted else { return }
        hasStarted = true
        #if !SPRITEKIT_SHIM
        if let presentSignIn, let gameKit = achievementService as? GameKitAchievements {
            gameKit.presentSignIn = presentSignIn
        }
        #endif
        achievementService.playerChanged = { [weak self] player in
            Task { @MainActor in self?.playerChanged?(player) }
        }
        achievementService.start { [weak self] in
            Task { @MainActor in self?.serviceAnswered() }
        }
    }

    public var isSignedIn: Bool { achievementService.isSignedIn }

    /// The signed-in player, by the service's ID; nil signed out.
    public var player: GamePlayer? { achievementService.player }

    /// The signed-in player's name and photo, to credit them; nil signed
    /// out.
    public func localPlayer() async -> (name: String, photo: UIImage?)? {
        guard let player = await achievementService.localPlayer() else { return nil }
        return (player.name, player.photo.flatMap { UIImage(data: $0) })
    }

    // MARK: - Achievements

    /// Reports what the game's saved progress has moved, with banners.
    public func reportProgress() {
        report(earnedHere: true)
    }

    /// Records moments the player just had and reports what they earn.
    /// Returns those that are new.
    @discardableResult
    public func record(_ moments: Set<String>) -> Set<String> {
        let added = moments.subtracting(self.moments)
        guard !added.isEmpty else { return [] }
        self.moments.formUnion(added)
        if let save = configuration.saveMoments {
            save(added)
        } else {
            configuration.defaults.set(self.moments.sorted(), forKey: configuration.momentsKey)
        }
        report(earnedHere: true)
        return added
    }

    /// Another device's progress or moments arrived: reports what they
    /// earned, quietly under `.whenEarnedHere` (that device showed the
    /// banners).
    public func savedDataDidSync() {
        moments = Self.savedMoments(configuration)
        report(earnedHere: false)
    }

    /// A whole percentage for `done` of `total`, as the services count it:
    /// rounded down, so it never claims an achievement early.
    public nonisolated static func percent(_ done: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return (min(Double(max(done, 0)) / Double(total), 1) * 100).rounded(.down)
    }

    /// All or nothing.
    public nonisolated static func percent(when done: Bool) -> Double {
        done ? 100 : 0
    }

    // MARK: - Dashboard

    /// Whether the dashboard opens from the game: signed in, or a service
    /// whose dashboard signs the player in first (Play Games). Otherwise a
    /// game tells the player to sign in from the system's settings.
    public var opensDashboard: Bool { achievementService.opensDashboard }

    /// Whether the service's dashboard can be shown on this device at all
    /// (Play Games; Game Center's is always there).
    public var hasDashboard: Bool { achievementService.hasDashboard }

    /// Opens the service's dashboard over the game, in `window` where the
    /// service takes one (GameKit's access point).
    public func showDashboard(over window: UIWindow? = nil) {
        #if !SPRITEKIT_SHIM
        if let gameKit = achievementService as? GameKitAchievements {
            gameKit.show(.dashboard, over: window)
            return
        }
        #endif
        achievementService.showDashboard()
    }

    /// Opens the achievements: Game Center's page of them, or the service's
    /// dashboard where that is its achievements (Play Games).
    public func showAchievements(over window: UIWindow? = nil) {
        #if !SPRITEKIT_SHIM
        if let gameKit = achievementService as? GameKitAchievements {
            gameKit.show(.achievements, over: window)
            return
        }
        #endif
        achievementService.showDashboard()
    }

    // MARK: - Leaderboards

    /// Whether leaderboards can be shown here.
    public var hasLeaderboards: Bool { leaderboardService.hasDashboard }

    /// Sends `score` to the leaderboards in `ids`. Returns whether it
    /// arrived; signed out, it doesn't.
    @discardableResult
    public func submitScore(_ score: Int, context: Int = 0, to ids: [String]) async -> Bool {
        do {
            try await leaderboardService.submitScore(score, context: context, to: ids)
            log.debug("Submitted \(score) to \(ids.joined(separator: ", "))")
            return true
        } catch {
            log.info("Submitting \(score) to \(ids.joined(separator: ", ")) failed: \(error)")
            return false
        }
    }

    /// Sends `score` without waiting for it.
    public func submit(_ score: Int, context: Int = 0, to ids: [String]) {
        Task { await submitScore(score, context: context, to: ids) }
    }

    /// Where the signed-in player stands on `id`; nil signed out, without
    /// a score there, or when the service doesn't answer.
    public func standing(
        on id: String, timeSpan: LeaderboardTimeSpan = .allTime, collection: LeaderboardCollection = .public
    ) async -> LeaderboardStanding? {
        do {
            let scores = try await leaderboardService.loadScores(id, timeSpan: timeSpan, collection: collection, range: 1...1)
            guard let local = scores.local else { return nil }
            return LeaderboardStanding(rank: local.rank, playerCount: scores.total, score: local)
        } catch {
            log.info("Loading the standing on \(id) failed: \(error)")
            return nil
        }
    }

    /// Opens one leaderboard over the game, or all of them for nil.
    public func showLeaderboards(
        _ id: String? = nil,
        timeSpan: LeaderboardTimeSpan = .allTime,
        collection: LeaderboardCollection = .public,
        over window: UIWindow? = nil
    ) {
        #if !SPRITEKIT_SHIM
        (leaderboardService as? GameKitLeaderboards)?.dashboardWindow = window
        #endif
        leaderboardService.showLeaderboards(id, timeSpan: timeSpan, collection: collection)
    }

    // MARK: - Reporting

    private static func savedMoments(_ configuration: Configuration) -> Set<String> {
        Set(configuration.defaults.stringArray(forKey: configuration.momentsKey) ?? [])
    }

    private func serviceAnswered() {
        if !hasAnswered {
            hasAnswered = true
            let handlers = answerHandlers
            answerHandlers.removeAll()
            handlers.forEach { $0() }
        }
        let signedIn = isSignedIn
        if signedIn != wasSignedIn {
            wasSignedIn = signedIn
            signInChanged?(signedIn)
        }
        Task { await catchUp() }
    }

    /// Loads what the service holds, then quietly sends what it is missing.
    private func catchUp() async {
        reported = [:]
        if configuration.resetsOnSignIn, await achievementService.reset() {
            // Start over completely, moments included.
            moments = []
            if let reset = configuration.resetMoments {
                reset()
            } else {
                configuration.defaults.removeObject(forKey: configuration.momentsKey)
            }
            log.debug("Reset achievements")
        } else {
            reported = await achievementService.load()
        }
        report(earnedHere: false)
    }

    /// Sends every achievement that has moved past what the service holds.
    private func report(earnedHere: Bool) {
        var progressed: [String: Double] = [:]
        for (id, percent) in configuration.progress(moments) {
            let percent = min(percent, 100)
            if percent > reported[id, default: 0] { progressed[id] = percent }
        }
        guard !progressed.isEmpty else { return }
        for (id, percent) in progressed {
            reported[id] = percent
        }
        let banners = switch configuration.banners {
        case .whenEarnedHere: earnedHere
        case .always: true
        case .never: false
        }
        let summary = progressed.sorted { $0.key < $1.key }.map { "\($0.key) \(Int($0.value))%" }.joined(separator: ", ")
        Task {
            if await achievementService.report(progressed, showingBanners: banners) {
                log.debug("Reported \(summary)")
            } else {
                log.info("Not reported: \(summary)")
                // Forget what didn't arrive, so the next report sends it
                // again, unless something newer was sent meanwhile.
                for (id, percent) in progressed where reported[id] == percent {
                    reported[id] = nil
                }
            }
        }
    }

    private static func platformAchievements() -> AchievementsBackend {
        #if SPRITEKIT_SHIM
        LocalAchievements()
        #else
        GameKitAchievements()
        #endif
    }

    private static func platformLeaderboards() -> LeaderboardsBackend {
        #if SPRITEKIT_SHIM
        LocalLeaderboards()
        #else
        GameKitLeaderboards()
        #endif
    }
}
