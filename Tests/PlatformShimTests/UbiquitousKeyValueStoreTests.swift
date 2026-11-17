import Foundation
import Testing
@testable import PlatformShim
@testable import SpriteKitShim

// iCloud's key-value store on Android (`NSUbiquitousKeyValueStore` there):
// values kept on the device, newest write of each key winning between
// devices, and the changed keys posted as iCloud posts them. Two devices are
// two stores on two `MemoryCloud`s, handed each other's contents.

@MainActor
private final class Device {
    let defaults: UserDefaults
    let cloud = MemoryCloud()
    let store: UbiquitousKeyValueStore
    var now: TimeInterval
    var posted: [(reason: Int, keys: [String])] = []
    private var observer: NSObjectProtocol?

    init(_ name: String, at time: TimeInterval) {
        let suite = "ubiquitous-test-\(name)-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        now = time
        var clock: () -> TimeInterval = { 0 }
        store = UbiquitousKeyValueStore(defaults: defaults, clock: { clock() })
        clock = { [weak self] in self?.now ?? 0 }
        observer = NotificationCenter.default.addObserver(
            forName: UbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: nil
        ) { [weak self] note in
            let reason = note.userInfo?[UbiquitousKeyValueStore.changeReasonKey] as? Int ?? -1
            let keys = note.userInfo?[UbiquitousKeyValueStore.changedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated { self?.posted.append((reason, keys)) }
        }
        store.cloud = cloud
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// What this device's cloud holds reaches `other`, as Play hands a
    /// snapshot over on the next sync.
    func sync(to other: Device) {
        cloud.deliver(to: other.cloud)
    }
}

@Suite("NSUbiquitousKeyValueStore")
@MainActor
struct UbiquitousKeyValueStoreTests {
    @Test("Values read back by type, and stay on the device across launches")
    func values() {
        let device = Device("a", at: 100)
        let data = Data([1, 2, 3])
        device.store.set(data, forKey: "snapshot")
        device.store.set("hello", forKey: "word")
        device.store.set(true, forKey: "flag")
        device.store.set(Int64(42), forKey: "count")
        device.store.set(2.5, forKey: "ratio")
        #expect(device.store.data(forKey: "snapshot") == data)
        #expect(device.store.string(forKey: "word") == "hello")
        #expect(device.store.bool(forKey: "flag"))
        #expect(device.store.longLong(forKey: "count") == 42)
        #expect(device.store.double(forKey: "ratio") == 2.5)
        #expect(device.store.data(forKey: "missing") == nil)

        let relaunched = UbiquitousKeyValueStore(defaults: device.defaults)
        #expect(relaunched.data(forKey: "snapshot") == data)
        #expect(relaunched.string(forKey: "word") == "hello")

        device.store.removeObject(forKey: "word")
        #expect(device.store.string(forKey: "word") == nil)
        #expect(device.store.dictionaryRepresentation["word"] == nil)
    }

    @Test("Another device's newer write arrives, and its key is posted as a server change")
    func newerArrives() {
        let a = Device("a", at: 100)
        let b = Device("b", at: 200)
        a.store.set("from a", forKey: "progress")
        b.store.set("from b", forKey: "progress")
        b.sync(to: a)
        #expect(a.store.string(forKey: "progress") == "from b")
        #expect(a.posted.last?.reason == UbiquitousKeyValueStore.serverChange)
        #expect(a.posted.last?.keys == ["progress"])
    }

    @Test("An older write from another device loses, and this device's goes back to the cloud")
    func olderLoses() {
        let a = Device("a", at: 300)
        let b = Device("b", at: 200)
        a.store.set("from a", forKey: "progress")
        b.store.set("from b", forKey: "progress")
        b.sync(to: a)
        #expect(a.store.string(forKey: "progress") == "from a")
        #expect(a.posted.isEmpty)
        // Merging put a's newer record in its cloud for the next commit.
        let record = a.cloud.dictionary(forKey: "ubiquitous.progress").flatMap(UbiquitousRecord.init(dictionary:))
        #expect(record?.value as? String == "from a")
    }

    @Test("A key only another device has set arrives too")
    func newKey() {
        let a = Device("a", at: 100)
        let b = Device("b", at: 200)
        b.store.set(Data([9]), forKey: "snapshot")
        b.sync(to: a)
        #expect(a.store.data(forKey: "snapshot") == Data([9]))
        #expect(a.posted.last?.keys == ["snapshot"])
    }

    @Test("A newer removal wins over an older value")
    func removal() {
        let a = Device("a", at: 100)
        let b = Device("b", at: 200)
        a.store.set("old", forKey: "word")
        b.store.set("x", forKey: "word")
        b.store.removeObject(forKey: "word")
        b.sync(to: a)
        #expect(a.store.string(forKey: "word") == nil)
        #expect(a.posted.last?.keys == ["word"])
    }

    @Test("The same value arriving again changes nothing and posts nothing")
    func sameValue() {
        let a = Device("a", at: 100)
        let b = Device("b", at: 200)
        a.store.set("same", forKey: "word")
        b.store.set("same", forKey: "word")
        b.sync(to: a)
        #expect(a.posted.isEmpty)
    }

    @Test("Values that aren't property lists are not kept, as on Apple")
    func notPropertyList() {
        let a = Device("a", at: 100)
        a.store.set(UUID(), forKey: "id")
        #expect(a.store.object(forKey: "id") == nil)
    }
}
