import Foundation

/// The small part of `NSUbiquitousKeyValueStore` a game's sync code
/// actually needs: a dictionary per key, a nudge to fetch, and news that
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
/// of how `SyncEngine` merges. Every record it writes is either a
/// value with the time it changed, or a set of items each with the time it
/// was added plus the time the set was last reset. Merging two of those is
/// commutative and idempotent — latest wins, unions pool, resets drop what
/// came before them — so **there is no conflict to resolve**: a Saved Games
/// conflict callback can merge both sides with the same `reconcile` pass
/// that runs here and never has to ask the player which device was right.
///
/// So one snapshot holding `[key: record]` gives this protocol exactly:
/// `PlaySavedGamesCloud` is that store. `LocalOnlyCloud` is what runs without
/// Play Games (a build without its IDs, a game with sync off, a host test), keeping
/// saved data on the device.
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
/// What an Android build without Play Games uses, and the same path an
/// Apple build with iCloud off takes, which is why the semantics a game
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
