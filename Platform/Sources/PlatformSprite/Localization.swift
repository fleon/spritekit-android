import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#endif

/// A language a game ships in, by its `.lproj` folder's name (`"en"`,
/// `"pt-BR"`, `"zh-Hans"`): a game's enum of its languages adopts it.
public protocol LocalizationLanguage: RawRepresentable, CaseIterable, Hashable where RawValue == String {}

/// Which language a game speaks, and its strings in it: the player's pick
/// (a saved setting the game names, synced however the game syncs it), else
/// the device's preferred language among the ones the game ships in, else
/// the development language.
///
/// Strings come from the language's `.lproj` in the bundle, the development
/// language's from `Base.lproj`. On Android, where corelibs' `Bundle` reads
/// no `.strings`, the runtime copies that folder out of the APK
/// (`BundleResources.folderProvider`) and its tables are read with the
/// shim's parser (`LocalizedStrings.table(atPath:)`); a key a table lacks is
/// the fallback on both. Safe on any thread.
public nonisolated final class Localizer<Language: LocalizationLanguage>: @unchecked Sendable {
    /// Posted after the player picks another language.
    public let didChange: Notification.Name
    /// The saved setting holding the player's pick (its raw value).
    public let settingKey: String
    /// The language the strings are written in, kept in `developmentFolder`.
    public let development: Language

    private let developmentFolder: String
    private let contentTable: String
    private let bundle: Bundle
    private let readSetting: () -> String?
    private let saveSetting: (String) -> Void
    private let preferredLanguages: () -> [String]
    private let cached = Locked<(language: Language, strings: Strings)?>(nil)

    /// - Parameters:
    ///   - development: the language the strings are written in.
    ///   - settingKey: the saved setting holding the player's pick.
    ///   - didChange: what's posted when the player picks another.
    ///   - developmentFolder: the `.lproj` the development language's
    ///     strings are in.
    ///   - contentTable: the strings table `content(_:)` reads, keyed by
    ///     the content's own text.
    ///   - read: the saved pick (user defaults' by default).
    ///   - save: saves a pick (into user defaults by default; a game that
    ///     syncs its settings saves through its sync).
    ///   - preferredLanguages: the device's, most preferred first.
    public init(
        development: Language,
        settingKey: String,
        didChange: Notification.Name,
        developmentFolder: String = "Base",
        contentTable: String = "Content",
        bundle: Bundle = .main,
        read: (() -> String?)? = nil,
        save: ((String) -> Void)? = nil,
        preferredLanguages: @escaping () -> [String] = Localizer.devicePreferredLanguages
    ) {
        self.development = development
        self.settingKey = settingKey
        self.didChange = didChange
        self.developmentFolder = developmentFolder
        self.contentTable = contentTable
        self.bundle = bundle
        readSetting = read ?? { UserDefaults.standard.string(forKey: settingKey) }
        saveSetting = save ?? { UserDefaults.standard.set($0, forKey: settingKey) }
        self.preferredLanguages = preferredLanguages
    }

    /// The player's languages: Apple's own list, or on Android the shell's
    /// (`PreferredLanguages`), which corelibs' `Locale` doesn't see there.
    public static func devicePreferredLanguages() -> [String] {
        #if SPRITEKIT_SHIM
        PreferredLanguages.current
        #else
        Locale.preferredLanguages
        #endif
    }

    /// The language the game speaks.
    public var current: Language { load().language }

    /// The device's preferred language, as the game supports it.
    public var deviceLanguage: Language {
        let codes = Language.allCases.map(\.rawValue)
        let best = Bundle.preferredLocalizations(from: codes, forPreferences: preferredLanguages()).first
        return best.flatMap(Language.init(rawValue:)) ?? development
    }

    public var locale: Locale { Locale(identifier: current.rawValue) }

    /// The player picks `language`: saved, and `didChange` posted.
    public func select(_ language: Language) {
        saveSetting(language.rawValue)
        forget()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Saved settings changed elsewhere (another device's pick): what's
    /// built from now on speaks it.
    public func savedDataDidSync(_ keys: Set<String>) {
        if keys.contains(settingKey) { forget() }
    }

    /// Forgets the language and its strings, read again when next asked.
    public func forget() {
        cached.withLock { $0 = nil }
    }

    /// An interface string in the current language, else `fallback`.
    public func string(_ key: String, fallback: String, table: String? = nil) -> String {
        load().strings.string(key, fallback: fallback, table: table)
    }

    /// Content (names, tips) in the current language, keyed by its text in
    /// the development language, which it falls back to.
    public func content(_ text: String) -> String {
        load().strings.string(text, fallback: text, table: contentTable)
    }

    private func load() -> (language: Language, strings: Strings) {
        cached.withLock { cached in
            if let cached { return cached }
            let loaded = read()
            cached = loaded
            return loaded
        }
    }

    private func read() -> (language: Language, strings: Strings) {
        let saved = readSetting().flatMap(Language.init(rawValue:))
        let language = saved ?? deviceLanguage
        let folder = language == development ? developmentFolder : language.rawValue
        #if SPRITEKIT_SHIM
        let path = BundleResources.folderProvider?(folder, "lproj") ?? bundle.path(forResource: folder, ofType: "lproj")
        let strings = Strings(folder: path)
        #else
        let strings = Strings(bundle: bundle.path(forResource: folder, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle)
        #endif
        return (language, strings)
    }
}

/// One language's tables.
private nonisolated struct Strings {
    #if SPRITEKIT_SHIM
    let folder: String?

    /// As Apple's bundle answers: the table's `.stringsdict` format (its
    /// plurals resolved when it's formatted, `StringsDict`), else its
    /// `.strings` string, else `fallback`, else the key.
    func string(_ key: String, fallback: String, table: String?) -> String {
        let name = table.flatMap { $0.isEmpty ? nil : $0 } ?? "Localizable"
        if let folder, let format = LocalizedStrings.pluralFormat(forKey: key, atPath: folder + "/" + name + ".stringsdict") { return format }
        if let folder, let found = LocalizedStrings.table(atPath: folder + "/" + name + ".strings")[key] { return found }
        return fallback.isEmpty ? key : fallback
    }
    #else
    let bundle: Bundle

    func string(_ key: String, fallback: String, table: String?) -> String {
        bundle.localizedString(forKey: key, value: fallback, table: table)
    }
    #endif
}

extension String {
    /// Upper-cased as `localizer`'s current language does it.
    public func uppercased<Language>(in localizer: Localizer<Language>) -> String {
        uppercased(with: localizer.locale)
    }
}
