import Foundation
import Testing
@testable import PlatformShim

// Saved data syncing between two Android devices through Play Games Saved
// Games: one snapshot, opened, merged by `SyncEngine` and committed. Play is
// a byte buffer here; each device is a channel, an engine and its own
// defaults, as two phones signed in to one Play Games profile are.

/// Play Games' copy of the snapshot, shared by every device.
private final class FakePlay {
    var snapshot = Data()
    var commits = 0
}

/// One device: what `PlayGamesServices.java` would answer, queued until
/// `pump()` so nothing re-enters the cloud while it is mid-call.
private final class Device {
    let play: FakePlay
    let defaults: UserDefaults
    var clock: TimeInterval = 1000
    var updated: [[String]] = []
    private var queue: [[String: Any]] = []
    private var later: [() -> Void] = []
    private var nextHandle = 1
    private(set) var calls: [String] = []
    private(set) lazy var channel = PlatformChannel { [unowned self] name, data in
        let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        self.calls.append(name)
        switch name {
        case "games.openSnapshot":
            let handle = self.nextHandle
            self.nextHandle += 1
            self.queue.append(["service": "games", "event": "snapshotOpened", "request": arguments["request"] ?? 0,
                               "ok": true, "handle": handle, "data": self.play.snapshot.base64EncodedString()])
        case "games.commitSnapshot":
            self.play.snapshot = Data(base64Encoded: arguments["data"] as? String ?? "") ?? Data()
            self.play.commits += 1
            self.queue.append(["service": "games", "event": "snapshotCommitted", "handle": arguments["handle"] ?? 0, "ok": true])
        default:
            break
        }
        return nil
    }
    private(set) lazy var cloud = PlaySavedGamesCloud(channel: channel) { [unowned self] _, work in self.later.append(work) }
    private(set) lazy var engine = SyncEngine(defaults: defaults, cloud: cloud, now: { [unowned self] in self.clock }) { [unowned self] keys in
        self.updated.append(keys.sorted())
    }

    init(_ play: FakePlay) {
        self.play = play
        let name = UUID().uuidString
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    func start() {
        engine.start(syncing: [["cleared": .union, "language": .latest]])
    }

    func signIn() {
        cloud.signInChanged(true)
        pump()
    }

    func pump() {
        while !queue.isEmpty {
            let batch = queue
            queue = []
            channel.deliver(batch)
        }
    }

    /// Runs what was scheduled (the commit delay, the poll).
    func runLater() {
        let work = later
        later = []
        work.forEach { $0() }
        pump()
    }

    var cleared: Set<String> { Set(defaults.stringArray(forKey: "cleared") ?? []) }
    var language: String? { defaults.string(forKey: "language") }
}

@Suite("Saved Games")
@MainActor
struct SavedGamesTests {
    @Test("A level cleared on one device turns up on the other, and says so")
    func clearedLevelSyncs() {
        let play = FakePlay()
        let phone = Device(play), tablet = Device(play)
        phone.start()
        tablet.start()
        phone.engine.insert(["garden-1"], intoSetForKey: "cleared")
        phone.signIn()
        #expect(play.commits == 1)
        tablet.signIn()
        #expect(tablet.cleared == ["garden-1"])
        // What `SavedDataObserving` hears through ICloudSyncManager.
        #expect(tablet.updated == [["cleared"]])
    }

    @Test("Clears made apart pool, whichever syncs first")
    func unionPools() {
        let play = FakePlay()
        let phone = Device(play), tablet = Device(play)
        phone.start()
        tablet.start()
        phone.engine.insert(["garden-1", "garden-2"], intoSetForKey: "cleared")
        tablet.engine.insert(["farm-1"], intoSetForKey: "cleared")
        tablet.signIn()
        phone.signIn()
        tablet.engine.synchronize()
        tablet.pump()
        #expect(phone.cleared == ["garden-1", "garden-2", "farm-1"])
        #expect(tablet.cleared == ["garden-1", "garden-2", "farm-1"])
    }

    @Test("The latest change wins, wherever it was made")
    func latestWins() {
        let play = FakePlay()
        let phone = Device(play), tablet = Device(play)
        phone.start()
        tablet.start()
        phone.clock = 2000
        phone.engine.set("ja", forKey: "language")
        tablet.clock = 3000
        tablet.engine.set("fr", forKey: "language")
        tablet.signIn()
        phone.signIn()
        #expect(phone.language == "fr")
        // And an older change made later in sync order doesn't undo it.
        tablet.engine.synchronize()
        tablet.pump()
        #expect(tablet.language == "fr")
    }

    @Test("A reset empties the set everywhere, and what comes after it stays")
    func resetEverywhere() {
        let play = FakePlay()
        let phone = Device(play), tablet = Device(play)
        phone.start()
        tablet.start()
        phone.clock = 2000
        phone.engine.insert(["garden-1"], intoSetForKey: "cleared")
        phone.signIn()
        tablet.signIn()
        #expect(tablet.cleared == ["garden-1"])
        tablet.clock = 3000
        tablet.engine.resetSet(forKey: "cleared")
        tablet.runLater()
        phone.engine.synchronize()
        phone.pump()
        #expect(phone.cleared.isEmpty)
        phone.clock = 4000
        phone.engine.insert(["garden-2"], intoSetForKey: "cleared")
        phone.runLater()
        tablet.engine.synchronize()
        tablet.pump()
        #expect(tablet.cleared == ["garden-2"])
    }

    @Test("A save goes up a few seconds later, not at once and not twice")
    func commitIsDelayed() {
        let play = FakePlay()
        let phone = Device(play)
        phone.start()
        phone.signIn()
        let commits = play.commits
        phone.engine.insert(["garden-1"], intoSetForKey: "cleared")
        phone.engine.insert(["garden-2"], intoSetForKey: "cleared")
        #expect(play.commits == commits)
        phone.runLater()
        #expect(play.commits == commits + 1)
    }

    @Test("Going to the background sends what's waiting")
    func flushOnBackground() {
        let play = FakePlay()
        let phone = Device(play)
        phone.start()
        phone.signIn()
        let commits = play.commits
        phone.engine.insert(["garden-1"], intoSetForKey: "cleared")
        phone.cloud.flush()
        phone.pump()
        #expect(play.commits == commits + 1)
    }

    @Test("Nothing new is discarded, not committed")
    func nothingNew() {
        let play = FakePlay()
        let phone = Device(play)
        phone.start()
        phone.engine.insert(["garden-1"], intoSetForKey: "cleared")
        phone.signIn()
        let commits = play.commits
        phone.engine.synchronize()
        phone.pump()
        #expect(play.commits == commits)
        #expect(phone.calls.last == "games.discardSnapshot")
    }

    @Test("Bytes that aren't a save are left alone")
    func foreignBytesKept() {
        let play = FakePlay()
        play.snapshot = Data("not a property list".utf8)
        let phone = Device(play)
        phone.start()
        phone.engine.insert(["garden-1"], intoSetForKey: "cleared")
        phone.signIn()
        #expect(play.commits == 0)
        #expect(play.snapshot == Data("not a property list".utf8))
    }

    @Test("Signed out, nothing reaches Play and saved data stays on the device")
    func signedOut() {
        let play = FakePlay()
        let phone = Device(play)
        phone.start()
        phone.engine.insert(["garden-1"], intoSetForKey: "cleared")
        phone.runLater()
        #expect(phone.calls.isEmpty)
        #expect(phone.cleared == ["garden-1"])
    }

    @Test("Values keep their types through the snapshot")
    func typesSurvive() {
        let contents: [String: [String: Any]] = ["settings.musicEnabled": ["value": false, "modifiedAt": 12.5]]
        let decoded = PlaySavedGamesCloud.decode(PlaySavedGamesCloud.encode(contents)!)
        #expect(decoded?["settings.musicEnabled"]?["value"] as? Bool == false)
        #expect(decoded?["settings.musicEnabled"]?["modifiedAt"] as? Double == 12.5)
    }
}
