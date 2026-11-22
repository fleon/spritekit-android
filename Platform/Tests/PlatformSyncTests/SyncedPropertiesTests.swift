import Foundation
import Macros
import Testing
@testable import PlatformSync

/// A scratch suite for `@Stored`'s `defaults:`.
nonisolated(unsafe) private let storedSuite = UserDefaults(suiteName: "SyncedPropertiesTests.stored")!

/// An owner as a game's rules keep one: `nonisolated`, in a module whose
/// code is main-actor isolated unless it says otherwise.
@SyncedKeys
nonisolated private enum SampleProgress {
    enum Key {
        static let cleared = "sample.cleared"
        @SyncedKey(merge: .union) static let pool = "sample.pool"
        @SyncedKey static let suspended = "sample.suspended"
        static let local = "sample.local"
    }

    @Synced("sample.lastWorld") static var lastWorld: Int
    @Synced("sample.lastPlayed") static var lastPlayed: Int?
    @Synced("sample.volume", default: 0.5) static var volume: Double
    @Synced("sample.name", default: "none") static var name: String
    @Synced("sample.seen", merge: .union) static var seen: Set<String>
    @Synced(Key.cleared, merge: .union) static var clearedIDs: [String]

    @Stored(Key.local, default: true, defaults: storedSuite) static var flag: Bool
    @Stored("sample.tags", defaults: storedSuite) static var tags: [String]
    @Stored("sample.picked", defaults: storedSuite) static var picked: Set<String>
    @Stored("sample.ratio", defaults: storedSuite) static var ratio: Double?
    @Stored("sample.levels", default: [1], defaults: storedSuite) static var levels: [Int]
}

/// An owner left main-actor isolated, with an instance property.
@SyncedKeys
private final class SampleSettings {
    @Synced("sample.music", default: true) static var music: Bool
    @Synced("sample.mode") var mode: String?
}

/// Serialized with the shared cloud's tests, as both use the shared manager.
extension SharedCloudTests {
    @Test("@Synced reads and saves through the shared manager, and @SyncedKeys lists every synced key")
    func syncedProperties() {
        let suite = UserDefaults(suiteName: "SyncedPropertiesTests.synced")!
        suite.removePersistentDomain(forName: "SyncedPropertiesTests.synced")
        let previous = ICloudSyncManager.configuration
        ICloudSyncManager.cloud = MemoryCloud()
        ICloudSyncManager.configuration = .init(defaults: suite)
        defer { ICloudSyncManager.configuration = previous }
        ICloudSyncManager.shared.start(syncing: [SampleProgress.syncedKeys, SampleSettings.syncedKeys], adoptingLaunchArguments: false)

        #expect(SampleProgress.syncedKeys == [
            "sample.lastWorld": .latest,
            "sample.lastPlayed": .latest,
            "sample.volume": .latest,
            "sample.name": .latest,
            "sample.seen": .union,
            "sample.cleared": .union,
            "sample.pool": .union,
            "sample.suspended": .latest,
        ])
        #expect(SampleSettings.syncedKeys == ["sample.music": .latest, "sample.mode": .latest])

        #expect(SampleProgress.lastWorld == 0)
        #expect(SampleProgress.lastPlayed == nil)
        #expect(SampleProgress.volume == 0.5)
        #expect(SampleProgress.name == "none")
        #expect(SampleSettings.music)

        SampleProgress.lastWorld = 3
        SampleProgress.lastPlayed = 2
        SampleProgress.volume = 0
        SampleProgress.name = "sample"
        SampleSettings.music = false
        #expect(suite.integer(forKey: "sample.lastWorld") == 3)
        #expect(SampleProgress.lastWorld == 3)
        #expect(SampleProgress.lastPlayed == 2)
        #expect(SampleProgress.volume == 0)
        #expect(SampleProgress.name == "sample")
        #expect(!SampleSettings.music)
        // Saved through the manager: each change keeps its time beside it.
        #expect(suite.object(forKey: "sync.sample.lastWorld") != nil)

        SampleProgress.lastPlayed = nil
        #expect(suite.object(forKey: "sample.lastPlayed") == nil)
        #expect(SampleProgress.lastPlayed == nil)

        let settings = SampleSettings()
        settings.mode = "dark"
        #expect(settings.mode == "dark")

        ICloudSyncManager.shared.insert(["b", "a"], intoSetForKey: "sample.seen")
        ICloudSyncManager.shared.insert(["one"], intoSetForKey: "sample.cleared")
        #expect(SampleProgress.seen == ["a", "b"])
        #expect(SampleProgress.clearedIDs == ["one"])
    }

    @Test("@Stored reads and saves its suite")
    func storedProperties() {
        storedSuite.removePersistentDomain(forName: "SyncedPropertiesTests.stored")
        #expect(SampleProgress.flag)
        #expect(SampleProgress.tags.isEmpty)
        #expect(SampleProgress.picked.isEmpty)
        #expect(SampleProgress.ratio == nil)
        #expect(SampleProgress.levels == [1])

        SampleProgress.flag = false
        SampleProgress.tags = ["x", "y"]
        SampleProgress.picked = ["q", "p"]
        SampleProgress.ratio = 0.25
        SampleProgress.levels = [4, 5]
        #expect(!storedSuite.bool(forKey: "sample.local"))
        #expect(!SampleProgress.flag)
        #expect(SampleProgress.tags == ["x", "y"])
        #expect(storedSuite.stringArray(forKey: "sample.picked") == ["p", "q"])
        #expect(SampleProgress.picked == ["p", "q"])
        #expect(SampleProgress.ratio == 0.25)
        #expect(SampleProgress.levels == [4, 5])

        SampleProgress.ratio = nil
        #expect(storedSuite.object(forKey: "sample.ratio") == nil)
        storedSuite.removePersistentDomain(forName: "SyncedPropertiesTests.stored")
    }
}
