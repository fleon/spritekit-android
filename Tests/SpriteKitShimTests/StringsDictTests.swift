import Foundation
import Testing
@testable import SpriteKitShim

// `.stringsdict` plurals (`StringsDict`, `PluralRules`), pinned to what
// Foundation answered on macOS 27.2: a plural variable's category in each
// language the games ship (and Polish and Arabic), and how a format with
// variables is resolved. On a Mac each case is also checked against
// Foundation itself, so a change there shows.

@Suite("Stringsdict plurals", .serialized)
struct StringsDictTests {
    static let numbers = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 19, 20, 21, 22, 23, 24, 25, 100, 101, 102, 103, 104, 105, 111, 112, 1000, 1001, 1000000, 2000000, 1000001]
    /// Each language's category for each of `numbers`: z zero, 1 one, 2 two, f few, m many, . other.
    static let categories: [String: String] = [
        "ar": "z12fffffffmmmmmmmmmmmm...fffmm.....",
        "de": "z1.................................",
        "en": "z1.................................",
        "es": "z1..............................mm.",
        "es-MX": "z1..............................mm.",
        "fr": "z1..............................mm.",
        "hi": "z1.................................",
        "id": "z..................................",
        "it": "z1..............................mm.",
        "ja": "z..................................",
        "ko": "z..................................",
        "nl": "z1.................................",
        "pl": "z1fffmmmmmmmmmmmmmfffmmmfffmmmmmmmm",
        "pt": "z1..............................mm.",
        "pt-BR": "z1..............................mm.",
        "pt-PT": "z1..............................mm.",
        "ru": "z1fffmmmmmmmmmmmm1fffmm1fffmmmm1mm1",
        "th": "z..................................",
        "tr": "z1.................................",
        "uk": "z1fffmmmmmmmmmmmm1fffmm1fffmmmm1mm1",
        "vi": "z..................................",
        "zh-Hans": "z..................................",
        "zh-Hant": "z..................................",
    ]

    /// A variable whose six forms each name their category.
    private static let named = StringsDict.Entry(format: "%#@v@", variables: [
        "v": StringsDict.Variable(valueType: "ld", forms: Dictionary(uniqueKeysWithValues: PluralRules.categories.map { ($0, $0) })),
    ])

    private static let short = ["zero": "z", "one": "1", "two": "2", "few": "f", "many": "m", "other": "."]

    @Test("Each language's category, as Foundation picks it with that locale (zero wins for 0)")
    func categories() {
        for (language, expected) in Self.categories {
            let locale = Locale(identifier: language)
            let ours = Self.numbers.map { Self.short[StringsDict.format(Self.named, locale: locale, pluralLocale: locale, arguments: [$0])] ?? "?" }.joined()
            #expect(ours == expected, "\(language)")
        }
    }

    /// A word game's entries and the edge cases, with what Foundation
    /// formatted on a Mac (`String(format:locale:)`, en_US).
    private static let entries: [String: StringsDict.Entry] = {
        func rule(_ type: String, _ forms: [String: String]) -> StringsDict.Variable { .init(valueType: type, forms: forms) }
        let words = rule("d", ["one": "%d word", "other": "%d words"])
        return [
            "found": .init(format: "You found %#@words@.", variables: ["words": words]),
            "overused": .init(format: "You found %#@words@, but %d of %#@tiles@ were overused.",
                              variables: ["words": words, "tiles": rule("d", ["one": "%d tile", "other": "%d tiles"])]),
            "onlyOneOther": .init(format: "%#@n@", variables: ["n": rule("d", ["one": "%d item", "other": "%d items"])]),
            "positional": .init(format: "%2$#@b@ / %1$#@a@", variables: [
                "a": rule("d", ["one": "%d apple", "other": "%d apples"]), "b": rule("d", ["one": "%d box", "other": "%d boxes"]),
            ]),
            "nested": .init(format: "%#@outer@", variables: [
                "outer": rule("d", ["one": "one row of %#@inner@", "other": "%d rows of %#@inner@"]),
                "inner": rule("d", ["one": "%d tile", "other": "%d tiles"]),
            ]),
            "textNoNumber": .init(format: "%#@n@ left", variables: ["n": rule("ld", ["one": "One", "other": "%ld"])]),
            "percent": .init(format: "100%% of %#@n@", variables: ["n": rule("d", ["one": "%d tile", "other": "%d tiles"])]),
        ]
    }()

    private static let cases: [(key: String, arguments: [Int], expected: String)] = [
        ("found", [0], "You found 0 words."),
        ("found", [1], "You found 1 word."),
        ("found", [2], "You found 2 words."),
        ("overused", [1, 1, 1], "You found 1 word, but 1 of 1 tile were overused."),
        ("overused", [7, 2, 5], "You found 7 words, but 2 of 5 tiles were overused."),
        ("onlyOneOther", [0], "0 items"),
        ("onlyOneOther", [1], "1 item"),
        ("positional", [1, 2], "2 boxes / 1 apple"),
        ("positional", [3, 1], "1 box / 3 apples"),
        ("nested", [1, 1], "one row of 1 tile"),
        ("nested", [2, 3], "2 rows of 3 tiles"),
        ("textNoNumber", [1], "One left"),
        ("textNoNumber", [4], "4 left"),
        ("percent", [1], "100% of 1 tile"),
    ]

    @Test("A format's variables resolve as Foundation resolves them")
    func formats() throws {
        let locale = Locale(identifier: "en_US")
        for test in Self.cases {
            let entry = try #require(Self.entries[test.key])
            let ours = StringsDict.format(entry, locale: locale, pluralLocale: locale, arguments: test.arguments)
            #expect(ours == test.expected, "\(test.key) \(test.arguments)")
            #if canImport(Darwin)
            let theirs = try Self.foundation(entry, locale: locale, arguments: test.arguments)
            #expect(ours == theirs, "\(test.key) \(test.arguments) against Foundation")
            #endif
        }
    }

    @Test("Numbers are formatted for the locale, the categories by its language")
    func localeFormatting() throws {
        let entry = try #require(Self.entries["found"])
        let german = Locale(identifier: "de_DE"), russian = Locale(identifier: "ru_RU")
        #expect(StringsDict.format(entry, locale: german, pluralLocale: german, arguments: [1000]) == "You found 1.000 words.")
        #expect(StringsDict.format(entry, locale: nil, pluralLocale: german, arguments: [1000]) == "You found 1000 words.")
        // Russian's categories with an entry that has only one and other: few
        // and many fall back to other.
        #expect(StringsDict.format(entry, locale: russian, pluralLocale: russian, arguments: [21]) == "You found 21 word.")
        #expect(StringsDict.format(entry, locale: russian, pluralLocale: russian, arguments: [22]) == "You found 22 words.")
        #if canImport(Darwin)
        for (locale, n) in [(german, 1000), (russian, 21), (russian, 22)] {
            #expect(StringsDict.format(entry, locale: locale, pluralLocale: locale, arguments: [n]) == (try Self.foundation(entry, locale: locale, arguments: [n])))
        }
        #endif
    }

    @Test("A stringsdict file parses into its plural entries")
    func parses() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: Self.plist(Self.entries), format: .xml, options: 0)
        let parsed = StringsDict.parse(data)
        #expect(parsed == Self.entries)
    }

    @Test("A key in the stringsdict comes before the strings file's, and its format is registered")
    func lookup() throws {
        StringsDict.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stringsdict-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: Self.plist(Self.entries), format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("Localizable.stringsdict"))
        try #""found" = "From strings %d"; "plain" = "Plain";"#.write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        LocalizedStrings.reset()
        LocalizedStrings.localizations = { ["en"] }
        LocalizedStrings.preferredLanguages = { ["en"] }
        BundleResources.folderProvider = { name, ext in ext == "lproj" && name == "en" ? folder.path : nil }
        defer {
            try? FileManager.default.removeItem(at: root)
            BundleResources.folderProvider = nil
            LocalizedStrings.localizations = nil
            LocalizedStrings.preferredLanguages = { Locale.preferredLanguages }
            LocalizedStrings.reset()
            StringsDict.reset()
        }
        let format = LocalizedStrings.string(forKey: "found", table: nil, value: "")
        #expect(format == "You found %#@words@.")
        #expect(StringsDict.entry(for: format) == Self.entries["found"])
        #expect(LocalizedStrings.string(forKey: "plain", table: nil, value: "") == "Plain")
        #expect(LocalizedStrings.pluralFormat(forKey: "overused", atPath: folder.appendingPathComponent("Localizable.stringsdict").path)
            == Self.entries["overused"]?.format)
        #expect(LocalizedStrings.pluralFormat(forKey: "plain", atPath: folder.appendingPathComponent("Localizable.stringsdict").path) == nil)
    }

    /// The entries as a `.stringsdict` property list.
    private static func plist(_ entries: [String: StringsDict.Entry]) -> [String: Any] {
        entries.mapValues { entry -> [String: Any] in
            var dict: [String: Any] = ["NSStringLocalizedFormatKey": entry.format]
            for (name, variable) in entry.variables {
                var spec: [String: Any] = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": variable.valueType]
                for (category, form) in variable.forms { spec[category] = form }
                dict[name] = spec
            }
            return dict
        }
    }

    #if canImport(Darwin)
    /// What Foundation makes of `entry` with `arguments` in `locale`: the
    /// entry in a bundle's `.stringsdict`, looked up and formatted.
    private static func foundation(_ entry: StringsDict.Entry, locale: Locale, arguments: [Int]) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stringsdict-apple-\(UUID().uuidString)/en.lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try PropertyListSerialization.data(fromPropertyList: plist(["k": entry]), format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("Localizable.stringsdict"))
        let bundle = try #require(Bundle(path: folder.path))
        let format = bundle.localizedString(forKey: "k", value: nil, table: nil)
        return String(format: format, locale: locale, arguments: arguments.map { $0 as CVarArg })
    }
    #endif
}
