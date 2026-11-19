#if SPRITEKIT_SHIM
import Foundation

/// Where `Bundle.main.url(forResource:withExtension:)` finds a file on
/// Android.
///
/// A game asks the main bundle for its resources (data files, images that
/// aren't in the asset catalog, music). On Apple those sit in the app
/// bundle. On Android there is
/// no app bundle: an asset lives inside the APK, which is a zip, so it has
/// no path on disk and `Data(contentsOf:)` cannot read it. corelibs
/// Foundation's `Bundle.main` looks beside the executable instead, which for
/// an SDL app is the system's `app_process`, so it finds nothing.
///
/// The game's sources compile unchanged, so the call has to keep working as
/// written. It does, through an overload: Foundation's takes `String?` for
/// both arguments and every call site in the game passes a plain `String`,
/// so this one — which takes `String` — needs no optional promotion and is
/// the better match. Swift picks it. (`BundleResourcesTests` is there to
/// catch it if that ever stops being true; it would fail loudly rather than
/// quietly reading the wrong file.)
///
/// `provider` is installed by the app once, at start. With none installed,
/// or when it answers nil, the call falls through to Foundation's own,
/// so the shim behaves exactly as before on the host.
public enum BundleResources {
    /// Answers with a readable `file:` URL for a resource, or nil if it has
    /// none. Android's materialises the file out of the APK the first time
    /// it is asked for it.
    public nonisolated(unsafe) static var provider: ((_ name: String, _ extension: String) -> URL?)?

    public static func url(forResource name: String, withExtension ext: String) -> URL? {
        provider?(name, ext)
    }

    /// "star.png" as ("star", "png"); a name with no extension as itself
    /// and "".
    static func splitExtension(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// Answers with a readable folder for a resource that is one: a
    /// language's `.lproj`, which a game's localization opens with
    /// `Bundle(path:)`.
    public nonisolated(unsafe) static var folderProvider: ((_ name: String, _ extension: String) -> String?)?
}

public extension Bundle {
    /// Resolves through `BundleResources` first, then as Foundation would.
    func url(forResource name: String, withExtension ext: String) -> URL? {
        if let url = BundleResources.url(forResource: name, withExtension: ext) { return url }
        // Spelled with optionals so this picks Foundation's own overload
        // rather than calling itself.
        let name: String? = name, ext: String? = ext
        return url(forResource: name, withExtension: ext)
    }

    /// The same with the extension left nil, as Apple takes it: the name
    /// carries its extension ("star.png"), or has none. Without this a nil
    /// extension picked Foundation's overload, which finds nothing on
    /// Android.
    func url(forResource name: String, withExtension ext: String?) -> URL? {
        if let ext, !ext.isEmpty { return url(forResource: name, withExtension: ext) }
        let (base, split) = BundleResources.splitExtension(name)
        if let url = BundleResources.url(forResource: base, withExtension: split) { return url }
        let name: String? = name, ext: String? = nil
        return url(forResource: name, withExtension: ext)
    }

    /// The same for `path(forResource:ofType:)`, which a game's localization
    /// asks for a language's `.lproj` folder.
    func path(forResource name: String, ofType ext: String) -> String? {
        if let path = BundleResources.folderProvider?(name, ext) { return path }
        if let url = BundleResources.url(forResource: name, withExtension: ext) { return url.path }
        let name: String? = name, ext: String? = ext
        return path(forResource: name, ofType: ext)
    }
}

public extension Bundle {
    /// `Bundle.preferredLocalizations(from:forPreferences:)`, as Apple's
    /// answers it: the first preference that any of `localizations` serves,
    /// matched exactly, then by language and script, then by language alone
    /// (`zh-TW` takes `zh-Hant`, `pt` takes `pt-PT`, `en-US` takes `en`).
    /// corelibs Foundation's answers otherwise, so a game picked a language
    /// the device never asked for. A game passes a plain array, so this
    /// overload is the one it calls; Foundation's takes an optional.
    class func preferredLocalizations(from localizations: [String], forPreferences preferences: [String]) -> [String] {
        LocalizationMatch.best(of: localizations, for: preferences).map { [$0] } ?? []
    }
}

/// The matching `preferredLocalizations` does, apart so the tests can check
/// it against Apple's on the Mac.
public enum LocalizationMatch {
    public static func best(of localizations: [String], for preferences: [String]) -> String? {
        let available = localizations.map { (code: $0, tag: Tag($0)) }
        for preference in preferences {
            let wanted = Tag(preference)
            if let exact = available.first(where: { $0.tag == wanted }) { return exact.code }
            if let script = available.first(where: { $0.tag.language == wanted.language && $0.tag.script != nil && $0.tag.script == wanted.script && $0.tag.region == nil }) { return script.code }
            if let region = available.first(where: { $0.tag.language == wanted.language && $0.tag.region != nil && $0.tag.region == wanted.region }) { return region.code }
            if let plain = available.first(where: { $0.tag.language == wanted.language && $0.tag.script == nil && $0.tag.region == nil }) { return plain.code }
            if let any = available.first(where: { $0.tag.language == wanted.language && ($0.tag.script == nil || $0.tag.script == wanted.script) }) { return any.code }
        }
        return nil
    }

    /// A language tag's parts, with Chinese's region standing for its script.
    struct Tag: Equatable {
        var language: String
        var script: String?
        var region: String?

        init(_ code: String) {
            let parts = code.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            language = parts.first?.lowercased() ?? ""
            for part in parts.dropFirst() {
                if part.count == 4 { script = part.capitalized } else if part.count == 2 || part.count == 3 { region = part.uppercased() }
            }
            if language == "zh", script == nil {
                switch region {
                case "TW", "HK", "MO": script = "Hant"
                case "CN", "SG", nil: script = "Hans"
                default: break
                }
            }
        }
    }
}
#endif
