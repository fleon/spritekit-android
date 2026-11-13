import Foundation
import PlatformShim

/// `Source/Utils/ICloudSyncManager.swift` on Android.
///
/// The name stays because 15 files call it and the shape the game depends on
/// is the shape it keeps: `set` for a value where the latest change wins,
/// `insert` / `addedTimes` / `resetSet` for a set every device adds to, and
/// a notification naming the keys another device changed. `Progress`,
/// `AudioManager`, `Localization` and `GameCenterManager` all lean on those
/// semantics and none of them changes.
///
/// **What is honestly different: nothing syncs yet.** There is no iCloud on
/// Android and no Play Saved Games here either, so a player's levels cleared
/// stay on the device they cleared them on. That is a gap, not a design —
/// `CloudKeyValueStore` in `PlatformShim` says in detail how Play Games
/// Saved Games fits the shape, and why its conflict callback has nothing to
/// resolve given records that merge commutatively.
///
/// What makes that honest rather than hand-waving is that the merge is not
/// bypassed: `SyncEngine` is the Apple file's reconcile logic, moved so it
/// could be tested, and it runs here against `LocalOnlyCloud`. That is the
/// same path the Apple build takes under `-ICloudOff`. When a cloud arrives
/// it is one object, not a rewrite.
nonisolated final class ICloudSyncManager: @unchecked Sendable {
    /// How a key merges with its copies on other devices.
    enum Merge {
        case latest
        case union
    }

    static let shared = ICloudSyncManager()
    /// Posted on the main queue when another device's changes reached the
    /// values saved here, with the keys that changed.
    static let didUpdateLocalData = Notification.Name("ICloudSyncManager.didUpdateLocalData")
    static let updatedKeysUserInfoKey = "updatedKeys"

    /// The cloud this manager talks to. Swapping this for a Saved Games
    /// store is the whole of what syncing on Android would take.
    static var cloud: CloudKeyValueStore = LocalOnlyCloud()

    private lazy var engine = SyncEngine(cloud: Self.cloud) { keys in
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.didUpdateLocalData,
                object: ICloudSyncManager.shared,
                userInfo: [Self.updatedKeysUserInfoKey: keys]
            )
        }
    }

    private init() {}

    /// Syncs every owner's `syncedKeys`.
    func start(syncing keys: [[String: Merge]]) {
        engine.start(syncing: keys.map { $0.mapValues(\.engineMerge) })
        #if DEBUG
        engine.adoptLaunchArguments()
        #endif
    }

    /// Asks for news (at launch and back in the foreground) and merges what
    /// is already held.
    func synchronize() {
        engine.synchronize()
    }

    /// Saves `value` (nil removes it) for a key that keeps the latest change.
    func set(_ value: Any?, forKey key: String) {
        engine.set(value, forKey: key)
    }

    /// Adds `items` to a set that pools every device's.
    func insert(_ items: some Sequence<String>, intoSetForKey key: String) {
        engine.insert(items, intoSetForKey: key)
    }

    /// When each item of a pooled set was added (on whichever device first did).
    func addedTimes(inSetForKey key: String) -> [String: TimeInterval] {
        engine.addedTimes(inSetForKey: key)
    }

    /// Empties a set here and, as they next merge, on the player's other devices.
    func resetSet(forKey key: String) {
        engine.resetSet(forKey: key)
    }

    #if DEBUG
    /// Pretends another device added `items` to a set (`-SyncedClears`).
    /// With no cloud behind it there is no other device, so this writes
    /// straight into whatever store is installed — which is what makes it a
    /// usable check of the merge even before one is.
    func simulateRemoteInsert(_ items: some Sequence<String>, intoSetForKey key: String) {
        engine.simulateRemoteInsert(items, intoSetForKey: key)
    }

    /// Pretends another device saved `value` (`-SyncedMoves`).
    func simulateRemoteSet(_ value: Any?, forKey key: String) {
        engine.simulateRemoteSet(value, forKey: key)
    }
    #endif
}

private extension ICloudSyncManager.Merge {
    var engineMerge: SyncEngine.Merge {
        switch self {
        case .latest: return .latest
        case .union: return .union
        }
    }
}
