#if SPRITEKIT_SHIM
import Foundation
import PlatformServices

/// `.stringsdict` plurals on Android, as Foundation resolves them on Apple
/// (measured on macOS 27.2; `StringsDictTests`).
///
/// A key a `.stringsdict` defines is looked up there before its `.strings`
/// file, as Apple's bundle does, and comes back as its
/// `NSStringLocalizedFormatKey` (`"You found %#@words@."`). Apple's string
/// carries its plural rules with it; here they're registered under the
/// format's text, and `String.localizedStringWithFormat`, `String(format:)`
/// and `String(format:locale:)` resolve a registered format when every
/// argument is an `Int` (`StringsDictFormatting`), which is how a count is
/// passed. Other calls, and formats nothing registered, go to Foundation's.
///
/// Resolving, as Foundation does:
/// - Each `%#@name@` takes the next argument (or `%N$#@name@` the Nth). Its
///   variable's form for that number replaces it, and a plain specifier in
///   the form (`%d`, `%ld`) formats that same argument; a `%#@name@` nested
///   in a form takes the argument after.
/// - The form is the category of the formatting locale's language (CLDR's
///   cardinal rules, `PluralRules`): the locale passed, else the current
///   one, never the string's own language. `zero` wins for 0 in every
///   language when the variable has it; a category it lacks takes `other`.
/// - Numbers are formatted as Foundation formats them for that locale
///   (`localizedStringWithFormat` groups digits by the current locale).
public enum StringsDict {
    /// One variable of a format: the type its value has and its forms by
    /// plural category.
    public struct Variable: Equatable, Sendable {
        public var valueType: String
        public var forms: [String: String]
    }

    /// A `.stringsdict` entry: its format and the variables the format names.
    public struct Entry: Equatable, Sendable {
        public var format: String
        public var variables: [String: Variable]
    }

    /// A `.stringsdict` file's plural entries by key. Entries of another
    /// rule type, or without a format, are left out.
    public static func parse(_ data: Data) -> [String: Entry] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        var entries: [String: Entry] = [:]
        for (key, value) in root {
            guard let dict = value as? [String: Any], let format = dict["NSStringLocalizedFormatKey"] as? String else { continue }
            var variables: [String: Variable] = [:]
            for (name, spec) in dict {
                guard let spec = spec as? [String: Any],
                      spec["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType" else { continue }
                var forms: [String: String] = [:]
                for category in PluralRules.categories {
                    if let form = spec[category] as? String { forms[category] = form }
                }
                variables[name] = Variable(valueType: spec["NSStringFormatValueTypeKey"] as? String ?? "d", forms: forms)
            }
            entries[key] = Entry(format: format, variables: variables)
        }
        return entries
    }

    private static let registered = Locked([String: Entry]())

    /// Remembers `entry` under its format's text, so formatting it resolves
    /// its plurals; returns the format.
    @discardableResult
    public static func register(_ entry: Entry) -> String {
        registered.withLock { $0[entry.format] = entry }
        return entry.format
    }

    /// The entry registered for `format`, if it has a plural variable in it.
    public static func entry(for format: String) -> Entry? {
        guard format.contains("#@") else { return nil }
        return registered.withLock { $0[format] }
    }

    /// Forgets every registered format (tests).
    static func reset() {
        registered.withLock { $0 = [:] }
    }

    /// `format` with `arguments`, its plurals in `pluralLocale`'s categories
    /// and its numbers formatted for `locale` (nil: unlocalized, as
    /// `String(format:)` formats them).
    public static func format(_ entry: Entry, locale: Locale?, pluralLocale: Locale, arguments: [Int]) -> String {
        var next = 0
        return expand(entry.format, entry: entry, own: nil, next: &next, locale: locale,
                      language: PluralRules.Language(pluralLocale), arguments: arguments, depth: 0)
    }

    /// One specifier as Foundation formats it, the rest of the text as is.
    /// `own` is the argument a plain specifier formats inside a variable's
    /// form; at the top level each plain specifier takes the next.
    private static func expand(
        _ text: String, entry: Entry, own: Int?, next: inout Int, locale: Locale?,
        language: PluralRules.Language, arguments: [Int], depth: Int
    ) -> String {
        var out = ""
        let scalars = Array(text.unicodeScalars)
        var i = 0
        func argument(_ index: Int) -> Int { index < arguments.count ? arguments[index] : 0 }
        while i < scalars.count {
            let c = scalars[i]
            guard c == "%" else { out.unicodeScalars.append(c); i += 1; continue }
            if i + 1 < scalars.count, scalars[i + 1] == "%" { out += "%"; i += 2; continue }
            // An optional `N$`.
            var j = i + 1
            var position: Int?
            var digits = 0
            while j < scalars.count, let d = scalars[j].properties.numericType != nil ? Int(String(scalars[j])) : nil {
                digits = digits * 10 + d
                j += 1
            }
            if j < scalars.count, scalars[j] == "$", j > i + 1 {
                position = digits - 1
                j += 1
            } else {
                j = i + 1
            }
            // A variable: `#@name@`.
            if j + 1 < scalars.count, scalars[j] == "#", scalars[j + 1] == "@",
               let close = scalars[(j + 2)...].firstIndex(of: "@") {
                let name = String(String.UnicodeScalarView(scalars[(j + 2) ..< close]))
                let index: Int
                if let position { index = position } else { index = next; next += 1 }
                if depth < 8, let variable = entry.variables[name] {
                    let value = argument(index)
                    let category = PluralRules.category(of: value, in: language)
                    let form = (value == 0 ? variable.forms["zero"] : nil)
                        ?? variable.forms[category] ?? variable.forms["other"] ?? ""
                    out += expand(form, entry: entry, own: index, next: &next, locale: locale,
                                  language: language, arguments: arguments, depth: depth + 1)
                }
                i = close + 1
                continue
            }
            // A plain specifier: flags, width, precision, length, conversion.
            var k = j
            while k < scalars.count, "-+ #0'".unicodeScalars.contains(scalars[k]) { k += 1 }
            while k < scalars.count, scalars[k].properties.numericType != nil || scalars[k] == "." || scalars[k] == "*" { k += 1 }
            while k < scalars.count, "hlqLztj".unicodeScalars.contains(scalars[k]) { k += 1 }
            guard k < scalars.count else { out += String(String.UnicodeScalarView(scalars[i...])); break }
            let spec = "%" + String(String.UnicodeScalarView(scalars[j ... k]))
            let index: Int
            if let position { index = position } else if let own { index = own } else { index = next; next += 1 }
            out += String(format: spec, locale: locale, arguments: [argument(index)])
            i = k + 1
        }
        return out
    }
}

/// CLDR's cardinal plural rules for integers, in the languages the games
/// ship and a few more, as ICU applies them on Apple (`StringsDictTests`
/// pins each against Foundation's choices on a Mac). A language not listed
/// has only `other`.
public enum PluralRules {
    /// Every category a `.stringsdict` form can be filed under.
    public static let categories = ["zero", "one", "two", "few", "many", "other"]

    /// A locale's language and region, as the rules key them.
    public struct Language: Equatable, Sendable {
        public var code: String
        public var region: String?

        public init(code: String, region: String? = nil) {
            self.code = code.lowercased()
            self.region = region?.uppercased()
        }

        public init(_ locale: Locale) {
            let parts = locale.identifier.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "@" }).map(String.init)
            let region = parts.dropFirst().first { $0.count == 2 && $0.uppercased() == $0 }
            self.init(code: parts.first ?? "en", region: region)
        }
    }

    /// `n`'s category in `language`.
    public static func category(of n: Int, in language: Language) -> String {
        let i = n.magnitude
        let mod10 = i % 10, mod100 = i % 100
        let million = i != 0 && i % 1_000_000 == 0
        switch language.code {
        case "ja", "ko", "zh", "th", "vi", "id", "ms", "lo", "my", "km", "yue":
            return "other"
        case "ru", "uk", "be":
            if mod10 == 1 && mod100 != 11 { return "one" }
            if (2 ... 4).contains(mod10) && !(12 ... 14).contains(mod100) { return "few" }
            return "many"
        case "pl":
            if i == 1 { return "one" }
            if (2 ... 4).contains(mod10) && !(12 ... 14).contains(mod100) { return "few" }
            return "many"
        case "ar":
            if i == 0 { return "zero" }
            if i == 1 { return "one" }
            if i == 2 { return "two" }
            if (3 ... 10).contains(mod100) { return "few" }
            if (11 ... 99).contains(mod100) { return "many" }
            return "other"
        case "fr":
            if i <= 1 { return "one" }
            return million ? "many" : "other"
        case "pt":
            if language.region == "PT" ? i == 1 : i <= 1 { return "one" }
            return million ? "many" : "other"
        case "es", "it", "ca":
            if i == 1 { return "one" }
            return million ? "many" : "other"
        case "hi", "bn", "gu", "kn", "mr", "fa", "zu", "am":
            return i <= 1 ? "one" : "other"
        case "en", "de", "nl", "sv", "da", "nb", "no", "nn", "fi", "et", "el", "hu", "bg", "tr", "az", "ka", "sw", "ur":
            return i == 1 ? "one" : "other"
        default:
            return "other"
        }
    }
}
#endif
