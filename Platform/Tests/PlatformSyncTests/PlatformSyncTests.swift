import Foundation
import Testing
@testable import PlatformSync

/// A fresh defaults suite per device, so one cannot see another's keys.
private func scratchDefaults() -> UserDefaults {
    let name = UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// One device: its own defaults and cloud copy, and a clock.
private final class Device {
    let defaults = scratchDefaults()
    let cloud = MemoryCloud()
    var clock: TimeInterval
    private(set) lazy var manager = ICloudSyncManager(
        configuration: .init(defaults: defaults), cloud: cloud, now: { [unowned self] in self.clock }
    )

    init(clock: TimeInterval) {
        self.clock = clock
    }
}

/// The keys `manager` posts as changed, once the main queue has delivered them.
@MainActor
private func announcedKeys(from manager: ICloudSyncManager, during work: () -> Void) async -> [String] {
    var keys: [String] = []
    let observer = NotificationCenter.default.addObserver(
        forName: ICloudSyncManager.didUpdateLocalData, object: manager, queue: nil
    ) { note in
        keys += note.userInfo?[ICloudSyncManager.updatedKeysUserInfoKey] as? [String] ?? []
    }
    work()
    // The post is queued on the main queue: let it run.
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    NotificationCenter.default.removeObserver(observer)
    return keys.sorted()
}

@MainActor
struct SyncManagerTests {
    @Test("Settings and sets travel between two devices, and the other device hears which keys changed")
    func twoDevices() async {
        let phone = Device(clock: 100)
        let pad = Device(clock: 100)
        let keys: [[String: ICloudSyncManager.Merge]] = [["settings.musicEnabled": .latest], ["progress.cleared": .union]]
        phone.manager.start(syncing: keys, adoptingLaunchArguments: false)
        pad.manager.start(syncing: keys, adoptingLaunchArguments: false)

        phone.manager.set(false, forKey: "settings.musicEnabled")
        phone.manager.insert(["level-1", "level-2"], intoSetForKey: "progress.cleared")
        pad.clock = 150
        pad.manager.insert(["level-9"], intoSetForKey: "progress.cleared")

        let changed = await announcedKeys(from: pad.manager) { phone.cloud.deliver(to: pad.cloud) }
        #expect(changed == ["progress.cleared", "settings.musicEnabled"])
        #expect(pad.manager.object(forKey: "settings.musicEnabled") as? Bool == false)
        #expect(pad.manager.stringArray(forKey: "progress.cleared") == ["level-1", "level-2", "level-9"])

        pad.cloud.deliver(to: phone.cloud)
        #expect(phone.manager.stringArray(forKey: "progress.cleared") == ["level-1", "level-2", "level-9"])
    }

    @Test("A reset on one device empties the set on the other")
    func resetTravels() {
        let phone = Device(clock: 100)
        let pad = Device(clock: 100)
        let keys: [[String: ICloudSyncManager.Merge]] = [["progress.cleared": .union]]
        phone.manager.start(syncing: keys, adoptingLaunchArguments: false)
        pad.manager.start(syncing: keys, adoptingLaunchArguments: false)
        phone.manager.insert(["level-1"], intoSetForKey: "progress.cleared")
        phone.cloud.deliver(to: pad.cloud)
        #expect(pad.manager.stringArray(forKey: "progress.cleared") == ["level-1"])

        pad.clock = 200
        pad.manager.resetSet(forKey: "progress.cleared")
        pad.cloud.deliver(to: phone.cloud)

        #expect(phone.manager.stringArray(forKey: "progress.cleared") == [])
    }

    @Test("Keys made during play under a synced prefix sync, are listed and removed together")
    func prefixes() {
        let phone = Device(clock: 100)
        let pad = Device(clock: 100)
        for device in [phone, pad] {
            device.manager.start(prefixes: ["game.": .latest, "settings.": .latest], adoptingLaunchArguments: false)
        }
        phone.manager.set(Data([7]), forKey: "game.level.3")
        phone.manager.set(4, forKey: "game.best")
        phone.manager.set(true, forKey: "settings.sound")
        phone.defaults.set("kept here", forKey: "device.only")
        phone.cloud.deliver(to: pad.cloud)

        #expect(pad.manager.data(forKey: "game.level.3") == Data([7]))
        #expect(pad.manager.integer(forKey: "game.best") == 4)
        #expect(Set(pad.manager.dictionaryRepresentation().keys) == ["game.level.3", "game.best", "settings.sound"])
        #expect(pad.manager.merge(for: "device.only") == nil)

        pad.clock = 200
        pad.manager.removeObjects(withPrefixes: ["game."])
        pad.cloud.deliver(to: phone.cloud)

        #expect(phone.manager.object(forKey: "game.level.3") == nil)
        #expect(phone.manager.object(forKey: "game.best") == nil)
        #expect(phone.manager.bool(forKey: "settings.sound"))
    }

    @Test("Launch arguments for synced keys are read here, and kept out of the cloud")
    func launchArguments() {
        let device = Device(clock: 100)
        device.defaults.setVolatileDomain(["settings.musicEnabled": "NO"], forName: UserDefaults.argumentDomain)
        device.manager.start(syncing: [["settings.musicEnabled": .latest]], adoptingLaunchArguments: true)

        #expect(device.manager.object(forKey: "settings.musicEnabled") as? Bool == false)
        #expect(device.cloud.dictionary(forKey: "settings.musicEnabled") == nil)
    }
}

/// iCloud's key-value store as a test holds it.
private final class MemoryStore: FlatKeyValueStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    var dictionaryRepresentation: [String: Any] { values }
    func synchronize() -> Bool { true }
}

@MainActor
struct KeyValueLayoutTests {
    @Test("Records are kept one dictionary a key")
    func records() {
        let store = MemoryStore()
        let cloud = ICloudKeyValueStore(store: store)
        cloud.set([SyncEngine.Record.value: 3, SyncEngine.Record.modifiedAt: TimeInterval(10)], forKey: "best")

        #expect((store.values["best"] as? [String: Any])?[SyncEngine.Record.value] as? Int == 3)
        #expect(cloud.dictionary(forKey: "best")?[SyncEngine.Record.modifiedAt] as? TimeInterval == 10)
    }

    @Test("A flat layout reads what an earlier build wrote and writes it the same way")
    func flat() {
        let store = MemoryStore()
        store.values["player"] = Data([1])
        store.values["player.modifiedAt"] = TimeInterval(50)
        store.values["score"] = 9
        store.values["old.score"] = TimeInterval(70)
        let cloud = ICloudKeyValueStore(
            store: store, layout: .flat(.init(suffix: ".modifiedAt"), legacy: .init(prefix: "old."))
        )

        #expect(cloud.dictionary(forKey: "player")?[SyncEngine.Record.value] as? Data == Data([1]))
        #expect(cloud.dictionary(forKey: "player")?[SyncEngine.Record.modifiedAt] as? TimeInterval == 50)
        #expect(cloud.dictionary(forKey: "score")?[SyncEngine.Record.modifiedAt] as? TimeInterval == 70)
        #expect(Set(cloud.keys) == ["player", "score"])

        cloud.set([SyncEngine.Record.modifiedAt: TimeInterval(90)], forKey: "player")
        #expect(store.values["player"] == nil)
        #expect(store.values["player.modifiedAt"] as? TimeInterval == 90)

        // A set's record stays whole.
        cloud.set([SyncEngine.Record.items: ["a": TimeInterval(1)], SyncEngine.Record.resetAt: TimeInterval(0)], forKey: "cleared")
        #expect(cloud.dictionary(forKey: "cleared")?[SyncEngine.Record.items] as? [String: TimeInterval] == ["a": 1])
    }

    @Test("A device moving to the manager keeps a newer value an earlier build saved")
    func migration() {
        let store = MemoryStore()
        store.values["player"] = Data([1])
        store.values["player.modifiedAt"] = TimeInterval(50)
        let defaults = scratchDefaults()
        defaults.set(Data([2]), forKey: "player")
        defaults.set(TimeInterval(80), forKey: "player.modifiedAt")
        let stamps = SyncEngine.Stamps(suffix: ".modifiedAt")
        let cloud = ICloudKeyValueStore(store: store, layout: .flat(stamps))
        let manager = ICloudSyncManager(configuration: .init(defaults: defaults, stamps: stamps), cloud: cloud, now: { 100 })
        manager.start(syncing: [["player": .latest]], adoptingLaunchArguments: false)

        #expect(manager.data(forKey: "player") == Data([2]))
        #expect(store.values["player"] as? Data == Data([2]))
        #expect(store.values["player.modifiedAt"] as? TimeInterval == 80)
    }
}
