import Foundation
import Testing
@testable import PlatformShim

// The merge the game's saved data depends on, run on the host with two
// devices and a cloud between them. Every case here is one the game relies
// on: levels cleared pool rather than overwrite, a reset on one device
// empties the other, a settings switch follows the latest change.

/// A fresh defaults suite per test, so one cannot see another's keys.
private func scratchDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Sync: values that keep the latest change")
struct LatestMergeTests {
    @Test("A value saved here reaches the cloud with when it changed")
    func savesToCloud() {
        let defaults = scratchDefaults()
        let cloud = MemoryCloud()
        let engine = SyncEngine(defaults: defaults, cloud: cloud, now: { 100 }) { _ in }
        engine.start(syncing: [["settings.musicEnabled": .latest]])

        engine.set(false, forKey: "settings.musicEnabled")

        #expect(defaults.object(forKey: "settings.musicEnabled") as? Bool == false)
        let record = cloud.dictionary(forKey: "settings.musicEnabled")
        #expect(record?[SyncEngine.Record.value] as? Bool == false)
        #expect(record?[SyncEngine.Record.modifiedAt] as? TimeInterval == 100)
    }

    @Test("The newer change wins, whichever device made it")
    func newerWins() {
        let cloud = MemoryCloud()
        var now: TimeInterval = 100
        let defaults = scratchDefaults()
        var changed: [String] = []
        let engine = SyncEngine(defaults: defaults, cloud: cloud, now: { now }) { changed += $0 }
        engine.start(syncing: [["settings.musicEnabled": .latest]])
        engine.set(false, forKey: "settings.musicEnabled")

        // Another device switched it back on, later.
        now = 200
        engine.simulateRemoteSet(true, forKey: "settings.musicEnabled")

        #expect(defaults.object(forKey: "settings.musicEnabled") as? Bool == true)
        #expect(changed == ["settings.musicEnabled"])
    }

    @Test("An older change from another device is ignored and corrected")
    func olderLoses() {
        let cloud = MemoryCloud()
        var now: TimeInterval = 500
        let defaults = scratchDefaults()
        let engine = SyncEngine(defaults: defaults, cloud: cloud, now: { now }) { _ in }
        engine.start(syncing: [["settings.soundEnabled": .latest]])
        engine.set(false, forKey: "settings.soundEnabled")

        // An older write lands in the cloud.
        cloud.set([SyncEngine.Record.value: true, SyncEngine.Record.modifiedAt: TimeInterval(100)],
                  forKey: "settings.soundEnabled")
        now = 600
        engine.synchronize()

        #expect(defaults.object(forKey: "settings.soundEnabled") as? Bool == false)
        #expect(cloud.dictionary(forKey: "settings.soundEnabled")?[SyncEngine.Record.value] as? Bool == false)
    }

    @Test("Nothing is announced when nothing moved")
    func quietWhenUnchanged() {
        let cloud = MemoryCloud()
        var changed: [[String]] = []
        let engine = SyncEngine(defaults: scratchDefaults(), cloud: cloud, now: { 1 }) { changed.append($0) }
        engine.start(syncing: [["settings.musicEnabled": .latest]])
        engine.set(true, forKey: "settings.musicEnabled")
        engine.synchronize()
        engine.synchronize()

        #expect(changed.isEmpty)
    }

    @Test("With no cloud at all a value still saves and reads back")
    func localOnly() {
        let defaults = scratchDefaults()
        let engine = SyncEngine(defaults: defaults, cloud: LocalOnlyCloud(), now: { 7 }) { _ in }
        engine.start(syncing: [["settings.musicEnabled": .latest]])

        engine.set(false, forKey: "settings.musicEnabled")

        #expect(defaults.object(forKey: "settings.musicEnabled") as? Bool == false)
    }
}

@Suite("Sync: sets that pool every device's")
struct UnionMergeTests {
    @Test("Two devices' clears pool rather than overwrite")
    func clearsPool() {
        let cloud = MemoryCloud()
        var now: TimeInterval = 10
        let defaults = scratchDefaults()
        let engine = SyncEngine(defaults: defaults, cloud: cloud, now: { now }) { _ in }
        engine.start(syncing: [["progress.cleared": .union]])

        engine.insert(["garden-1", "garden-2"], intoSetForKey: "progress.cleared")
        now = 20
        engine.simulateRemoteInsert(["garden-3"], intoSetForKey: "progress.cleared")

        #expect(defaults.stringArray(forKey: "progress.cleared") == ["garden-1", "garden-2", "garden-3"])
    }

    @Test("A set announces only the keys whose contents changed")
    func announcesNewItems() {
        let cloud = MemoryCloud()
        var changed: [String] = []
        let engine = SyncEngine(defaults: scratchDefaults(), cloud: cloud, now: { 1 }) { changed += $0 }
        engine.start(syncing: [["progress.cleared": .union]])
        engine.insert(["garden-1"], intoSetForKey: "progress.cleared")
        changed = []

        engine.simulateRemoteInsert(["garden-1"], intoSetForKey: "progress.cleared")
        #expect(changed.isEmpty)

        engine.simulateRemoteInsert(["garden-2"], intoSetForKey: "progress.cleared")
        #expect(changed == ["progress.cleared"])
    }

    @Test("A reset empties the set and drops what another device added before it")
    func resetWins() {
        let cloud = MemoryCloud()
        var now: TimeInterval = 10
        let defaults = scratchDefaults()
        let engine = SyncEngine(defaults: defaults, cloud: cloud, now: { now }) { _ in }
        engine.start(syncing: [["progress.cleared": .union]])
        engine.insert(["garden-1", "garden-2"], intoSetForKey: "progress.cleared")

        now = 20
        engine.resetSet(forKey: "progress.cleared")
        #expect(defaults.stringArray(forKey: "progress.cleared") == [])

        // An item added before the reset does not come back.
        var stale = SyncEngine.SetRecord()
        stale.items = ["garden-1": 15]
        cloud.set(stale.dictionary, forKey: "progress.cleared")
        now = 30
        engine.synchronize()
        #expect(defaults.stringArray(forKey: "progress.cleared") == [])
    }

    @Test("An item added after a reset comes back")
    func afterResetReturns() {
        let cloud = MemoryCloud()
        var now: TimeInterval = 10
        let defaults = scratchDefaults()
        let engine = SyncEngine(defaults: defaults, cloud: cloud, now: { now }) { _ in }
        engine.start(syncing: [["progress.cleared": .union]])
        engine.insert(["garden-1"], intoSetForKey: "progress.cleared")
        now = 20
        engine.resetSet(forKey: "progress.cleared")

        now = 30
        engine.simulateRemoteInsert(["garden-9"], intoSetForKey: "progress.cleared")
        #expect(defaults.stringArray(forKey: "progress.cleared") == ["garden-9"])
    }

    @Test("Each item keeps the earliest time it was added anywhere")
    func earliestTimeWins() {
        let cloud = MemoryCloud()
        var now: TimeInterval = 50
        let defaults = scratchDefaults()
        let engine = SyncEngine(defaults: defaults, cloud: cloud, now: { now }) { _ in }
        engine.start(syncing: [["gameCenter.moments": .union]])
        engine.insert(["firstTrade"], intoSetForKey: "gameCenter.moments")

        var earlier = SyncEngine.SetRecord()
        earlier.items = ["firstTrade": 5]
        cloud.set(earlier.dictionary, forKey: "gameCenter.moments")
        now = 60
        engine.synchronize()

        #expect(engine.addedTimes(inSetForKey: "gameCenter.moments")["firstTrade"] == 5)
    }

    @Test("Items listed before syncing count as added before any reset")
    func legacyItemsDropOnReset() {
        let defaults = scratchDefaults()
        defaults.set(["garden-1", "garden-2"], forKey: "progress.cleared")
        var now: TimeInterval = 100
        let engine = SyncEngine(defaults: defaults, cloud: MemoryCloud(), now: { now }) { _ in }
        engine.start(syncing: [["progress.cleared": .union]])

        #expect(engine.addedTimes(inSetForKey: "progress.cleared").count == 2)
        now = 200
        engine.resetSet(forKey: "progress.cleared")
        #expect(defaults.stringArray(forKey: "progress.cleared") == [])
    }
}

@Suite("Sync: two devices through one cloud")
struct TwoDeviceTests {
    @Test("A clear on one device reaches the other")
    func clearsTravel() {
        var now: TimeInterval = 10
        let clock = { now }
        let phoneCloud = MemoryCloud()
        let padCloud = MemoryCloud()
        let phoneDefaults = scratchDefaults()
        let padDefaults = scratchDefaults()
        var padChanged: [String] = []
        let phone = SyncEngine(defaults: phoneDefaults, cloud: phoneCloud, now: clock) { _ in }
        let pad = SyncEngine(defaults: padDefaults, cloud: padCloud, now: clock) { padChanged += $0 }
        phone.start(syncing: [["progress.cleared": .union]])
        pad.start(syncing: [["progress.cleared": .union]])

        phone.insert(["reef-4"], intoSetForKey: "progress.cleared")
        now = 20
        pad.insert(["sky-2"], intoSetForKey: "progress.cleared")

        // The service hands each device the other's bytes.
        now = 30
        phoneCloud.deliver(to: padCloud)
        padCloud.deliver(to: phoneCloud)
        phone.synchronize()

        #expect(phoneDefaults.stringArray(forKey: "progress.cleared") == ["reef-4", "sky-2"])
        #expect(padDefaults.stringArray(forKey: "progress.cleared") == ["reef-4", "sky-2"])
        #expect(padChanged == ["progress.cleared"])
    }

    @Test("Merging twice changes nothing the second time")
    func idempotent() {
        var now: TimeInterval = 10
        let cloud = MemoryCloud()
        let defaults = scratchDefaults()
        var changes = 0
        let engine = SyncEngine(defaults: defaults, cloud: cloud, now: { now }) { _ in changes += 1 }
        engine.start(syncing: [["progress.cleared": .union, "settings.musicEnabled": .latest]])
        engine.insert(["garden-1"], intoSetForKey: "progress.cleared")
        engine.set(false, forKey: "settings.musicEnabled")
        changes = 0

        now = 20
        engine.synchronize()
        engine.synchronize()

        #expect(changes == 0)
        #expect(defaults.stringArray(forKey: "progress.cleared") == ["garden-1"])
        #expect(defaults.object(forKey: "settings.musicEnabled") as? Bool == false)
    }
}
