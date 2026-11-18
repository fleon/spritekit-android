import Foundation
import Testing
@testable import PlatformSync

/// iCloud's key-value store as Foundation hands values back: numbers and
/// data bridged.
private final class BridgedStore: FlatKeyValueStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    var dictionaryRepresentation: [String: Any] { values }
    func synchronize() -> Bool { true }

    func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
}

private func freshDefaults() -> UserDefaults {
    let name = UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// A build moving to the shared manager over data a flat build saved: on the
/// device and in the cloud, with times kept beside each value.
@MainActor
struct FlatLayoutUpgradeTests {
    @Test("Blobs with a `.modifiedAt` time beside them read back, newer side winning, and old builds read what's written")
    func suffixStamps() async {
        let stamps = SyncEngine.Stamps(suffix: ".modifiedAt")
        let store = BridgedStore()
        let defaults = freshDefaults()
        // This device, as the earlier build left it.
        defaults.set(Data([1]), forKey: "save.player")
        defaults.set(TimeInterval(100), forKey: "save.player.modifiedAt")
        defaults.set(Data([3]), forKey: "save.game")
        defaults.set(TimeInterval(250), forKey: "save.game.modifiedAt")
        defaults.set(Data([4]), forKey: "save.levels")
        defaults.set(TimeInterval(150), forKey: "save.levels.modifiedAt")
        // The cloud, as another device's earlier build wrote it: a newer
        // player, the game removed since, nothing for the levels yet.
        store.values["save.player"] = NSData(data: Data([2]))
        store.values["save.player.modifiedAt"] = NSNumber(value: 200.0)
        store.values["save.game.modifiedAt"] = NSNumber(value: 300.0)

        var clock: TimeInterval = 1000
        let cloud = ICloudKeyValueStore(store: store, layout: .flat(stamps))
        let manager = ICloudSyncManager(configuration: .init(defaults: defaults, stamps: stamps), cloud: cloud, now: { clock })
        manager.start(syncing: [["save.player": .latest, "save.game": .latest, "save.levels": .latest]], adoptingLaunchArguments: false)

        #expect(manager.data(forKey: "save.player") == Data([2]))
        #expect(defaults.double(forKey: "save.player.modifiedAt") == 200)
        #expect(manager.data(forKey: "save.game") == nil)
        #expect(defaults.double(forKey: "save.game.modifiedAt") == 300)
        #expect(manager.data(forKey: "save.levels") == Data([4]))
        // Uploaded as the earlier build would have, with its own time.
        #expect(store.values["save.levels"] as? Data == Data([4]))
        #expect(store.double(forKey: "save.levels.modifiedAt") == 150)
        #expect(store.values.keys.allSatisfy { !$0.hasPrefix("sync.") })

        // Written now: an earlier build reads it under the key, time beside it.
        clock = 1100
        manager.set(Data([9]), forKey: "save.player")
        #expect(store.values["save.player"] as? Data == Data([9]))
        #expect(store.double(forKey: "save.player.modifiedAt") == 1100)
        clock = 1200
        manager.removeObject(forKey: "save.levels")
        #expect(store.values["save.levels"] == nil)
        #expect(store.double(forKey: "save.levels.modifiedAt") == 1200)

        // An earlier build on another device saves; the news arrives here.
        // (Let what the start posted be delivered first.)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        store.values["save.player"] = NSData(data: Data([5]))
        store.values["save.player.modifiedAt"] = NSNumber(value: 1300.0)
        var announced: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: ICloudSyncManager.didUpdateLocalData, object: manager, queue: nil
        ) { note in
            announced += note.userInfo?[ICloudSyncManager.updatedKeysUserInfoKey] as? [String] ?? []
        }
        cloud.externalChanges?()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        NotificationCenter.default.removeObserver(observer)
        #expect(manager.data(forKey: "save.player") == Data([5]))
        #expect(announced == ["save.player"])
    }

    @Test("Prefixed keys with `sync.` times and an older time prefix read back, keys only in the cloud too")
    func prefixAndLegacyStamps() {
        let legacy = SyncEngine.Stamps(prefix: "old-stamp.")
        let store = BridgedStore()
        let defaults = freshDefaults()
        // This device: one value timed only under the older prefix, one under `sync.`.
        defaults.set(5, forKey: "game.best")
        defaults.set(TimeInterval(100), forKey: "old-stamp.game.best")
        defaults.set(false, forKey: "settings.sound")
        defaults.set(TimeInterval(120), forKey: "sync.settings.sound")
        defaults.set("never synced", forKey: "device.only")
        // The cloud: a newer best timed under the older prefix, a level only
        // there, an older sound setting.
        store.values["game.best"] = NSNumber(value: 7)
        store.values["old-stamp.game.best"] = NSNumber(value: 150.0)
        store.values["game.level.3"] = NSData(data: Data([3]))
        store.values["sync.game.level.3"] = NSNumber(value: 130.0)
        store.values["settings.sound"] = NSNumber(value: true)
        store.values["sync.settings.sound"] = NSNumber(value: 110.0)

        var clock: TimeInterval = 1000
        let cloud = ICloudKeyValueStore(store: store, layout: .flat(.standard, legacy: legacy))
        let manager = ICloudSyncManager(configuration: .init(defaults: defaults, legacyStamps: legacy), cloud: cloud, now: { clock })
        manager.start(prefixes: ["game.": .latest, "settings.": .latest], adoptingLaunchArguments: false)

        #expect(manager.integer(forKey: "game.best") == 7)
        #expect(defaults.double(forKey: "sync.game.best") == 150)
        #expect(manager.data(forKey: "game.level.3") == Data([3]))
        #expect(manager.bool(forKey: "settings.sound") == false)
        #expect((store.values["settings.sound"] as? NSNumber)?.boolValue == false)
        #expect(store.double(forKey: "sync.settings.sound") == 120)
        #expect(Set(manager.dictionaryRepresentation().keys) == ["game.best", "game.level.3", "settings.sound"])
        #expect(store.values["device.only"] == nil)
        // The older prefix is read, never written.
        #expect(store.values.keys.filter { $0.hasPrefix("old-stamp.") } == ["old-stamp.game.best"])

        clock = 1100
        manager.removeObjects(withPrefixes: ["game."])
        #expect(store.values["game.best"] == nil)
        #expect(store.values["game.level.3"] == nil)
        #expect(store.double(forKey: "sync.game.best") == 1100)
        #expect(manager.object(forKey: "game.best") == nil)
        #expect(manager.bool(forKey: "settings.sound") == false)
    }

    @Test("A launch argument never reaches the cloud as its string")
    func launchArgumentNotUploadedRaw() {
        let defaults = freshDefaults()
        let cloud = MemoryCloud()
        defaults.set(true, forKey: "settings.music")
        defaults.set(TimeInterval(100), forKey: "sync.settings.music")
        cloud.set([SyncEngine.Record.value: true, SyncEngine.Record.modifiedAt: TimeInterval(100)], forKey: "settings.music")
        var uploaded: [Any?] = []
        let recording = RecordingCloud(cloud) { uploaded.append($0[SyncEngine.Record.value]) }
        defaults.setVolatileDomain(["settings.music": "NO"], forName: UserDefaults.argumentDomain)
        let manager = ICloudSyncManager(configuration: .init(defaults: defaults), cloud: recording, now: { 200 })
        manager.start(syncing: [["settings.music": .latest]], adoptingLaunchArguments: true)

        #expect(manager.object(forKey: "settings.music") as? Bool == false)
        #expect(uploaded.allSatisfy { !($0 is String) })
    }
}

private final class RecordingCloud: CloudKeyValueStore {
    private let inner: CloudKeyValueStore
    private let wrote: ([String: Any]) -> Void
    init(_ inner: CloudKeyValueStore, wrote: @escaping ([String: Any]) -> Void) {
        self.inner = inner
        self.wrote = wrote
    }
    var externalChanges: (() -> Void)? {
        get { inner.externalChanges }
        set { inner.externalChanges = newValue }
    }
    func dictionary(forKey key: String) -> [String: Any]? { inner.dictionary(forKey: key) }
    func set(_ dictionary: [String: Any], forKey key: String) {
        wrote(dictionary)
        inner.set(dictionary, forKey: key)
    }
    func synchronize() -> Bool { inner.synchronize() }
    var keys: [String] { inner.keys }
}
