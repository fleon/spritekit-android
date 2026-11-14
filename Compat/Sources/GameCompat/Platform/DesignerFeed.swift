// A port of `Source/Utils/DesignerFeed.swift`, not a symlink: the game's,
// line for line, but for one gate. Only a beta build plays the feed (Play's
// testing tracks: `-Pswitchlings.beta`, `BetaBuild`), and a store build reads
// no launch arguments, so `-DesignerLevels NO` can't turn it off there:
// `start()` and `refresh()` also ask `isBeta`. A debug build reads
// `-DesignerLevels`, which the shell sets to NO with beta off unless the
// launch names it. `DesignerServer` stays for what outlives the beta (shared
// levels). Keep it in step with the original; it comes out with it before
// the store release.
import CryptoKit
import Foundation

/// Every build plays the Level Designer's levels (`Tools/Levels/Designer`)
/// during the beta (it comes out before the App Store release), which the
/// designer sends on every save to the level feed on fleon-home
/// (`DesignerServer`, `GET /feed`). At launch the
/// feed fetched last (cached) stands in for the bundle's levels and the feed
/// is fetched again, as it is whenever the app comes back to the front: a
/// changed feed swaps the catalog (`LevelCatalog.use`), and scenes built
/// afterwards show it. A feed is used only when every file it names is
/// there, whole, and decodes, and every level's stored solution plays
/// through; otherwise the levels in play stay (the last good feed, or the
/// bundle's). `-DesignerLevels NO` keeps the bundle's levels.
/// The Level Designer's server on fleon-home, which keeps the level feed
/// (`/feed`) and the solve log (`/solves`) and asks for no key.
/// `-DesignerServer <url>` points a debug build at another.
enum DesignerServer {
    private static let url = URL(string: "https://switchlings.fleon.com")

    static func endpoint(_ path: String) -> URL? {
        (LaunchArguments.designerServerURL ?? url)?.appendingPathComponent(path)
    }
}

final class DesignerFeed {
    static let shared = DesignerFeed()

    /// A feed as it is cached: its files and revision, and the tag that asks
    /// the server whether it has changed.
    nonisolated private struct Snapshot: Codable {
        let etag: String?
        let revision: String
        let files: [String: String]
    }

    /// What the server answers: the level files, under a revision named for them.
    private struct Feed: Decodable {
        let revision: String
        let files: [String: String]
    }

    nonisolated private static let cacheName = "DesignerFeed.json"
    /// How long a fetch may take; the launch splash waits for the first one,
    /// but never past `launchSplashMaximumDuration`.
    private static let timeout: TimeInterval = 5
    /// The least time between fetches as the app comes back to the front.
    private static let refreshInterval: TimeInterval = 15
    /// How much of the feed's revision solve records keep.
    private static let revisionLength = 10
    private static let ok = 200
    private static let notModified = 304

    private let session: URLSession
    /// The feed in play, if the levels come from one.
    private var snapshot: Snapshot?
    private var isFetching = false
    /// When the last fetch started (system uptime).
    private var lastFetch: TimeInterval?
    private var hasAnswered = false
    private var answerHandlers: [() -> Void] = []

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// At launch: plays the cached feed's levels, if they're still good,
    /// then fetches the feed. Checking the cache replays every solution, so
    /// it runs off the main thread (the launch splash waits for the fetch).
    func start() {
        guard Self.isBeta else {
            print("DesignerFeed: not a beta build, playing the bundled levels")
            answer()
            return
        }
        guard LaunchArguments.usesDesignerLevels else {
            print("DesignerFeed: -DesignerLevels NO, playing the bundled levels")
            answer()
            return
        }
        isFetching = true
        Task {
            if let (cached, checked) = await Task.detached(priority: .userInitiated, operation: { Self.checkedCache() }).value {
                use(cached, checked: checked)
            }
            isFetching = false
            refresh()
        }
    }

    /// Fetches the feed again (as the app comes back to the front), unless
    /// it was fetched in the last `refreshInterval`.
    func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        guard Self.isBeta, LaunchArguments.usesDesignerLevels, !isFetching,
              lastFetch.map({ now - $0 >= Self.refreshInterval }) ?? true else { return }
        isFetching = true
        lastFetch = now
        Task {
            await fetch()
            isFetching = false
            answer()
        }
    }

    /// Android: whether this build may play the feed. A debug build leaves
    /// it to `-DesignerLevels` (`BetaBuild.arguments`), a store build to
    /// the beta switch.
    private static var isBeta: Bool {
        #if DEBUG
        return true
        #else
        return BetaBuild.current.isOn
        #endif
    }

    /// Runs `handler` once the feed has first answered (changed, unchanged
    /// or failed), or at once if it has.
    func whenAnswered(_ handler: @escaping () -> Void) {
        if hasAnswered { handler() } else { answerHandlers.append(handler) }
    }

    private func answer() {
        guard !hasAnswered else { return }
        hasAnswered = true
        let handlers = answerHandlers
        answerHandlers.removeAll()
        handlers.forEach { $0() }
    }

    private var playing: String {
        snapshot.map { "the feed's levels (\($0.revision))" } ?? "the bundled levels"
    }

    private func fetch() async {
        guard let (data, response) = await request() else {
            print("DesignerFeed: couldn't reach the feed, playing \(playing)")
            return
        }
        switch response.statusCode {
        case Self.notModified:
            print("DesignerFeed: the feed is unchanged, playing \(playing)")
        case Self.ok:
            await accept(data, etag: response.value(forHTTPHeaderField: "ETag"))
        default:
            print("DesignerFeed: the feed answered \(response.statusCode), playing \(playing)")
        }
    }

    /// GETs the feed, asking only for a change when one is in play.
    private func request() async -> (Data, HTTPURLResponse)? {
        guard let url = DesignerServer.endpoint("feed") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = snapshot?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await session.data(for: request),
              let response = response as? HTTPURLResponse else { return nil }
        return (data, response)
    }

    /// Plays the feed's levels if they make a whole catalog and differ from
    /// those in play, and caches them.
    private func accept(_ data: Data, etag: String?) async {
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data) else {
            print("DesignerFeed: the feed didn't decode, playing \(playing)")
            return
        }
        let files = feed.files
        let revision = String(feed.revision.prefix(Self.revisionLength))
        let fetched = Snapshot(etag: etag, revision: revision, files: files)
        if let snapshot, snapshot.revision == revision, snapshot.files == files {
            self.snapshot = fetched
            Self.saveCache(fetched)
            print("DesignerFeed: the feed is unchanged, playing \(playing)")
            return
        }
        let checked = await Task.detached(priority: .userInitiated) {
            LevelCatalog.contents(from: files.mapValues { Data($0.utf8) }, revision: revision)
        }.value
        switch checked {
        case let .failure(problem):
            print("DesignerFeed: the feed (\(revision)) \(Self.describe(problem)), playing \(playing)")
        case let .success(contents):
            LevelCatalog.use(contents)
            snapshot = fetched
            Self.saveCache(fetched)
            print("DesignerFeed: playing the feed's levels (\(revision), \(contents.levels.count) levels)")
        }
    }

    /// Plays the cached feed's levels, if they're still whole and every
    /// solution still plays through (the engine may have changed since).
    private func use(_ cached: Snapshot, checked: Result<LevelCatalog.Contents, LevelCatalog.FeedProblem>) {
        switch checked {
        case let .failure(problem):
            print("DesignerFeed: the cached feed (\(cached.revision)) \(Self.describe(problem)), playing \(playing)")
        case let .success(contents):
            LevelCatalog.use(contents)
            snapshot = cached
            print("DesignerFeed: playing the cached feed's levels (\(cached.revision))")
        }
    }

    /// The cached feed, if there is one, and its levels if they can be played.
    nonisolated private static func checkedCache() -> (Snapshot, Result<LevelCatalog.Contents, LevelCatalog.FeedProblem>)? {
        guard let cached = loadCache() else { return nil }
        return (cached, LevelCatalog.contents(from: cached.files.mapValues { Data($0.utf8) }, revision: cached.revision))
    }

    private static func describe(_ problem: LevelCatalog.FeedProblem) -> String {
        switch problem {
        case .incomplete: return "is incomplete or broken"
        case let .unsolved(id): return "has a solution that doesn't play through (\(id))"
        }
    }

    nonisolated private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(cacheName)
    }

    nonisolated private static func loadCache() -> Snapshot? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    nonisolated private static func saveCache(_ snapshot: Snapshot) {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// A level's fingerprint names what's played, so solve times follow a
/// level when it moves and start over when its board changes: the first 12
/// hex digits of the SHA-256 of its JSON without `tip`, `solution` and
/// `tiles` (and `name`, which levels carried before names were dropped),
/// written canonically (`JSONText.canonical`). It matches the Level
/// Designer's (`Tools/Levels/Designer/README.md`).
nonisolated enum LevelFingerprint {
    private static let ignoredKeys: Set<String> = ["name", "tip", "solution", "tiles"]
    private static let length = 12

    /// The fingerprint of each level in a world file's JSON, in order.
    static func ofLevels(inWorldFile data: Data) -> [String]? {
        guard let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let levels = file["levels"] as? [Any] else { return nil }
        return levels.map { level in
            let played: Any = (level as? [String: Any])?.filter { !ignoredKeys.contains($0.key) } ?? level
            let digest = SHA256.hash(data: Data(JSONText.canonical(played).utf8))
            return String(digest.map { String(format: "%02x", $0) }.joined().prefix(length))
        }
    }
}

/// JSON written as JavaScript's `JSON.stringify` writes it, for level
/// fingerprints and solve records: no whitespace, whole numbers as plain
/// digits.
nonisolated enum JSONText {
    /// JSON already written, put in as it is.
    struct Raw {
        let text: String
    }

    /// The largest whole number a JavaScript number holds exactly (2^53).
    private static let largestExactInteger = 9_007_199_254_740_992.0

    /// `value` (as `JSONSerialization` reads it, or strings, numbers, bools,
    /// `NSNull` and `Raw`) with every object's keys sorted by UTF-16 code unit.
    static func canonical(_ value: Any) -> String {
        switch value {
        case let raw as Raw:
            return raw.text
        case let object as [String: Any]:
            let keys = object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return "{" + keys.map { quoted($0) + ":" + canonical(object[$0] ?? NSNull()) }.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map(canonical).joined(separator: ",") + "]"
        case let text as String:
            return quoted(text)
        case let number as NSNumber:
            // Booleans are numbers to Foundation: tell them apart by type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            if double.rounded() == double, abs(double) <= largestExactInteger { return String(Int64(double)) }
            return "\(double)"
        default:
            return "null"
        }
    }

    /// An object with `fields` in the order given.
    static func object(_ fields: [(key: String, value: Any)]) -> String {
        "{" + fields.map { quoted($0.key) + ":" + canonical($0.value) }.joined(separator: ",") + "}"
    }

    /// `text` in quotes, escaped as `JSON.stringify` escapes it.
    private static func quoted(_ text: String) -> String {
        var escaped = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{8}": escaped += "\\b"
            case "\u{C}": escaped += "\\f"
            case _ where scalar.value < 0x20: escaped += String(format: "\\u%04x", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }
}
