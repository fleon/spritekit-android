// The merge, the cloud protocol and its stand-ins come with the facade.
@_exported import PlatformServices
import Foundation

/// Keeps a game's saved data the same on every device the player signs in
/// to: iCloud's key-value store on Apple platforms, Play Games Saved Games
/// on Android (handed in as `cloud` by the Android wiring), or nothing at
/// all, where it stays on the device.
///
/// User defaults stay the store on this device, so a game reads its keys
/// there (or through `object(forKey:)` and its kin) and saves the ones it
/// syncs through here: `set` for a value where the latest change wins,
/// `insert` and `resetSet` for a set every device adds to. Which keys sync
/// is named at `start`: each owner's `syncedKeys`, and prefixes for keys
/// made as play goes on. `SyncEngine` does the merging, at start, on
/// `synchronize()` and whenever the cloud brings another device's changes;
/// what that changed here is posted as `didUpdateLocalData`.
///
/// Everything runs on the main thread, as the cloud's news arrives there.
nonisolated public final class ICloudSyncManager: @unchecked Sendable {
    public typealias Merge = SyncEngine.Merge

    /// Where the manager keeps its keys and their times on this device.
    public struct Configuration {
        public var defaults: UserDefaults
        /// Where each key's time is kept beside it (`sync.<key>`).
        public var stamps: SyncEngine.Stamps
        /// Where an older build kept them, read and never written.
        public var legacyStamps: SyncEngine.Stamps?

        public init(defaults: UserDefaults = .standard, stamps: SyncEngine.Stamps = .standard, legacyStamps: SyncEngine.Stamps? = nil) {
            self.defaults = defaults
            self.stamps = stamps
            self.legacyStamps = legacyStamps
        }
    }

    /// The shared manager, made from `configuration` and `cloud` as first used.
    public static let shared = ICloudSyncManager(configuration: configuration, cloud: cloud)

    /// Posted on the main queue when another device's changes reached the
    /// values saved here, with the keys that changed.
    public static let didUpdateLocalData = Notification.Name("ICloudSyncManager.didUpdateLocalData")
    public static let updatedKeysUserInfoKey = "updatedKeys"

    /// The layout `shared` keeps on this device. Set it, and `cloud`, before
    /// `start`; setting it once `shared` has started merges again with it.
    nonisolated(unsafe) public static var configuration = Configuration() {
        didSet { shared.use(configuration) }
    }

    /// The cloud `shared` syncs through: iCloud's key-value store on Apple
    /// platforms, none on Android until its wiring hands one in. A game
    /// kept off iCloud (a test run on a Mac signed in to a real account)
    /// sets `LocalOnlyCloud()`. Setting it once `shared` has started merges
    /// again with the new one. The platform's own is made only when read
    /// before any is set: merely making iCloud's store starts it syncing,
    /// which a game kept off iCloud must never do.
    public static var cloud: CloudKeyValueStore {
        get {
            if let chosenCloud { return chosenCloud }
            let made = makeDefaultCloud()
            chosenCloud = made
            return made
        }
        set {
            chosenCloud = newValue
            shared.use(newValue)
        }
    }

    nonisolated(unsafe) private static var chosenCloud: CloudKeyValueStore?
    /// Makes the platform's own cloud (a test counts how often).
    nonisolated(unsafe) static var makeDefaultCloud: () -> CloudKeyValueStore = defaultCloud

    private static func defaultCloud() -> CloudKeyValueStore {
        #if SPRITEKIT_SHIM
        LocalOnlyCloud()
        #else
        ICloudKeyValueStore()
        #endif
    }

    private var configuration: Configuration
    private let now: () -> TimeInterval
    private var cloud: CloudKeyValueStore
    private var madeEngine: SyncEngine?
    private var started: (keys: [[String: Merge]], prefixes: [String: Merge])?

    public init(
        configuration: Configuration = Configuration(),
        cloud: CloudKeyValueStore,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.configuration = configuration
        self.cloud = cloud
        self.now = now
    }

    private var defaults: UserDefaults { configuration.defaults }

    private var engine: SyncEngine {
        if let madeEngine { return madeEngine }
        let engine = makeEngine()
        madeEngine = engine
        return engine
    }

    private func makeEngine() -> SyncEngine {
        SyncEngine(
            defaults: configuration.defaults,
            cloud: cloud,
            stamps: configuration.stamps,
            legacyStamps: configuration.legacyStamps,
            now: now
        ) { [weak self] keys in
            let sender = self
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.didUpdateLocalData,
                    object: sender,
                    userInfo: [Self.updatedKeysUserInfoKey: keys]
                )
            }
        }
    }

    private func use(_ cloud: CloudKeyValueStore) {
        self.cloud = cloud
        restart()
    }

    private func use(_ configuration: Configuration) {
        self.configuration = configuration
        restart()
    }

    private func restart() {
        madeEngine = makeEngine()
        if let started { engine.start(syncing: started.keys, prefixes: started.prefixes) }
    }

    /// Syncs every owner's `syncedKeys`, and every key starting with one of
    /// `prefixes`: merges them with the cloud now, and again whenever it
    /// brings changes. With `adoptingLaunchArguments` (a debug build's
    /// default), a synced key passed as a launch argument
    /// (`-settings.musicEnabled "<false/>"`) is saved as a change made here,
    /// so the run's switches can still change it.
    public func start(
        syncing keys: [[String: Merge]] = [],
        prefixes: [String: Merge] = [:],
        adoptingLaunchArguments: Bool = ICloudSyncManager.isDebugBuild
    ) {
        started = (keys, prefixes)
        engine.start(syncing: keys, prefixes: prefixes, adoptingLaunchArguments: adoptingLaunchArguments)
    }

    /// Asks the cloud for news (at launch and back in the foreground) and
    /// merges what it already has.
    public func synchronize() {
        engine.synchronize()
    }

    /// Whether `key` syncs, and how.
    public func merge(for key: String) -> Merge? {
        engine.merge(for: key)
    }

    // MARK: - Values where the latest change wins

    /// Saves `value` (nil removes it) for a key that keeps the latest change.
    public func set(_ value: Any?, forKey key: String) {
        engine.set(value, forKey: key)
    }

    /// Removes a key's value here and, as they next merge, everywhere.
    public func removeObject(forKey key: String) {
        engine.set(nil, forKey: key)
    }

    /// Removes every synced key starting with one of `prefixes`.
    public func removeObjects(withPrefixes prefixes: [String]) {
        for key in dictionaryRepresentation().keys where prefixes.contains(where: key.hasPrefix) {
            removeObject(forKey: key)
        }
    }

    // MARK: - Sets every device adds to

    /// Adds `items` to a set that pools every device's.
    public func insert(_ items: some Sequence<String>, intoSetForKey key: String) {
        engine.insert(items, intoSetForKey: key)
    }

    /// When each item of a pooled set was added (on whichever device first did).
    public func addedTimes(inSetForKey key: String) -> [String: TimeInterval] {
        engine.addedTimes(inSetForKey: key)
    }

    /// Empties a set here and, as they next merge, on the player's other devices.
    public func resetSet(forKey key: String) {
        engine.resetSet(forKey: key)
    }

    // MARK: - Reading

    /// What's saved here for `key`, synced or not.
    public func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func array(forKey key: String) -> [Any]? { defaults.array(forKey: key) }
    public func stringArray(forKey key: String) -> [String]? { defaults.stringArray(forKey: key) }
    public func dictionary(forKey key: String) -> [String: Any]? { defaults.dictionary(forKey: key) }
    public func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    public func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    public func double(forKey key: String) -> Double { defaults.double(forKey: key) }

    /// Every synced key saved here, with its value.
    public func dictionaryRepresentation() -> [String: Any] {
        defaults.dictionaryRepresentation().filter { engine.merge(for: $0.key) != nil }
    }

    // MARK: - Debugging

    /// Pretends another device added `items` to a set and the cloud just
    /// brought them here. With no cloud behind it, nothing arrives.
    public func simulateRemoteInsert(_ items: some Sequence<String>, intoSetForKey key: String) {
        engine.simulateRemoteInsert(items, intoSetForKey: key)
    }

    /// Pretends another device saved `value` and the cloud just brought it here.
    public func simulateRemoteSet(_ value: Any?, forKey key: String) {
        engine.simulateRemoteSet(value, forKey: key)
    }

    public static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
