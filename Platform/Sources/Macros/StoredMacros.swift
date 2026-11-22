import Foundation
import PlatformServices

// Saved values as properties: a key, a type and what it reads before
// anything is saved, instead of a getter and a setter written out by hand.
// The property's type picks the reader: `Int`, `Bool` and `Double` read
// through `integer`, `bool` and `double` (so a value saved as another number
// still reads), `String`, `[String]` and `Data` through `string`,
// `stringArray` and `data`, `Set<String>` as a sorted string array, and any
// other type as the object saved, cast. An optional reads nil until saved,
// and saving nil removes the key. Without `default:`, a value reads what the
// typed reader does for a missing key (0, false, "", empty).

/// A property kept in user defaults under `key`.
///
///     @Stored("settings.statusBarVisible", default: true)
///     static var isStatusBarVisible: Bool
///
/// expands to
///
///     static var isStatusBarVisible: Bool {
///         get {
///             UserDefaults.standard.object(forKey: "settings.statusBarVisible") != nil ? UserDefaults.standard.bool(forKey: "settings.statusBarVisible") : true
///         }
///         set {
///             UserDefaults.standard.set(newValue, forKey: "settings.statusBarVisible")
///         }
///     }
///
/// `defaults:` names another suite.
@attached(accessor)
public macro Stored<Value>(_ key: String, default: Value, defaults: UserDefaults = .standard) =
    #externalMacro(module: "MacrosPlugin", type: "StoredMacro")

/// A property kept in user defaults under `key`, reading the typed
/// reader's value (or nil) until saved.
@attached(accessor)
public macro Stored(_ key: String, defaults: UserDefaults = .standard) =
    #externalMacro(module: "MacrosPlugin", type: "StoredMacro")

/// A property kept the same on the player's devices: it reads through
/// `ICloudSyncManager.shared` (user defaults on this device) and saves
/// through its `set(_:forKey:)`.
///
///     @Synced("progress.lastWorld")
///     static var lastWorldIndex: Int
///
/// A `.union` key is a set every device adds to, which only
/// `insert(_:intoSetForKey:)` and `resetSet(forKey:)` change: its property
/// (`[String]` or `Set<String>`) only reads.
///
/// List the owner's synced keys with `@SyncedKeys` on it.
@attached(accessor)
public macro Synced<Value>(_ key: String, merge: SyncEngine.Merge = .latest, default: Value) =
    #externalMacro(module: "MacrosPlugin", type: "SyncedMacro")

/// A synced property reading the typed reader's value (or nil) until saved.
@attached(accessor)
public macro Synced(_ key: String, merge: SyncEngine.Merge = .latest) =
    #externalMacro(module: "MacrosPlugin", type: "SyncedMacro")

/// Marks a key constant as synced, for `@SyncedKeys` to list: a key saved
/// through `ICloudSyncManager`'s other calls (a pooled set, a blob, a key
/// read with logic of its own) rather than a `@Synced` property.
///
///     private enum Key {
///         @SyncedKey(merge: .union) static let cleared = "progress.cleared"
///     }
@attached(peer)
public macro SyncedKey(merge: SyncEngine.Merge = .latest) =
    #externalMacro(module: "MacrosPlugin", type: "SyncedKeyMacro")

/// Adds `static let syncedKeys: [String: ICloudSyncManager.Merge]`, the
/// owner's list for `ICloudSyncManager.start(syncing:)`: every `@Synced`
/// property among its members, and every `@SyncedKey` constant among its
/// members and its nested types' (named from the owner, `Key.cleared`).
/// Keys declared in an extension aren't seen.
@attached(member, names: named(syncedKeys))
public macro SyncedKeys() =
    #externalMacro(module: "MacrosPlugin", type: "SyncedKeysMacro")
