import Foundation

/// A merge for a game's synced saved data, as a game syncing through
/// iCloud's key-value store does it, here so it can be tested on the host
/// and so a game's Android sync code is a wrapper rather than a rewrite.
///
/// User defaults stay the store on this device — they work signed out and
/// offline, and they work on Android through corelibs Foundation. What a
/// cloud adds is a second copy to reconcile with. The rules, unchanged from
/// the Apple build:
///
///   - `.latest`: a value is kept with the time it changed. The newer of the
///     two wins; a tie with equal values is left alone.
///   - `.union`: a set is kept as its items, each with the time it was first
///     added anywhere, and the time the set was last reset. The two pool,
///     each item keeping the earlier time, and anything added before the
///     later reset drops out.
///
/// Both are commutative and idempotent, which is what lets this run against
/// a store that can only hand back a whole blob (see `CloudKeyValueStore`).
public final class SyncEngine: @unchecked Sendable {
    /// How a key merges with its copies on the player's other devices.
    public enum Merge: Sendable {
        case latest
        case union
    }

    /// A key's copy in the cloud: its value (none once removed) and when it
    /// changed, or a set's items with when each was added, and when the set
    /// was last reset.
    public enum Record {
        public static let value = "value"
        public static let modifiedAt = "modifiedAt"
        public static let items = "items"
        public static let resetAt = "resetAt"
    }

    public struct SetRecord: Equatable {
        public var items: [String: TimeInterval] = [:]
        public var resetAt: TimeInterval = 0

        public init(items: [String: TimeInterval] = [:], resetAt: TimeInterval = 0) {
            self.items = items
            self.resetAt = resetAt
        }
    }

    /// Where the time a synced key last changed is kept beside it: the
    /// key with a prefix and a suffix (a set keeps its whole record there).
    /// `sync.<key>` unless a game kept its times elsewhere before.
    public struct Stamps: Equatable, Sendable {
        public var prefix: String
        public var suffix: String

        public init(prefix: String = "", suffix: String = "") {
            self.prefix = prefix
            self.suffix = suffix
        }

        public static let standard = Stamps(prefix: "sync.")

        public func key(for key: String) -> String {
            prefix + key + suffix
        }

        /// The synced key a stamp's key belongs to, or nil for any other key.
        public func syncedKey(forStamp key: String) -> String? {
            guard key.hasPrefix(prefix), key.hasSuffix(suffix), key.count > prefix.count + suffix.count else { return nil }
            return String(key.dropFirst(prefix.count).dropLast(suffix.count))
        }
    }

    private let defaults: UserDefaults
    private let cloud: CloudKeyValueStore
    private let stamps: Stamps
    /// Where an older build kept its times, read alongside (the later of
    /// the two counts) and never written.
    private let legacyStamps: Stamps?
    private var syncedKeys: [String: Merge] = [:]
    /// Every key starting with one of these syncs too, as it merges.
    private var syncedPrefixes: [String: Merge] = [:]
    /// Called with the keys whose values here changed because another device
    /// had changed them.
    private let updated: ([String]) -> Void
    /// The clock, so tests can place changes in time.
    private let now: () -> TimeInterval

    public init(
        defaults: UserDefaults = .standard,
        cloud: CloudKeyValueStore = LocalOnlyCloud(),
        stamps: Stamps = .standard,
        legacyStamps: Stamps? = nil,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        updated: @escaping ([String]) -> Void
    ) {
        self.defaults = defaults
        self.cloud = cloud
        self.stamps = stamps
        self.legacyStamps = legacyStamps
        self.now = now
        self.updated = updated
    }

    /// Syncs every owner's keys, and every key starting with one of
    /// `prefixes` (for keys made as play goes on, one a level, say): merges
    /// them with the cloud now, and again whenever it brings changes.
    public func start(syncing keys: [[String: Merge]], prefixes: [String: Merge] = [:]) {
        syncedKeys = keys.reduce(into: [:]) { $0.merge($1) { first, _ in first } }
        syncedPrefixes = prefixes
        cloud.externalChanges = { [weak self] in self?.merge() }
        synchronize()
    }

    /// How `key` merges, if it syncs.
    public func merge(for key: String) -> Merge? {
        if let merge = syncedKeys[key] { return merge }
        guard !isStamp(key) else { return nil }
        return syncedPrefixes.first { key.hasPrefix($0.key) }?.value
    }

    /// Every key that syncs: those named, and those here or in the cloud
    /// under a synced prefix.
    public var allSyncedKeys: [String: Merge] {
        var keys = syncedKeys
        guard !syncedPrefixes.isEmpty else { return keys }
        let found = Set(defaults.dictionaryRepresentation().keys).union(cloud.keys)
        for key in found where keys[key] == nil {
            if let merge = merge(for: key) { keys[key] = merge }
        }
        return keys
    }

    private func isStamp(_ key: String) -> Bool {
        stamps.syncedKey(forStamp: key) != nil || legacyStamps?.syncedKey(forStamp: key) != nil
    }

    /// Asks the cloud for news (at launch and back in the foreground) and
    /// merges what it already has.
    public func synchronize() {
        cloud.synchronize()
        merge()
    }

    /// Saves `value` (nil removes it) for a key that keeps the latest change.
    public func set(_ value: Any?, forKey key: String) {
        guard !Self.isSame(value, defaults.object(forKey: key)) else { return }
        let stamp = now()
        saveLocally(value, forKey: key, modifiedAt: stamp)
        cloud.set(Self.record(value, modifiedAt: stamp), forKey: key)
    }

    /// Adds `items` to a set that pools every device's.
    public func insert(_ items: some Sequence<String>, intoSetForKey key: String) {
        var record = savedSet(key)
        let added = Set(items).subtracting(record.items.keys)
        guard !added.isEmpty else { return }
        let stamp = now()
        for item in added {
            record.items[item] = stamp
        }
        saveSet(record, forKey: key)
        merge([key: .union])
    }

    /// When each item of a pooled set was added (on whichever device first did).
    public func addedTimes(inSetForKey key: String) -> [String: TimeInterval] {
        savedSet(key).items
    }

    /// Empties a set here and, as they next merge, on the player's other devices.
    public func resetSet(forKey key: String) {
        let record = SetRecord(resetAt: now())
        saveSet(record, forKey: key)
        cloud.set(record.dictionary, forKey: key)
    }

    /// Pretends another device added `items` to a set and the cloud just
    /// brought them here (for a debug argument that simulates it).
    public func simulateRemoteInsert(_ items: some Sequence<String>, intoSetForKey key: String) {
        var record = SetRecord(cloud.dictionary(forKey: key))
        let stamp = now()
        for item in Set(items).subtracting(record.items.keys) {
            record.items[item] = stamp
        }
        cloud.set(record.dictionary, forKey: key)
        merge()
    }

    /// Pretends another device saved `value` for a key that keeps the latest
    /// change and the cloud just brought it here (for a debug argument that
    /// simulates it).
    public func simulateRemoteSet(_ value: Any?, forKey key: String) {
        cloud.set(Self.record(value, modifiedAt: now()), forKey: key)
        merge()
    }

    /// A launch argument (`-settings.musicEnabled "<false/>"`) hides the saved
    /// value for the whole run, so the switches could never change it: take
    /// each synced key passed that way as a change made here instead.
    public func adoptLaunchArguments() {
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let passed = syncedKeys.filter { $0.value == .latest }.keys.compactMap { key in
            arguments.removeValue(forKey: key).map { (key, Self.launchValue($0)) }
        }
        guard !passed.isEmpty else { return }
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        for (key, value) in passed {
            set(value, forKey: key)
        }
    }

    private static func launchValue(_ value: Any) -> Any {
        switch (value as? String)?.lowercased() {
        case "yes", "true": true
        case "no", "false": false
        default: value
        }
    }

    /// Merges `keys` (every synced key by default) with their copies in the
    /// cloud, then announces what changed here.
    private func merge(_ keys: [String: Merge]? = nil) {
        var changed: [String] = []
        for (key, kind) in keys ?? allSyncedKeys {
            if reconcile(key, as: kind) { changed.append(key) }
        }
        guard !changed.isEmpty else { return }
        updated(changed)
    }

    /// Brings `key` here and in the cloud into step. Returns whether the
    /// value here changed.
    private func reconcile(_ key: String, as merge: Merge) -> Bool {
        switch merge {
        case .latest: return reconcileLatest(key)
        case .union: return reconcileSet(key)
        }
    }

    private func reconcileLatest(_ key: String) -> Bool {
        let local = defaults.object(forKey: key)
        let modifiedAt = localModifiedAt(key)
        let record = cloud.dictionary(forKey: key)
        let remote = record?[Record.value]
        let remoteModifiedAt = record?[Record.modifiedAt] as? TimeInterval ?? 0
        if record != nil {
            if remoteModifiedAt > modifiedAt {
                // Changed since on another device, or never saved through here.
                saveLocally(remote, forKey: key, modifiedAt: remoteModifiedAt)
                return !Self.isSame(local, remote)
            }
            if remoteModifiedAt == modifiedAt, Self.isSame(local, remote) { return false }
        } else if local == nil, modifiedAt == 0 {
            return false
        }
        // Newer here, not in the cloud yet, or changed here without a new
        // stamp (a `defaults write` before a test run): this device wins.
        let stamp = modifiedAt > remoteModifiedAt ? modifiedAt : now()
        defaults.set(stamp, forKey: stamps.key(for: key))
        cloud.set(Self.record(local, modifiedAt: stamp), forKey: key)
        return false
    }

    private func reconcileSet(_ key: String) -> Bool {
        let local = savedSet(key)
        let remote = SetRecord(cloud.dictionary(forKey: key))
        let resetAt = max(local.resetAt, remote.resetAt)
        let merged = SetRecord(
            items: local.items.merging(remote.items, uniquingKeysWith: min).filter { $0.value >= resetAt },
            resetAt: resetAt
        )
        if merged != local { saveSet(merged, forKey: key) }
        if merged != remote { cloud.set(merged.dictionary, forKey: key) }
        return Set(merged.items.keys) != Set(local.items.keys)
    }

    /// The set saved here. Its list says what's in it: items listed without
    /// coming through here (from before syncing) count as added before any reset.
    private func savedSet(_ key: String) -> SetRecord {
        let listed = defaults.stringArray(forKey: key) ?? []
        var record = SetRecord(defaults.dictionary(forKey: stamps.key(for: key)))
        record.items = Dictionary(listed.map { ($0, record.items[$0] ?? 0) }, uniquingKeysWith: min)
        return record
    }

    private func saveSet(_ record: SetRecord, forKey key: String) {
        defaults.set(record.items.keys.sorted(), forKey: key)
        defaults.set(record.dictionary, forKey: stamps.key(for: key))
    }

    private func saveLocally(_ value: Any?, forKey key: String, modifiedAt: TimeInterval) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        defaults.set(modifiedAt, forKey: stamps.key(for: key))
    }

    private func localModifiedAt(_ key: String) -> TimeInterval {
        let modifiedAt = defaults.double(forKey: stamps.key(for: key))
        guard let legacyStamps else { return modifiedAt }
        return max(modifiedAt, defaults.double(forKey: legacyStamps.key(for: key)))
    }

    private static func record(_ value: Any?, modifiedAt: TimeInterval) -> [String: Any] {
        var record: [String: Any] = [Record.modifiedAt: modifiedAt]
        record[Record.value] = value
        return record
    }

    private static func isSame(_ first: Any?, _ second: Any?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        // corelibs Foundation bridges the value types the game stores
        // (Bool, Int, Double, String, [String]) to NSObject, as Darwin does.
        // `AnyObject.isEqual` is not the fallback it is on Apple: Android
        // builds with no Objective-C interop, so AnyObject has no such
        // member. Nothing a property list can hold reaches the second line.
        if let first = first as? NSObject, let second = second as? NSObject { return first.isEqual(second) }
        return String(describing: first) == String(describing: second)
    }
}

public extension SyncEngine.SetRecord {
    init(_ record: [String: Any]?) {
        items = record?[SyncEngine.Record.items] as? [String: TimeInterval] ?? [:]
        resetAt = record?[SyncEngine.Record.resetAt] as? TimeInterval ?? 0
    }

    var dictionary: [String: Any] {
        [SyncEngine.Record.items: items, SyncEngine.Record.resetAt: resetAt]
    }
}
