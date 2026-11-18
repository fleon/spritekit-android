import Foundation

/// Where a device service keeps what it remembers (the haptics switch, the
/// ratings asked for, play time): user defaults unless the game hands in
/// closures, typically reading user defaults and saving through its sync
/// manager so the value follows the player:
///
///     ValueStorage(
///         object: { UserDefaults.standard.object(forKey: $0) },
///         set: { ICloudSyncManager.shared.set($0, forKey: $1) }
///     )
nonisolated public struct ValueStorage {
    public var object: (_ key: String) -> Any?
    /// Saves a value; nil removes it.
    public var set: (_ value: Any?, _ key: String) -> Void
    /// Every key held, for values kept one key a device.
    public var keys: () -> [String]

    public init(
        object: @escaping (_ key: String) -> Any?,
        set: @escaping (_ value: Any?, _ key: String) -> Void,
        keys: @escaping () -> [String] = { Array(UserDefaults.standard.dictionaryRepresentation().keys) }
    ) {
        self.object = object
        self.set = set
        self.keys = keys
    }

    public init(defaults: UserDefaults) {
        self.init(
            object: { defaults.object(forKey: $0) },
            set: { value, key in
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            },
            keys: { Array(defaults.dictionaryRepresentation().keys) }
        )
    }

    public static var standard: ValueStorage { ValueStorage(defaults: .standard) }
}
