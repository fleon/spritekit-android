import Foundation

/// Play Games Services v2's leaderboards behind `LeaderboardsBackend`.
///
/// Game Center IDs become Play's through `PlayGamesMapping.leaderboards`,
/// in the same file as the achievements'. Java submits
/// with `LeaderboardsClient.submitScoreImmediate`, which, like Game Center,
/// keeps a player's best and ignores a lower score. Sign-in is Play Games'
/// own (`PlayGamesAchievements` starts it); its `signIn` events tell this
/// class who is signed in.
///
/// Every request answers within `timeout`: a signed-out player or a device
/// without Play Games fails at once, a sign-out fails what is waiting, and
/// an answer that never comes (an activity restart, a lost event) fails
/// once the timeout passes.
///
/// Calls, under `games`:
///
///   - `submitScores {items: [{id, score, tag}], request}`, answered by
///     `scoresSubmitted {request, ok, reason?}`.
///   - `loadLeaderboards {ids?, request}`, answered by
///     `leaderboards {request, ok, reason?, items: [{id, title}]}`.
///   - `loadScores {id, timeSpan, collection, count, request}`, answered by
///     `scores {request, ok, reason?, items: [score], local?: score, total}`,
///     each score `{rank, score, formattedScore, tag, time, playerId, name}`:
///     the top `count` scores (none for 0) and the signed-in player's.
///   - `showLeaderboards {id?, timeSpan?, collection?}`.
///
/// `reason: "signedOut"` with `ok: false` says the player wasn't signed in.
public final class PlayGamesLeaderboards: LeaderboardsBackend {
    private static let service = "games"
    /// How long a request waits for Java before it fails.
    public static let timeout: TimeInterval = 30

    private typealias Answer = Result<PlatformChannel.Message, LeaderboardError>

    private let channel: PlatformChannel
    private let mapping: PlayGamesMapping
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private var nextRequest = 1
    private var waiters: [Int: CheckedContinuation<Answer, Never>] = [:]
    /// Nil until the first `signIn` event: Java is asked, and answers.
    private var isSignedIn: Bool?

    /// Whether Play Games can run on this device, as Java answers once.
    public let isAvailable: Bool
    public var hasDashboard: Bool { isAvailable && !mapping.leaderboards.isEmpty }

    /// `after` runs a closure later on the game's thread; the default is the
    /// main queue, which the shell drains once a frame.
    public init(
        channel: PlatformChannel,
        mapping: PlayGamesMapping,
        after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.channel = channel
        self.mapping = mapping
        self.after = after
        isAvailable = channel.call("games.available")?.bool("available") ?? false
        channel.on(Self.service) { [weak self] event, body in self?.handle(event, body) }
    }

    /// On the main actor, as Play's answers are delivered there.
    @MainActor
    public func submitScore(_ score: Int, context: Int, to ids: [String]) async throws(LeaderboardError) {
        let playIDs = ids.compactMap { mapping.leaderboards[$0] }
        guard !playIDs.isEmpty else { throw .unknownLeaderboard }
        let items: [[String: Any]] = playIDs.map { ["id": $0, "score": score, "tag": Self.tag(context)] }
        _ = try await request("games.submitScores", ["items": items]).get()
        guard playIDs.count == ids.count else { throw .unknownLeaderboard }
    }

    @MainActor
    public func loadLeaderboards(_ ids: [String]?) async throws(LeaderboardError) -> [LeaderboardInfo] {
        var arguments: PlatformChannel.Message = [:]
        if let ids {
            let playIDs = ids.compactMap { mapping.leaderboards[$0] }
            guard !playIDs.isEmpty else { return [] }
            arguments["ids"] = playIDs
        }
        let body = try await request("games.loadLeaderboards", arguments).get()
        let byPlayID = Dictionary(mapping.leaderboards.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let titles = Dictionary(
            (body["items"] as? [PlatformChannel.Message] ?? []).compactMap { item -> (String, String?)? in
                guard let playID = item["id"] as? String, let id = byPlayID[playID] else { return nil }
                return (id, item["title"] as? String)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Every known leaderboard answers, titled where Play gave a title.
        let known = ids?.filter { mapping.leaderboards[$0] != nil } ?? mapping.leaderboards.keys.sorted()
        return known.map { LeaderboardInfo(id: $0, title: titles[$0] ?? nil) }
    }

    @MainActor
    public func loadScores(
        _ id: String, timeSpan: LeaderboardTimeSpan, collection: LeaderboardCollection, range: ClosedRange<Int>?
    ) async throws(LeaderboardError) -> LeaderboardScores {
        guard let playID = mapping.leaderboards[id] else { throw .unknownLeaderboard }
        let body = try await request("games.loadScores", [
            "id": playID, "timeSpan": timeSpan.rawValue, "collection": collection.rawValue,
            "count": range?.upperBound ?? 0,
        ]).get()
        let loaded = (body["items"] as? [PlatformChannel.Message] ?? []).compactMap(Self.score)
        var entries: [LeaderboardScore] = []
        if let range, range.lowerBound >= 1, range.lowerBound <= loaded.count {
            entries = Array(loaded[(range.lowerBound - 1)..<min(range.upperBound, loaded.count)])
        }
        // Play counts -1 when it doesn't know.
        let total = body.int("total") ?? -1
        return LeaderboardScores(
            local: (body["local"] as? PlatformChannel.Message).flatMap(Self.score),
            entries: entries,
            total: total >= 0 ? total : loaded.count
        )
    }

    public func showLeaderboards(_ id: String?, timeSpan: LeaderboardTimeSpan, collection: LeaderboardCollection) {
        guard hasDashboard else { return }
        if let id {
            guard let playID = mapping.leaderboards[id] else { return }
            channel.call("games.showLeaderboards", [
                "id": playID, "timeSpan": timeSpan.rawValue, "collection": collection.rawValue,
            ])
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

    static func context(_ tag: String?) -> Int {
        tag.flatMap { Int($0) } ?? 0
    }

    private static func score(_ item: PlatformChannel.Message) -> LeaderboardScore? {
        guard let rank = item.int("rank"), let score = item.int("score") else { return nil }
        return LeaderboardScore(
            rank: rank,
            score: score,
            formattedScore: item["formattedScore"] as? String ?? String(score),
            context: context(item["tag"] as? String),
            date: Date(timeIntervalSince1970: (item.double("time") ?? 0) / 1000),
            playerID: item["playerId"] as? String ?? "",
            playerName: item["name"] as? String ?? ""
        )
    }

    /// Sends `name` with a request number and waits for its answer, or
    /// fails at once when no answer could come.
    @MainActor
    private func request(_ name: String, _ arguments: PlatformChannel.Message) async -> Answer {
        guard isAvailable else { return .failure(.unavailable) }
        guard isSignedIn != false else { return .failure(.signedOut) }
        let request = nextRequest
        nextRequest += 1
        var arguments = arguments
        arguments["request"] = request
        return await withCheckedContinuation { continuation in
            waiters[request] = continuation
            channel.call(name, arguments)
            after(Self.timeout) { [weak self] in self?.finish(request, .failure(.failed)) }
        }
    }

    private func finish(_ request: Int, _ answer: Answer) {
        waiters.removeValue(forKey: request)?.resume(returning: answer)
    }

    private func handle(_ event: String, _ body: PlatformChannel.Message) {
        switch event {
        case "signIn":
            let signedIn = body.bool("signedIn") ?? false
            isSignedIn = signedIn
            guard !signedIn else { return }
            for request in waiters.keys.sorted() {
                finish(request, .failure(.signedOut))
            }
        case "scoresSubmitted", "leaderboards", "scores":
            guard let request = body.int("request") else { return }
            if body.bool("ok") == true {
                finish(request, .success(body))
            } else {
                let signedOut = body["reason"] as? String == "signedOut" || isSignedIn == false
                finish(request, .failure(signedOut ? .signedOut : .failed))
            }
        default:
            break
        }
    }
}
