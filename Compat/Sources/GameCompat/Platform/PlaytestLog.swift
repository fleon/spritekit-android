// A port of `Source/Utils/PlaytestLog.swift`, not a symlink: on Android
// Swift has no Objective-C runtime, so the original's `@objc` observers
// (`#selector(resignActive)`) can't compile. Everything else is the game's,
// line for line; what differs, and only that:
// - `PlaytestRun` watches the app's state with block observers, removed as
//   it goes;
// - only a beta build records or posts (Play's testing tracks:
//   `-Pswitchlings.beta`, `BetaBuild`): a store build reads no launch
//   arguments, so `-Playtest NO` can't turn it off there, and `run(...)` and
//   `flush()` also ask `isBeta`;
// - the device is Android's, as `MainActivity` describes it
//   (`AndroidDevice`): `platform` "Android", `device` its maker and model,
//   `os` its Android version, `simulator` an emulator, `screen` the one
//   screen's size; `systemValue` (`sysctl`) goes with them;
// - Foundation comes in through UIKit's stand-in, not on its own: imported
//   directly, its `object(forInfoDictionaryKey:)` is ambiguous with the
//   shim's (`BundleInfo`), which answers with the APK's version and build.
// GameKit and Network are Compat's stand-ins (an install's anonymous id;
// ConnectivityManager). Keep it in step with the original; it comes out with
// it before the store release.
import GameKit
import Network
import PlatformShim
import UIKit

/// The solve log for the Level Designer (`Tools/Levels/Designer`), kept by
/// every build during the beta (it comes out before the App Store release):
/// every level cleared is recorded with how long it took over every visit
/// since it was last cleared, what the player did (`PlaytestRun`) and what
/// TestFlight's feedback would say of the device, queued in user defaults and
/// posted in batches to the designer's server on fleon-home (`DesignerServer`,
/// `POST /solves`), so the app carries no token. It posts after each solve,
/// at launch and when the app comes back to the front. Auto-solve runs and
/// `-Playtest NO` record nothing.
final class PlaytestLog {
    static let shared = PlaytestLog()

    private enum Key {
        static let queue = "debug.playtest.queue"
        /// Prefixes each unsolved level's key (`PlaytestRun`).
        static let unsolved = "debug.playtest.unsolved."
        static let player = "debug.playtest.player"
    }

    /// The most records one post carries.
    private static let batchSize = 100
    private static let created = 201
    /// Answers that mean the server will never take a batch: it's dropped.
    private static let refusals: Set<Int> = [400, 413]
    private static let recordVersion = 1
    private static let percent = 100.0

    private let defaults = UserDefaults.standard
    private var isFlushing = false
    /// How the device reaches the internet, watched once records are taken.
    private let paths = NWPathMonitor()
    private var isWatching = false

    private init() {}

    /// Starts timing a visit to a level as it shows, standing on the moves
    /// it `resumed`, or nil when nothing is recorded: while auto-solving or
    /// with `-Playtest NO`.
    func run(levelID: String, version: LevelCatalog.Version, resumed: [GameSession.Move]) -> PlaytestRun? {
        guard Self.isBeta, !LaunchArguments.autoSolve, LaunchArguments.recordsPlaytests else { return nil }
        watchDevice()
        return PlaytestRun(levelID: levelID, version: version, resumed: resumed)
    }

    /// Posts what's queued, a batch at a time, unless a post is on its way.
    /// A batch leaves the queue once the server has taken it, or refused it
    /// for good.
    func flush() {
        guard Self.isBeta, let url = DesignerServer.endpoint("solves"), !isFlushing else { return }
        let batch = Array(queue.prefix(Self.batchSize))
        guard !batch.isEmpty else { return }
        isFlushing = true
        Task {
            let isDone = await post(batch, to: url)
            isFlushing = false
            guard isDone else { return }
            var queue = self.queue
            if queue.starts(with: batch) { queue.removeFirst(batch.count) }
            self.queue = queue
            flush()
        }
    }

    /// Android: whether this build may record and post. A debug build leaves
    /// it to `-Playtest` (`BetaBuild.arguments`), a store build to the beta
    /// switch.
    private static var isBeta: Bool {
        #if DEBUG
        return true
        #else
        return BetaBuild.current.isOn
        #endif
    }

    /// One post: the records as a JSON array. True once the batch can leave
    /// the queue.
    private func post(_ records: [String], to url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(("[" + records.joined(separator: ",") + "]").utf8)
        let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode
        if status == Self.created {
            print("PlaytestLog: posted \(records.count) records")
            return true
        }
        if let status, Self.refusals.contains(status) {
            print("PlaytestLog: the solve log refused \(records.count) records (\(status)), dropping them")
            return true
        }
        print("PlaytestLog: the solve log answered \(status.map(String.init) ?? "nothing"), keeping \(queue.count) records")
        return false
    }

    private var queue: [String] {
        get { defaults.stringArray(forKey: Key.queue) ?? [] }
        set { defaults.set(newValue, forKey: Key.queue) }
    }

    /// Queues a level's solve, then posts it: `moves` is the winning run's
    /// length, the rest covers every visit since the level was last cleared.
    fileprivate func record(levelID: String, version: LevelCatalog.Version, play: PlaytestRun.Play, firstClear: Bool) {
        let player = GKLocalPlayer.local
        let isSignedIn = player.isAuthenticated
        var fields: [(key: String, value: Any)] = [
            ("v", Self.recordVersion),
            ("kind", "solve"),
            ("id", UUID().uuidString),
            ("level", levelID),
            ("fp", version.fingerprint),
            ("source", version.revision == nil ? "bundle" : "designer"),
            ("feed", Self.nullable(version.revision)),
            ("ms", play.milliseconds),
        ]
        fields += [
            ("moves", play.moves),
            ("taps", play.counts.taps),
            ("undos", play.counts.undos),
            ("restarts", play.counts.restarts),
            ("hints", play.counts.hints),
        ]
        fields.append(("firstClear", firstClear))
        fields.append(("log", JSONText.Raw(text: "[" + play.log.entries.joined(separator: ",") + "]")))
        if play.log.isTruncated { fields.append(("logTruncated", true)) }
        fields += [
            ("player", isSignedIn ? "pg:\(player.gamePlayerID)" : "anon:\(anonymousID)"),
            ("alias", Self.nullable(isSignedIn ? player.alias : nil)),
            ("platform", Self.platform),
            ("device", Self.device),
            ("simulator", Self.isSimulator),
            ("os", Self.osVersion),
            ("arch", Self.architecture),
            ("appVersion", Self.info("CFBundleShortVersionString")),
            ("build", Self.info("CFBundleVersion")),
            ("language", Localization.current.rawValue),
            ("locale", Locale.current.identifier),
            ("timeZone", TimeZone.current.identifier),
            ("battery", Self.battery),
            ("connection", connection),
            ("screen", Self.screen),
            ("at", ISO8601DateFormatter().string(from: Date())),
        ]
        queue.append(JSONText.object(fields))
        print("PlaytestLog: \(levelID) (\(version.fingerprint)) solved, \(play.milliseconds) ms, \(play.moves) moves, \(play.log.entries.count) log entries")
        flush()
    }

    /// The time, counts and log kept for a level left unsolved, by its key
    /// (`PlaytestRun`).
    fileprivate func unsolved(_ key: String) -> PlaytestRun.Tally? {
        guard let data = defaults.data(forKey: Key.unsolved + key) else { return nil }
        return try? JSONDecoder().decode(PlaytestRun.Tally.self, from: data)
    }

    /// Keeps a level's time, counts and log while it's left unsolved; nil
    /// forgets them.
    fileprivate func keep(_ tally: PlaytestRun.Tally?, for key: String) {
        defaults.set(tally.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.unsolved + key)
    }

    /// Who played when Game Center is signed out: an id kept for the install.
    private var anonymousID: String {
        if let id = defaults.string(forKey: Key.player) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Key.player)
        return id
    }

    /// Starts watching what the app only learns as it changes: the network
    /// path and the battery's charge.
    private func watchDevice() {
        guard !isWatching else { return }
        isWatching = true
        #if !os(tvOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        paths.start(queue: DispatchQueue(label: "PlaytestLog.paths"))
    }

    /// How the device reaches the internet, as TestFlight's feedback names it.
    private var connection: String {
        let path = paths.currentPath
        guard path.status == .satisfied else { return "none" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "other"
    }

    private static func nullable(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }

    private static let platform = "Android"

    /// The maker and model (`Google Pixel 6`), or the emulator's image.
    private static var device: String { AndroidDevice.current.model }

    private static var isSimulator: Bool { AndroidDevice.current.isEmulator }

    /// The Android version (`17`), which the designer shows after `platform`.
    private static var osVersion: String { AndroidDevice.current.osVersion }

    /// The architecture the app runs as.
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// The battery's charge in percent; null where there's no battery to read.
    private static var battery: Any {
        #if os(tvOS)
        return NSNull()
        #else
        let level = UIDevice.current.batteryLevel
        return level < 0 ? NSNull() : Int((Double(level) * percent).rounded())
        #endif
    }

    /// The screen's size in points, upright (`393x852`).
    private static var screen: Any {
        guard let size = UIScreen.main?.fixedCoordinateSpace.bounds.size else { return NSNull() }
        return "\(Int(size.width))x\(Int(size.height))"
    }
}

/// One visit to a level, timed, counted and logged for the solve log:
/// active time from the board showing, stopped while the app isn't active or
/// a menu is open; every tap, undo, restart and hint; and a log that replays
/// them, entries `[ms, code, …]` (`v` a visit's start with the moves it
/// resumed, `m` a tap that moved, `x` one that only bonked, `u`, `r`, `h` the
/// hint with the moves standing after its rewind and the Switchling it
/// pointed at, `l` leaving). Leaving the level unsolved carries its time,
/// counts and log, under the level's id and fingerprint, to the next visit,
/// so the solve's record covers every visit since the level was last cleared.
final class PlaytestRun: NSObject {
    /// What stops the clock.
    enum Pause {
        /// The app is in the background, or covered.
        case inactive
        /// The pause menu or the guide is open.
        case menu
    }

    /// What the player did, so many times each.
    fileprivate struct Counts: Codable {
        var taps = 0
        var undos = 0
        var restarts = 0
        var hints = 0
    }

    /// Entries `[ms, code, …]` written as JSON, no more than `logLimit`.
    fileprivate struct Log: Codable {
        var entries: [String] = []
        var isTruncated = false

        mutating func append(_ entry: [Any]) {
            guard entries.count < PlaytestRun.logLimit else {
                isTruncated = true
                return
            }
            entries.append(JSONText.canonical(entry))
        }
    }

    /// The level's play since it was last cleared, carried from visit to visit.
    fileprivate struct Tally: Codable {
        var seconds: TimeInterval = 0
        var counts = Counts()
        /// On the carried clock, from the first visit's start.
        var log = Log()
    }

    /// What a record says the player did.
    fileprivate struct Play {
        let milliseconds: Int
        let moves: Int
        let counts: Counts
        let log: Log
    }

    fileprivate static let logLimit = 600
    private static let millisecondsPerSecond = 1000.0

    private let levelID: String
    private let version: LevelCatalog.Version
    /// Where the play waits while the level is left unsolved.
    private let key: String
    private var tally: Tally
    /// When the clock last started (system uptime); nil while it's stopped.
    private var runningSince: TimeInterval?
    private var pauses: Set<Pause> = []
    /// Solved or left: nothing counts until the level is played again.
    private var isOver = false
    /// The app-state observers, removed as the run goes.
    private var observers: [NSObjectProtocol] = []

    fileprivate init(levelID: String, version: LevelCatalog.Version, resumed: [GameSession.Move]) {
        self.levelID = levelID
        self.version = version
        key = "\(levelID).\(version.fingerprint)"
        tally = PlaytestLog.shared.unsolved(key) ?? Tally()
        super.init()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.resignActive() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.becomeActive() }
            },
        ]
        if UIApplication.shared.applicationState != .active { pauses.insert(.inactive) }
        note("v", [Self.steps(resumed)])
        // The board shows as the scene fades in.
        startClock(after: DesignSystem.sceneRevealDelay)
    }

    /// Stops the clock while `pause` lasts (`isOn`), and starts it again
    /// once nothing stops it. Leaving the app isn't leaving the level.
    func set(_ pause: Pause, isOn: Bool) {
        if isOn {
            guard pauses.insert(pause).inserted else { return }
            stopClock()
            keep()
        } else if pauses.remove(pause) != nil {
            startClock()
        }
    }

    /// A tap played `id`'s arrow, `direction`: a move (`moved`, the tick
    /// advanced) or only a bonk. The winning move stops the clock and
    /// records the solve.
    func tapped(_ id: String, _ direction: Direction, moved: Bool, in session: GameSession) {
        guard !isOver else { return }
        guard moved else {
            note("x", [id])
            return keep()
        }
        bump(\.taps)
        if session.isWon { stopClock() }
        note("m", [id, direction.rawValue])
        guard session.isWon else { return keep() }
        isOver = true
        PlaytestLog.shared.keep(nil, for: key)
        let play = Play(milliseconds: Self.milliseconds(tally.seconds), moves: session.moves.count, counts: tally.counts, log: tally.log)
        PlaytestLog.shared.record(levelID: levelID, version: version, play: play, firstClear: session.isFirstClear)
    }

    func undid() {
        guard !isOver else { return }
        bump(\.undos)
        note("u")
        keep()
    }

    func restarted() {
        guard !isOver else { return }
        bump(\.restarts)
        note("r")
        keep()
    }

    /// The hint rewound the board to `standing` moves and pointed at `actor`.
    func hinted(standing: Int, actor: String?) {
        guard !isOver else { return }
        bump(\.hints)
        note("h", [standing, actor.map { $0 as Any } ?? NSNull()])
        keep()
    }

    /// Another device's moves arrived: the board stands on them now.
    func caughtUp(_ moves: [GameSession.Move]) {
        guard !isOver else { return }
        note("v", [Self.steps(moves)])
        keep()
    }

    /// The won level is played again: a new solve starts from nothing.
    func replay() {
        tally = Tally()
        isOver = false
        runningSince = nil
        note("v", [[Any]()])
        startClock()
    }

    /// The player left the level unsolved: its time, counts and log carry
    /// over to the next visit.
    func leave() {
        guard !isOver else { return }
        stopClock()
        note("l")
        isOver = true
        PlaytestLog.shared.keep(tally, for: key)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * millisecondsPerSecond).rounded())
    }

    /// Moves as the log writes them, `[[id, direction], …]`.
    private static func steps(_ moves: [GameSession.Move]) -> [Any] {
        moves.map { [$0.id, $0.direction.rawValue] }
    }

    private var elapsed: TimeInterval {
        tally.seconds + (runningSince.map { max(0, Self.now - $0) } ?? 0)
    }

    /// Logs `code` and its `details` now, on the carried clock.
    private func note(_ code: String, _ details: [Any] = []) {
        tally.log.append([Self.milliseconds(elapsed), code] + details)
    }

    private func bump(_ counter: WritableKeyPath<Counts, Int>) {
        tally.counts[keyPath: counter] += 1
    }

    private func startClock(after delay: TimeInterval = 0) {
        guard !isOver, pauses.isEmpty, runningSince == nil else { return }
        runningSince = Self.now + delay
    }

    private func stopClock() {
        tally.seconds = elapsed
        runningSince = nil
    }

    /// Saves the play so far, in case the app quits before the level is
    /// solved or left.
    private func keep() {
        guard !isOver else { return }
        var kept = tally
        kept.seconds = elapsed
        PlaytestLog.shared.keep(kept, for: key)
    }

    private func resignActive() {
        set(.inactive, isOn: true)
    }

    private func becomeActive() {
        set(.inactive, isOn: false)
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
