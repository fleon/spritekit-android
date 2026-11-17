#if SPRITEKIT_SHIM
import Foundation

/// Where `NSUbiquitousKeyValueStore` keeps its copy in the cloud: one
/// dictionary per key, a nudge to fetch, and news that another device
/// changed something. PlatformShim's `CloudKeyValueStore`s (Play Games Saved
/// Games, the local-only one, the in-memory one for tests) all have this
/// shape and adopt it there.
public protocol UbiquitousCloud: AnyObject {
    func dictionary(forKey key: String) -> [String: Any]?
    func set(_ dictionary: [String: Any], forKey key: String)
    @discardableResult func synchronize() -> Bool
    /// Called when another device's changes arrive, on the main thread.
    var externalChanges: (() -> Void)? { get set }
    /// Every key the cloud holds, so values another device set under keys
    /// this one never wrote still arrive.
    var keys: [String] { get }
}

/// One key's value and when it was last set; a removal is a record too, so
/// it reaches other devices and wins over an older value there.
public struct UbiquitousRecord {
    /// A property-list value, or nil for a removal.
    public var value: Any?
    public var time: TimeInterval

    public init(value: Any?, time: TimeInterval) {
        self.value = value
        self.time = time
    }

    /// As user defaults and the cloud keep it, a property list.
    public var dictionary: [String: Any] {
        if let value { return ["value": value, "time": time] }
        return ["removed": true, "time": time]
    }

    public init?(dictionary: [String: Any]) {
        guard let time = (dictionary["time"] as? NSNumber)?.doubleValue ?? dictionary["time"] as? Double else { return nil }
        if dictionary["removed"] as? Bool == true {
            self.init(value: nil, time: time)
        } else if let value = dictionary["value"] {
            self.init(value: value, time: time)
        } else {
            return nil
        }
    }

    /// Whether two records hold the same value, as property lists compare
    /// (so a dictionary that went through the cloud, its keys in another
    /// order, still compares equal).
    func sameValue(as other: UbiquitousRecord) -> Bool {
        switch (value, other.value) {
        case (nil, nil): return true
        case let (a?, b?): return NSArray(object: a).isEqual(NSArray(object: b))
        default: return false
        }
    }

    /// Whether this record wins over `other`: the later one, and for two set
    /// at the same instant the one whose encoding sorts last, so every device
    /// settles on the same value.
    func wins(over other: UbiquitousRecord) -> Bool {
        if time != other.time { return time > other.time }
        if sameValue(as: other) { return false }
        let mine = value.flatMap(Self.encoded).map(Array.init) ?? []
        let theirs = other.value.flatMap(Self.encoded).map(Array.init) ?? []
        return mine.lexicographicallyPrecedes(theirs) == false && mine != theirs
    }

    private static func encoded(_ value: Any) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0)
    }
}

/// iCloud's key-value store, its API name for name; on Android it is
/// `NSUbiquitousKeyValueStore` (a type alias), here so it tests on the Mac.
///
/// The values live on the device in user defaults (which the shell writes
/// to disk), each with when it was set, and go to the cloud the game installs
/// (`cloud`: Play Games Saved Games, through PlatformShim), one key a record
/// under `"ubiquitous." + key`. iCloud resolves two devices' writes to one key
/// by keeping the later, and so does the merge here, key by key; the keys
/// whose value changed on this device are posted as
/// `didChangeExternallyNotification`, as iCloud posts them: the initial-sync
/// reason for the first merge that hears from the cloud (installed with its
/// data there, or the first news after Play signs in), the server-change one
/// after. With no cloud the store is the device's alone, as with iCloud off.
///
/// Safe to read and write from any thread; the cloud is only spoken to on
/// the main thread, where its changes also arrive.
open class UbiquitousKeyValueStore: @unchecked Sendable {
    public static let didChangeExternallyNotification = Notification.Name("NSUbiquitousKeyValueStoreDidChangeExternallyNotification")
    public static let changeReasonKey = "NSUbiquitousKeyValueStoreChangeReasonKey"
    public static let changedKeysKey = "NSUbiquitousKeyValueStoreChangedKeysKey"
    public static let serverChange = 0
    public static let initialSyncChange = 1

    nonisolated(unsafe) private static let shared = UbiquitousKeyValueStore()
    open class var `default`: UbiquitousKeyValueStore { shared }

    /// The defaults key the records are kept under.
    static let defaultsKey = "NSUbiquitousKeyValueStore.records"
    /// The prefix a key's record carries in the cloud.
    static let cloudPrefix = "ubiquitous."

    private let defaults: UserDefaults
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private var records: [String: UbiquitousRecord]
    /// Whether the cloud has been heard from yet, so the next merge is
    /// iCloud's initial sync.
    private var hasSynced = false

    /// Where the values go beyond this device. Installing one merges with it
    /// at once; if it holds nothing yet (Play Games not signed in), the first
    /// news from it is the initial sync.
    public var cloud: UbiquitousCloud? {
        didSet {
            onMain { [self] in
                cloud?.externalChanges = { [weak self] in self?.mergeWithCloud(heardFrom: true) }
                mergeWithCloud(heardFrom: false)
            }
        }
    }

    public init(defaults: UserDefaults = .standard, clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.defaults = defaults
        self.clock = clock
        let saved = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        records = saved.compactMapValues { ($0 as? [String: Any]).flatMap(UbiquitousRecord.init(dictionary:)) }
    }

    // MARK: Reading

    open func object(forKey key: String) -> Any? { locked { records[key]?.value } }
    open func string(forKey key: String) -> String? { object(forKey: key) as? String }
    open func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    open func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    open func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    open func longLong(forKey key: String) -> Int64 { (object(forKey: key) as? NSNumber)?.int64Value ?? 0 }
    open func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    open func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }

    open var dictionaryRepresentation: [String: Any] { locked { records.compactMapValues(\.value) } }

    // MARK: Writing

    /// Only property-list values are kept, as on Apple; anything else is
    /// dropped.
    open func set(_ value: Any?, forKey key: String) {
        guard let value else {
            removeObject(forKey: key)
            return
        }
        guard (try? PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0)) != nil else { return }
        write(value, forKey: key)
    }

    open func set(_ value: String?, forKey key: String) { set(value as Any?, forKey: key) }
    open func set(_ value: Data?, forKey key: String) { set(value as Any?, forKey: key) }
    open func set(_ value: [Any]?, forKey key: String) { set(value as Any?, forKey: key) }
    open func set(_ value: [String: Any]?, forKey key: String) { set(value as Any?, forKey: key) }
    open func set(_ value: Int64, forKey key: String) { write(NSNumber(value: value), forKey: key) }
    open func set(_ value: Double, forKey key: String) { write(NSNumber(value: value), forKey: key) }
    open func set(_ value: Bool, forKey key: String) { write(NSNumber(value: value), forKey: key) }

    open func removeObject(forKey key: String) {
        write(nil, forKey: key)
    }

    /// Saves to the device now and asks the cloud for news. True, as iCloud
    /// answers whenever the values could be saved.
    @discardableResult
    open func synchronize() -> Bool {
        locked { save() }
        onMain { [self] in cloud?.synchronize() }
        return true
    }

    // MARK: -

    private func write(_ value: Any?, forKey key: String) {
        let record = UbiquitousRecord(value: value, time: clock())
        locked {
            records[key] = record
            save()
        }
        onMain { [self] in cloud?.set(record.dictionary, forKey: Self.cloudPrefix + key) }
    }

    /// Under the lock.
    private func save() {
        defaults.set(records.mapValues(\.dictionary), forKey: Self.defaultsKey)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    /// Takes the cloud's newer records, sends back this device's newer ones,
    /// and posts the keys whose value changed here. On the main thread.
    /// `heardFrom` is true when the cloud called with news, which a signed-in
    /// cloud does once it has fetched, data or not.
    private func mergeWithCloud(heardFrom: Bool) {
        guard let cloud else { return }
        var remote: [String: UbiquitousRecord] = [:]
        for cloudKey in cloud.keys where cloudKey.hasPrefix(Self.cloudPrefix) {
            if let dictionary = cloud.dictionary(forKey: cloudKey), let record = UbiquitousRecord(dictionary: dictionary) {
                remote[String(cloudKey.dropFirst(Self.cloudPrefix.count))] = record
            }
        }
        var changed: [String] = []
        var outgoing: [(String, UbiquitousRecord)] = []
        let reason: Int = locked {
            let reason = hasSynced ? Self.serverChange : Self.initialSyncChange
            if heardFrom || !remote.isEmpty { hasSynced = true }
            for key in Set(records.keys).union(remote.keys).sorted() {
                switch (records[key], remote[key]) {
                case let (local?, theirs?) where theirs.wins(over: local):
                    if !theirs.sameValue(as: local) { changed.append(key) }
                    records[key] = theirs
                case let (nil, theirs?):
                    records[key] = theirs
                    if theirs.value != nil { changed.append(key) }
                case let (local?, theirs) where theirs.map({ local.wins(over: $0) }) ?? true:
                    outgoing.append((key, local))
                default:
                    break
                }
            }
            save()
            return reason
        }
        for (key, record) in outgoing {
            cloud.set(record.dictionary, forKey: Self.cloudPrefix + key)
        }
        guard !changed.isEmpty else { return }
        NotificationCenter.default.post(
            name: Self.didChangeExternallyNotification,
            object: self,
            userInfo: [Self.changeReasonKey: reason, Self.changedKeysKey: changed]
        )
    }
}

#if !canImport(Darwin)
public typealias NSUbiquitousKeyValueStore = UbiquitousKeyValueStore

public let NSUbiquitousKeyValueStoreChangeReasonKey = UbiquitousKeyValueStore.changeReasonKey
public let NSUbiquitousKeyValueStoreChangedKeysKey = UbiquitousKeyValueStore.changedKeysKey
public let NSUbiquitousKeyValueStoreServerChange = UbiquitousKeyValueStore.serverChange
public let NSUbiquitousKeyValueStoreInitialSyncChange = UbiquitousKeyValueStore.initialSyncChange
public let NSUbiquitousKeyValueStoreQuotaViolationChange = 2
public let NSUbiquitousKeyValueStoreAccountChange = 3
#endif
#endif
