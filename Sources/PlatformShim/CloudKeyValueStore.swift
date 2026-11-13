import Foundation

/// The small part of `NSUbiquitousKeyValueStore` that `ICloudSyncManager`
/// actually uses: a dictionary per key, a nudge to fetch, and news that
/// another device changed something.
///
/// ## Why this shape, and how Play Saved Games fits it
///
/// Android's answer to iCloud's key-value store is **Play Games Services
/// Saved Games** (Snapshots). It is not a key-value store: a snapshot is one
/// named blob, opened with a conflict callback when two devices wrote
/// without seeing each other.
///
/// That is a worse API in general and an irrelevant difference here, because
/// of how `ICloudSyncManager` merges. Every record it writes is either a
/// value with the time it changed, or a set of items each with the time it
/// was added plus the time the set was last reset. Merging two of those is
/// commutative and idempotent — latest wins, unions pool, resets drop what
/// came before them — so **there is no conflict to resolve**: a Saved Games
/// conflict callback can merge both sides with the same `reconcile` pass
/// that runs here and never has to ask the player which device was right.
///
/// So one snapshot holding `[key: record]` as JSON gives this protocol
/// exactly, and that is the shape the Android implementation should take
/// when it lands:
///
///   - `dictionary(forKey:)` reads the key out of the decoded snapshot;
///   - `set(_:forKey:)` writes it back and marks the snapshot dirty;
///   - `synchronize()` commits the snapshot (`SnapshotsClient.commitAndClose`);
///   - `externalChanges` fires after an open that brought another device's
///     bytes in.
///
/// It is **not** implemented yet, and nothing here pretends otherwise:
/// `LocalOnlyCloud` is what the port runs on, which means saved data is kept
/// on the device and does not follow the player to another one.
public protocol CloudKeyValueStore: AnyObject {
    func dictionary(forKey key: String) -> [String: Any]?
    func set(_ dictionary: [String: Any], forKey key: String)
    /// Asks the service for news. Returns whether anything may have changed.
    @discardableResult func synchronize() -> Bool
    /// Called when another device's changes arrive, on the main thread.
    var externalChanges: (() -> Void)? { get set }
}

/// No cloud at all: every read is empty and every write goes nowhere, so the
/// merge engine above degrades to "this device's values, kept locally".
///
/// This is what the Android build uses today. It is the same path the Apple
/// build takes under `-ICloudOff`, which is why the semantics the game
/// depends on — latest wins, sets pool, a reset empties — are not a separate
/// code path that could drift: they are the merge engine running with
/// nothing on the other side.
public final class LocalOnlyCloud: CloudKeyValueStore {
    public var externalChanges: (() -> Void)?

    public init() {}

    public func dictionary(forKey key: String) -> [String: Any]? { nil }
    public func set(_ dictionary: [String: Any], forKey key: String) {}
    @discardableResult public func synchronize() -> Bool { false }
}

/// A cloud in memory, so the merge can be tested with two devices.
public final class MemoryCloud: CloudKeyValueStore {
    public var externalChanges: (() -> Void)?
    private var contents: [String: [String: Any]] = [:]

    public init() {}

    public func dictionary(forKey key: String) -> [String: Any]? { contents[key] }

    public func set(_ dictionary: [String: Any], forKey key: String) {
        contents[key] = dictionary
    }

    @discardableResult public func synchronize() -> Bool { true }

    /// Hands everything this cloud holds to another device's copy, the way
    /// the service would, and tells it the news arrived.
    public func deliver(to other: MemoryCloud) {
        for (key, record) in contents { other.contents[key] = record }
        other.externalChanges?()
    }
}
