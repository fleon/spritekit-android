import Foundation

/// iCloud's key-value store, on Play Games **Saved Games**: what
/// `ICloudSyncManager` syncs (levels cleared, the level left part-way,
/// settings, language, board firsts…) follows the player to every Android
/// device signed in to the same Play Games profile.
///
/// One snapshot holds every key's record (`[key: record]`, a binary property
/// list, so a Bool stays a Bool). A **sync** opens it, takes what Play holds
/// as the cloud's copy, and lets `SyncEngine` merge — latest change wins for
/// a value, sets pool, a reset empties — which writes back whatever this
/// device has that Play hasn't. If anything was written the snapshot is
/// committed, otherwise discarded. Because every record merges commutatively,
/// it doesn't matter which device's copy Play hands back on a conflict: this
/// device's own changes are in its saved data with their times, and the
/// merge puts them back.
///
/// A sync runs as Play Games signs in, when the game asks (`synchronize()`:
/// at launch and coming back to the front), a few seconds after the game
/// saves something (`commitDelay`), every couple of minutes while it plays
/// (`pollInterval`, so another device's clears turn up without a relaunch),
/// and at once as it goes to the background (`flush()`). Signed out it does
/// nothing and the game keeps its saved data on the device, as under
/// `-ICloudOff`.
public final class PlaySavedGamesCloud: CloudKeyValueStore {
    public static let snapshotName = "switchlings-progress"
    public static let commitDelay: TimeInterval = 5
    public static let pollInterval: TimeInterval = 120

    public var externalChanges: (() -> Void)?

    private let channel: PlatformChannel
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private var contents: [String: [String: Any]] = [:]
    private var isSignedIn = false
    /// Written since the snapshot was last committed.
    private var dirty = false
    private var inFlight = false
    private var again = false
    private var commitScheduled = false
    private var pollScheduled = false
    private var request = 0
    private var committing: Int?

    /// `after` runs a closure later on the game's thread; the default is the
    /// main queue, which the shell drains once a frame.
    public init(
        channel: PlatformChannel,
        after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.channel = channel
        self.after = after
        channel.on("games") { [weak self] event, body in self?.handle(event, body) }
    }

    // MARK: - CloudKeyValueStore

    public func dictionary(forKey key: String) -> [String: Any]? { contents[key] }

    public func set(_ dictionary: [String: Any], forKey key: String) {
        contents[key] = dictionary
        dirty = true
        guard isSignedIn, !commitScheduled else { return }
        commitScheduled = true
        after(Self.commitDelay) { [weak self] in
            self?.commitScheduled = false
            self?.sync()
        }
    }

    @discardableResult
    public func synchronize() -> Bool {
        guard isSignedIn else { return false }
        sync()
        return true
    }

    /// The game is going to the background: what it wrote goes to Play now.
    public func flush() {
        if dirty { sync() }
    }

    /// Play Games signed in or out (`PlayGamesAchievements.signInChanged`).
    public func signInChanged(_ signedIn: Bool) {
        isSignedIn = signedIn
        if signedIn {
            sync()
            schedulePoll()
        }
    }

    // MARK: - Syncing

    private func sync() {
        guard isSignedIn else { return }
        if inFlight {
            again = true
            return
        }
        inFlight = true
        request += 1
        channel.call("games.openSnapshot", ["name": Self.snapshotName, "request": request])
    }

    private func schedulePoll() {
        guard !pollScheduled else { return }
        pollScheduled = true
        after(Self.pollInterval) { [weak self] in
            guard let self else { return }
            pollScheduled = false
            guard isSignedIn else { return }
            sync()
            schedulePoll()
        }
    }

    private func handle(_ event: String, _ body: PlatformChannel.Message) {
        switch event {
        case "snapshotOpened":
            guard body.int("request") == request else { return }
            opened(body)
        case "snapshotCommitted":
            guard body.int("handle") == committing else { return }
            committing = nil
            if body.bool("ok") != true { dirty = true }
            finished()
        default:
            break
        }
    }

    private func opened(_ body: PlatformChannel.Message) {
        guard body.bool("ok") == true, let handle = body.int("handle") else {
            // Offline, or signed out meanwhile: the next sync tries again.
            finished()
            return
        }
        // No bytes means they couldn't be read, and bytes that aren't ours
        // (a corrupted write) can't be merged: either way Play's copy is
        // left alone rather than overwritten blind. A new snapshot's bytes
        // are empty, which is a copy holding nothing.
        guard let text = body["data"] as? String, let data = Data(base64Encoded: text), let remote = Self.decode(data) else {
            channel.call("games.discardSnapshot", ["handle": handle])
            finished()
            return
        }
        merge(into: remote, handle: handle)
    }

    /// Takes Play's copy as the cloud's, lets the engine merge this device's
    /// saved data into it, and commits if that changed anything.
    private func merge(into remote: [String: [String: Any]], handle: Int) {
        contents = remote
        dirty = false
        externalChanges?()
        guard dirty, let data = Self.encode(contents) else {
            channel.call("games.discardSnapshot", ["handle": handle])
            finished()
            return
        }
        dirty = false
        committing = handle
        channel.call("games.commitSnapshot", [
            "handle": handle,
            "data": data.base64EncodedString(),
            "description": "Switchlings",
        ])
    }

    private func finished() {
        inFlight = false
        if again {
            again = false
            sync()
        }
    }

    // MARK: - The snapshot's bytes

    static func encode(_ contents: [String: [String: Any]]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0)
    }

    static func decode(_ data: Data) -> [String: [String: Any]]? {
        if data.isEmpty { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: [String: Any]]
    }
}
