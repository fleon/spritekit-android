import Foundation

/// What a game has saved in user defaults, as Apple keeps it on disk: the
/// app's own domain, never the launch arguments.
///
/// Measured on a Mac (macOS 27.2; `SavedDefaultsTests`): the argument domain
/// is an overlay on reads alone. A value set for a key a launch argument
/// also names is saved, though reads return the argument's for the rest of
/// the run; the next launch without the argument reads the saved one.
///
/// Nothing here touches the volatile domains: the shell calls this every
/// few seconds, and lifting the process-wide argument domain meanwhile would
/// hand any other thread reading user defaults the wrong values. Apple's
/// `dictionaryRepresentation()` includes the arguments, so there it reads
/// the persistent domain, which is what reaches disk; corelibs'
/// `dictionaryRepresentation()` leaves the argument domain out (its
/// registered defaults and stored values alone), so on Android it is that.
public enum SavedDefaults {
    /// `persistentDomain` names the domain on Apple (the suite's name; the
    /// app's bundle ID by default). Corelibs needs none.
    public static func stored(in defaults: UserDefaults = .standard, persistentDomain: String? = nil) -> [String: Any] {
        #if canImport(Darwin)
        let name = persistentDomain ?? Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return defaults.persistentDomain(forName: name) ?? [:]
        #else
        return defaults.dictionaryRepresentation()
        #endif
    }

    /// Puts `arguments` in place of the argument domain, on Apple and
    /// corelibs alike. Apple's `setVolatileDomain` replaces the domain and
    /// its `removeVolatileDomain` leaves the argument domain as it is;
    /// corelibs' set merges into the domain and its remove clears it. Remove
    /// then set replaces it on both.
    public static func replaceArguments(in defaults: UserDefaults, with arguments: [String: Any]) {
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}
