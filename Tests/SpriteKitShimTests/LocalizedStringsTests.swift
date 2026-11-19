import Foundation
import Testing
@testable import SpriteKitShim

// `NSLocalizedString` where `Bundle.main` holds no `.lproj` (Android): the
// `.strings` parser, checked against Foundation's own on the Mac, and the
// language and fallback order, as Apple's `Bundle.main` looks a key up.

private let fixture = #"""
/* A block comment, with "quotes" and = signs; */
"title" = "Example Game";
// A line comment
"button.play" = "Play »";
"escapes" = "Tab\there, \"quoted\", back\\slash, line\nbreak";
"unicode" = "\U00e9té";
"control" = "\a\b\f\v\0x \101\102\012 \351";
"pair" = "\UD83D\UDE00";
"lower" = "\u00e9 \q";
"spaced"   =    "x"   ;
unquoted.key = "bare";
"empty" = "";
"multi
line" = "kept";
"""#

@Suite("Localized strings", .serialized)
struct LocalizedStringsTests {
    @Test("A strings file parses as Foundation's property list parser parses it")
    func parsesAsFoundation() throws {
        for encoding in [String.Encoding.utf8, .utf16] {
            let data = try #require(fixture.data(using: encoding))
            let ours = StringsFile.parse(data)
            let foundation = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            #expect(ours == foundation, "\(encoding)")
            #expect(ours["button.play"] == "Play »")
        }
    }

    /// A temporary APK: `lproj/<language>.lproj/Localizable.strings` for each.
    private func install(_ tables: [String: String], preferring languages: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lproj-\(UUID().uuidString)")
        for (language, text) in tables {
            let folder = root.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        LocalizedStrings.reset()
        LocalizedStrings.localizations = { Array(tables.keys) }
        LocalizedStrings.preferredLanguages = { languages }
        BundleResources.folderProvider = { name, ext in
            ext == "lproj" && tables[name] != nil ? root.appendingPathComponent("\(name).lproj").path : nil
        }
        return root
    }

    private func uninstall(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
        BundleResources.folderProvider = nil
        LocalizedStrings.localizations = nil
        LocalizedStrings.preferredLanguages = { PreferredLanguages.current }
        LocalizedStrings.reset()
    }

    @Test("The player's languages are the ones the shell put in AppleLanguages, which the strings read")
    func preferredLanguagesFromTheShell() {
        let saved = UserDefaults.standard.object(forKey: "AppleLanguages")
        defer { UserDefaults.standard.set(saved, forKey: "AppleLanguages") }
        UserDefaults.standard.set(["ja-JP", "en-US"], forKey: "AppleLanguages")
        #expect(PreferredLanguages.current == ["ja-JP", "en-US"])
        #expect(LocalizedStrings.preferredLanguages() == ["ja-JP", "en-US"])
        UserDefaults.standard.set([String](), forKey: "AppleLanguages")
        #expect(PreferredLanguages.current == Locale.preferredLanguages, "with none set, Foundation's")
    }

    /// Each case as `Bundle.main` answered it on macOS 27.2, with these
    /// folders beside a command-line tool whose Info.plist names `en` as
    /// its development region, and `-AppleLanguages` set.
    @Test("The device's language, matched as Apple matches it, else the development language; a missing key is the value or the key")
    func lookup() throws {
        let tables = [
            "Base": #""a" = "A (Base)"; "b" = "B (Base)";"#,
            "de": #""a" = "A (de)";"#,
            "pt-PT": #""a" = "A (pt-PT)";"#,
            "zh-Hant": #""a" = "A (zh-Hant)";"#,
        ]
        func string(_ key: String, value: String = "", preferring languages: [String]) throws -> String {
            let root = try install(tables, preferring: languages)
            defer { uninstall(root) }
            return LocalizedStrings.string(forKey: key, table: nil, value: value)
        }
        #expect(try string("a", preferring: ["de-AT", "en"]) == "A (de)")
        #expect(try string("a", preferring: ["pt-BR"]) == "A (pt-PT)")
        #expect(try string("a", preferring: ["zh-TW"]) == "A (zh-Hant)")
        #expect(try string("a", preferring: ["zh-HK"]) == "A (zh-Hant)")
        #expect(try string("a", preferring: ["fi", "de"]) == "A (de)")
        // English is the development language, which Base holds.
        #expect(try string("a", preferring: ["en-GB", "de"]) == "A (Base)")
        // A language the game doesn't have: the development language.
        #expect(try string("a", preferring: ["fi"]) == "A (Base)")
        // A key the chosen table lacks: not looked for elsewhere.
        #expect(try string("b", preferring: ["de"]) == "b")
        #expect(try string("b", preferring: ["fi"]) == "B (Base)")
        // In neither: the value, else the key.
        #expect(try string("c", value: "fallback", preferring: ["de"]) == "fallback")
        #expect(try string("c", preferring: ["de"]) == "c")
    }

    /// Apple's answers with `CFBundleDevelopmentRegion` set to `de`.
    @Test("The app's own development region, not always en")
    func developmentRegion() throws {
        let tables = [
            "Base": #""a" = "A (Base)";"#,
            "de": #""a" = "A (de)";"#,
            "fr": #""a" = "A (fr)";"#,
        ]
        let saved = AppIdentity.current
        AppIdentity.current.developmentRegion = "de"
        defer { AppIdentity.current = saved }
        for (languages, expected) in [(["en-GB", "de"], "A (de)"), (["fi"], "A (de)"), (["fr"], "A (fr)")] {
            let root = try install(tables, preferring: languages)
            #expect(LocalizedStrings.string(forKey: "a", table: nil, value: "") == expected, "\(languages)")
            uninstall(root)
        }
    }

    @Test("Another table, by name")
    func otherTable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lproj-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Base.lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #""k" = "from Content";"#.write(to: folder.appendingPathComponent("Content.strings"), atomically: true, encoding: .utf8)
        LocalizedStrings.reset()
        LocalizedStrings.localizations = { ["Base"] }
        BundleResources.folderProvider = { name, _ in name == "Base" ? folder.path : nil }
        defer { uninstall(root) }
        #expect(LocalizedStrings.string(forKey: "k", table: "Content", value: "") == "from Content")
        #expect(LocalizedStrings.string(forKey: "k", table: nil, value: "") == "k")
    }

    @Test("A table read by its path, once")
    func tableAtPath() throws {
        let root = try install(["fr": #""a" = "A (fr)";"#], preferring: ["fr"])
        defer { uninstall(root) }
        let path = root.appendingPathComponent("fr.lproj/Localizable.strings").path
        #expect(LocalizedStrings.table(atPath: path) == ["a": "A (fr)"])
        try #""a" = "changed";"#.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(LocalizedStrings.table(atPath: path) == ["a": "A (fr)"])
        #expect(LocalizedStrings.table(atPath: root.appendingPathComponent("none.strings").path).isEmpty)
    }
}
