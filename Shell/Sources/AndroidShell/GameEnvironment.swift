import CAndroidShell
import Foundation
import PlatformShim
import ShellCore

/// What corelibs Foundation reads from the process's environment, set up the
/// way the game expects it on Apple, before anything touches it.
///
/// - **Saved data.** `UserDefaults.standard` is where a game keeps progress,
///   settings and whatever else it saves. corelibs Foundation keeps it in memory
///   only on Android (it finds no app domain to write: the process is
///   `app_process`, with no bundle identifier), so the shell writes the
///   app's values to `defaults.plist` in internal storage — which survives
///   updates and goes with an uninstall, as an iOS app's container does —
///   whenever the game might be ended (`save()`), and reads them back first
///   thing at launch. `HOME` points there too, for anything else that asks.
/// - **The device's language.** A game asks
///   `Locale.preferredLanguages`, which corelibs reads from `AppleLanguages`;
///   it is filled from Android's own list (`SDL_GetPreferredLocales`).
/// - **Launch arguments.** On Apple, `-Key value` pairs reach
///   `UserDefaults`' argument domain, where a game reads them. Here the
///   intent's `args` or `args64` extra carries them (`ShellArguments`), and
///   they are put in that domain the same way (`LaunchArgumentDomain`). An
///   emulator's gain `-Playtest NO` unless they name it (`AndroidDevice`),
///   since a game knows an iOS simulator only at compile time. A build that
///   isn't a beta (as the app's build properties say) gains
///   `-DesignerLevels NO` too (`BetaBuild`).
enum GameEnvironment {
    static func install() {
        if let storage = SDL_GetAndroidInternalStoragePath().map({ String(cString: $0) }) {
            setenv("HOME", storage, 1)
            setenv("XDG_CONFIG_HOME", storage + "/.config", 1)
            setenv("XDG_DATA_HOME", storage + "/.local/share", 1)
            let cache = SDL_GetAndroidCachePath().map { String(cString: $0) } ?? storage
            setenv("TMPDIR", cache + "/tmp", 1)
            // `FileManager`'s caches directory is the app's cache, where a
            // game's debug captures land and
            // `adb exec-out run-as <package> cat cache/…` reaches them.
            setenv("XDG_CACHE_HOME", cache, 1)
            try? FileManager.default.createDirectory(atPath: storage + "/.config", withIntermediateDirectories: true)
            if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] {
                try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            }
        } else {
            Log.error("no internal storage path — nothing the game saves will last")
        }

        loadSavedDefaults()

        // An emulator gains `-Playtest NO` unless told otherwise, as an iOS
        // simulator is known to be one; a build that isn't a beta gains
        // `-DesignerLevels NO` and `-Playtest NO` unless told otherwise.
        Log.info(BetaBuild.current.description)
        let arguments = BetaBuild.current.arguments(AndroidDevice.current.arguments(LaunchArgumentDomain.parse(ShellArguments.values)))
        // `-AppleLanguages "(ja)"` stands in for the device's, as on Apple;
        // set where `Locale.preferredLanguages` reads it whichever domain
        // that is, and never saved, since it's an argument.
        let languages = arguments["AppleLanguages"] as? [String] ?? preferredLanguages()
        if !languages.isEmpty {
            UserDefaults.standard.set(languages, forKey: "AppleLanguages")
            setenv("LANG", languages[0].replacingOccurrences(of: "-", with: "_") + ".UTF-8", 1)
            Log.info("languages: \(languages.joined(separator: ", "))")
        }

        if !arguments.isEmpty {
            Log.info("launch arguments: \(arguments.count) (\(ProcessInfo.processInfo.arguments.count - 1) in ProcessInfo)")
            var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            domain.merge(arguments) { $1 }
            UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        }
    }

    private static var savedDefaultsURL: URL? {
        SDL_GetAndroidInternalStoragePath().map { URL(fileURLWithPath: String(cString: $0)).appendingPathComponent("defaults.plist") }
    }

    /// The values the game saved last time, put back before it reads any.
    private static func loadSavedDefaults() {
        guard let url = savedDefaultsURL, let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        for (key, value) in values { UserDefaults.standard.set(value, forKey: key) }
        Log.info("saved data: \(values.count) values read back")
    }

    /// Writes what the game has saved: everything in user defaults but the
    /// launch arguments (which are this run's alone). Cheap enough to call
    /// every few seconds; written only when something changed.
    static func save() {
        guard let url = savedDefaultsURL else { return }
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let values = UserDefaults.standard.dictionaryRepresentation().filter { arguments[$0.key] == nil }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0),
              data != lastSaved else { return }
        do {
            try data.write(to: url, options: .atomic)
            lastSaved = data
        } catch {
            Log.error("saved data would not write: \(error)")
        }
    }

    private static var lastSaved: Data?

    /// Android's languages, best first, as BCP 47 tags (`pt-BR`, `zh-Hant`).
    private static func preferredLanguages() -> [String] {
        var count: Int32 = 0
        guard let locales = SDL_GetPreferredLocales(&count) else { return [] }
        defer { SDL_free(locales) }
        return (0 ..< Int(count)).compactMap { index -> String? in
            guard let locale = locales[index], let language = locale.pointee.language else { return nil }
            let code = String(cString: language)
            guard let country = locale.pointee.country else { return code }
            return "\(code)-\(String(cString: country))"
        }
    }
}
