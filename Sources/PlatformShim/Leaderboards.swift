import Foundation

/// What a game's Game Center manager asks of leaderboards, in Game Center's
/// own terms: a score sent to one or more leaderboards by their Game Center
/// IDs, and the leaderboards shown over the game.
///
/// On Android the backend is Play Games (`PlayGamesLeaderboards`); with no
/// Play Games in the build it is `LocalLeaderboards`, which keeps nothing, as
/// a signed-out Game Center player's scores go nowhere.
public protocol LeaderboardsBackend: AnyObject {
    /// Sends `score` to each leaderboard in `ids` (Game Center IDs). True once
    /// they all arrived; false signed out, or for a leaderboard with no
    /// counterpart on this backend.
    func submit(_ score: Int, context: Int, to ids: [String]) async -> Bool
    /// Whether `showDashboard` can show anything here.
    var hasDashboard: Bool { get }
    /// The leaderboards over the game: one by its Game Center ID, or all of
    /// them for nil (Game Center's dashboard).
    func showDashboard(leaderboardID: String?)
}

/// No leaderboards at all.
public final class LocalLeaderboards: LeaderboardsBackend {
    public init() {}

    public func submit(_ score: Int, context: Int, to ids: [String]) async -> Bool { false }
    public var hasDashboard: Bool { false }
    public func showDashboard(leaderboardID: String?) {}
}

/// Play Games Services v2's leaderboards behind `LeaderboardsBackend`.
///
/// Game Center IDs become Play's through `PlayGamesMapping.leaderboards`
/// (generated beside the achievements by `Tools/Play/games.js`). Java submits
/// with `LeaderboardsClient.submitScoreImmediate`, which, like Game Center,
/// keeps a player's best and ignores a lower score. Sign-in is Play Games'
/// own (`PlayGamesAchievements` starts it): signed out, Java answers each
/// submission with `ok: false` and the dashboard signs the player in first.
///
/// Calls, under `games`: `submitScores {items: [{id, score, tag}], request}`,
/// `showLeaderboards {id?}`. Event: `scoresSubmitted {request, ok}`.
public final class PlayGamesLeaderboards: LeaderboardsBackend {
    private static let service = "games"

    private let channel: PlatformChannel
    private let mapping: PlayGamesMapping
    private var nextRequest = 1
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

    /// Whether Play Games can run on this device, as Java answers once.
    public let hasDashboard: Bool

    public init(channel: PlatformChannel, mapping: PlayGamesMapping) {
        self.channel = channel
        self.mapping = mapping
        hasDashboard = !mapping.leaderboards.isEmpty
            && (channel.call("games.available")?.bool("available") ?? false)
        channel.on(Self.service) { [weak self] event, body in self?.handle(event, body) }
    }

    /// On the main actor, as Play's answers are delivered there.
    @MainActor
    public func submit(_ score: Int, context: Int, to ids: [String]) async -> Bool {
        let playIDs = ids.compactMap { mapping.leaderboards[$0] }
        guard !playIDs.isEmpty else { return false }
        let items: [[String: Any]] = playIDs.map { ["id": $0, "score": score, "tag": Self.tag(context)] }
        let request = nextRequest
        nextRequest += 1
        let arrived = await withCheckedContinuation { continuation in
            waiters[request] = continuation
            channel.call("games.submitScores", ["items": items, "request": request])
        }
        return arrived && playIDs.count == ids.count
    }

    public func showDashboard(leaderboardID: String?) {
        guard hasDashboard else { return }
        if let leaderboardID {
            guard let playID = mapping.leaderboards[leaderboardID] else { return }
            channel.call("games.showLeaderboards", ["id": playID])
        } else {
            channel.call("games.showLeaderboards")
        }
    }

    /// Game Center's context is a 64-bit number kept with the score; Play
    /// keeps a tag of up to 64 URL-safe characters, so the context travels
    /// as its decimal digits, and 0, Game Center's "none", as no tag.
    static func tag(_ context: Int) -> String {
        context == 0 ? "" : String(context)
    }

    private func handle(_ event: String, _ body: PlatformChannel.Message) {
        guard event == "scoresSubmitted",
              let request = body.int("request"),
              let waiter = waiters.removeValue(forKey: request)
        else { return }
        waiter.resume(returning: body.bool("ok") ?? false)
    }
}
