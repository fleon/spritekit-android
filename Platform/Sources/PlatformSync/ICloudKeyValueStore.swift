import Foundation

/// What `ICloudKeyValueStore` keeps its values in: iCloud's key-value store
/// on Apple platforms, or one in memory for a test.
nonisolated public protocol FlatKeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    var dictionaryRepresentation: [String: Any] { get }
    @discardableResult func synchronize() -> Bool
}

/// iCloud's key-value store as a `CloudKeyValueStore`: the cloud
/// `ICloudSyncManager` syncs through on Apple platforms. Another device's
/// changes arrive on the main queue as `externalChanges`.
///
/// `.records` keeps each key as `SyncEngine` writes it, one dictionary (a
/// value and when it changed, or a set's items). `.flat` keeps the layout a
/// game synced in before records: the value under its own key and the time
/// beside it under its stamp's key, so a build moving to the shared manager
/// reads what earlier builds wrote, and they still read what it writes.
nonisolated public final class ICloudKeyValueStore: CloudKeyValueStore, @unchecked Sendable {
    public enum Layout {
        case records
        /// Values under their keys, times under `stamps` (and read under
        /// `legacy` too, the later counting).
        case flat(SyncEngine.Stamps, legacy: SyncEngine.Stamps? = nil)
    }

    public var externalChanges: (() -> Void)?

    private let store: FlatKeyValueStore
    private let layout: Layout
    private var observer: NSObjectProtocol?

    /// Over any store; whoever owns it calls `externalChanges` as news comes.
    public init(store: FlatKeyValueStore, layout: Layout = .records) {
        self.store = store
        self.layout = layout
    }

    #if !SPRITEKIT_SHIM
    public convenience init(_ store: NSUbiquitousKeyValueStore = .default, layout: Layout = .records) {
        self.init(store: store, layout: layout)
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            self?.externalChanges?()
        }
    }
    #endif

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func dictionary(forKey key: String) -> [String: Any]? {
        guard case let .flat(stamps, legacy) = layout else { return store.object(forKey: key) as? [String: Any] }
        let stamp = store.object(forKey: stamps.key(for: key)) as? TimeInterval
        let legacyStamp = legacy.flatMap { store.object(forKey: $0.key(for: key)) as? TimeInterval }
        let value = store.object(forKey: key)
        if stamp != nil || legacyStamp != nil {
            var record: [String: Any] = [SyncEngine.Record.modifiedAt: max(stamp ?? 0, legacyStamp ?? 0)]
            record[SyncEngine.Record.value] = value
            return record
        }
        // A set's record is kept whole.
        if let record = value as? [String: Any], record[SyncEngine.Record.items] != nil { return record }
        // A value with no time: older than anything saved through the
        // manager, newer than nothing.
        return value.map { [SyncEngine.Record.value: $0, SyncEngine.Record.modifiedAt: TimeInterval.leastNonzeroMagnitude] }
    }

    public func set(_ dictionary: [String: Any], forKey key: String) {
        guard case let .flat(stamps, _) = layout, dictionary[SyncEngine.Record.items] == nil,
              let modifiedAt = dictionary[SyncEngine.Record.modifiedAt]
        else {
            store.set(dictionary, forKey: key)
            return
        }
        if let value = dictionary[SyncEngine.Record.value] {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
        store.set(modifiedAt, forKey: stamps.key(for: key))
    }

    @discardableResult
    public func synchronize() -> Bool {
        store.synchronize()
    }

    public var keys: [String] {
        let held = store.dictionaryRepresentation.keys
        guard case let .flat(stamps, legacy) = layout else { return Array(held) }
        let keys = held.map { stamps.syncedKey(forStamp: $0) ?? legacy?.syncedKey(forStamp: $0) ?? $0 }
        return Array(Set(keys))
    }
}

#if !SPRITEKIT_SHIM
extension NSUbiquitousKeyValueStore: FlatKeyValueStore {}
#endif
