#if SPRITEKIT_SHIM
import Foundation

/// `NSLocalizedString` on Android, where corelibs' `Bundle.main` is the
/// system's `app_process` and holds no `.lproj`, so every string came out as
/// its key.
///
/// The tables are the game's own `.strings` files, staged in the APK as
/// `lproj/<language>.lproj/<table>.strings` and copied out as asked
/// (`BundleResources.folderProvider`). As Apple's `Bundle.main` does
/// (measured on macOS 27.2; `LocalizedStringsTests`):
///
/// - The language is the first of the device's preferred languages any
///   `.lproj` serves, matched as `Bundle.preferredLocalizations` matches
///   (`LocalizationMatch`: `pt-BR` takes `pt-PT`, `zh-HK` takes `zh-Hant`),
///   else the development language (`AppIdentity.developmentRegion`, the
///   Info.plist's `CFBundleDevelopmentRegion`, `en` unless set), whose
///   strings are its own `.lproj`'s or `Base.lproj`'s.
/// - A key that language's table lacks comes back as `value`, or as the key
///   when `value` is empty: Apple doesn't look in another language's table.
///
/// Only `NSLocalizedString` is covered: `Bundle.localizedString(forKey:value:table:)`,
/// `String(localized:)` and `.stringsdict` plurals still answer with the key,
/// and the `bundle:` argument is taken but not read (only the main bundle's
/// strings are in the APK). A file that imports only Foundation sees these
/// overloads once a file of its module re-exports the shim
/// (`@_exported import SpriteKitShim`).
///
/// The overloads below take the arguments Foundation's takes, `tableName` as
/// a plain `String`, so a call passing a literal or nothing resolves to them
/// rather than to Foundation's (`LocalizedStringsTests`).
public enum LocalizedStrings {
    /// The `.lproj` folders the APK has, by name without the extension. Set
    /// by the shell (`ResourceBundle`).
    public nonisolated(unsafe) static var localizations: (() -> [String])?
    /// The device's preferred languages, most preferred first.
    public nonisolated(unsafe) static var preferredLanguages: () -> [String] = { Locale.preferredLanguages }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var tables: [String: [String: String]] = [:]
    nonisolated(unsafe) private static var chosen: String??

    /// The development language (`AppIdentity.developmentRegion`, Apple's
    /// `CFBundleDevelopmentRegion`); `Base.lproj` holds it too.
    static var developmentLanguage: String { AppIdentity.current.developmentRegion }
    static var development: [String] { [developmentLanguage, "Base"] }

    public static func string(forKey key: String, table: String?, value: String) -> String {
        let table = table.flatMap { $0.isEmpty ? nil : $0 } ?? "Localizable"
        for language in searchOrder() {
            if let found = strings(language: language, table: table)[key] { return found }
        }
        return value.isEmpty ? key : value
    }

    /// The folders the chosen language's strings are in: its own, or for
    /// the development language its own folder's and then `Base.lproj`'s.
    static func searchOrder() -> [String] {
        let available = localizations?() ?? []
        lock.lock()
        if chosen == nil {
            let languages = available.filter { $0 != "Base" } + (available.contains(developmentLanguage) ? [] : [developmentLanguage])
            chosen = .some(LocalizationMatch.best(of: languages, for: preferredLanguages()) ?? developmentLanguage)
        }
        let language = (chosen ?? nil) ?? developmentLanguage
        lock.unlock()
        let folders = language == developmentLanguage ? development : [language]
        return folders.filter(available.contains)
    }

    /// One language's table, read once.
    private static func strings(language: String, table: String) -> [String: String] {
        let name = "\(language)/\(table)"
        lock.lock()
        if let cached = tables[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var parsed: [String: String] = [:]
        if let folder = BundleResources.folderProvider?(language, "lproj"),
           let data = FileManager.default.contents(atPath: folder + "/" + table + ".strings") {
            parsed = StringsFile.parse(data)
        }
        lock.lock()
        tables[name] = parsed
        lock.unlock()
        return parsed
    }

    /// Forgets the tables and the language chosen (tests).
    static func reset() {
        lock.lock()
        tables = [:]
        chosen = nil
        lock.unlock()
    }
}

/// A `.strings` file: `"key" = "value";` pairs, with `/* */` and `//`
/// comments, Apple's backslash escapes (`\"`, `\\`, `\n`, `\t`, `\r`,
/// `\Uxxxx`), UTF-8 or UTF-16 with a byte order mark, and unquoted keys of
/// letters, digits and `_.-:$/`, as Foundation's old-style property list
/// parser takes them.
enum StringsFile {
    static func parse(_ data: Data) -> [String: String] {
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16) ?? ""
        } else {
            text = String(decoding: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...], as: UTF8.self)
        }
        var scanner = Scanner(Array(text.unicodeScalars))
        var result: [String: String] = [:]
        while true {
            scanner.skipSpaceAndComments()
            guard let key = scanner.token() else { break }
            scanner.skipSpaceAndComments()
            if scanner.take("=") {
                scanner.skipSpaceAndComments()
                guard let value = scanner.token() else { break }
                result[key] = value
                scanner.skipSpaceAndComments()
            } else {
                // `"key";` alone means the key is its own value.
                result[key] = key
            }
            guard scanner.take(";") else { break }
        }
        return result
    }

    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var at = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var current: Unicode.Scalar? { at < scalars.count ? scalars[at] : nil }
        func peek(_ offset: Int) -> Unicode.Scalar? { at + offset < scalars.count ? scalars[at + offset] : nil }

        mutating func take(_ character: Unicode.Scalar) -> Bool {
            guard current == character else { return false }
            at += 1
            return true
        }

        mutating func skipSpaceAndComments() {
            while let c = current {
                if c.properties.isWhitespace {
                    at += 1
                } else if c == "/", peek(1) == "*" {
                    at += 2
                    while at < scalars.count, !(current == "*" && peek(1) == "/") { at += 1 }
                    at = min(scalars.count, at + 2)
                } else if c == "/", peek(1) == "/" {
                    while let c = current, c != "\n" { _ = c; at += 1 }
                } else {
                    return
                }
            }
        }

        mutating func token() -> String? {
            guard let c = current else { return nil }
            if c == "\"" {
                at += 1
                var out = String.UnicodeScalarView()
                while let c = current, c != "\"" {
                    at += 1
                    guard c == "\\", let escaped = current else {
                        out.append(c)
                        continue
                    }
                    at += 1
                    switch escaped {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "U", "u":
                        var hex = ""
                        while hex.count < 4, let h = current, h.properties.isASCIIHexDigit {
                            hex.unicodeScalars.append(h)
                            at += 1
                        }
                        if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { out.append(scalar) }
                    default: out.append(escaped)
                    }
                }
                guard take("\"") else { return nil }
                return String(out)
            }
            var out = String.UnicodeScalarView()
            while let c = current, c.properties.isAlphabetic || ("0"..."9").contains(c) || "_.-:$/".unicodeScalars.contains(c) {
                out.append(c)
                at += 1
            }
            return out.isEmpty ? nil : String(out)
        }
    }
}

#if !canImport(Darwin)
// Foundation's `NSLocalizedString` takes `tableName: String?`, `bundle` and
// `value` with defaults; each of these takes the arguments a call actually
// passes, as non-optional values, which Swift prefers. Only `Bundle.main`'s
// strings live in the APK, so `bundle` is taken and not read.

public func NSLocalizedString(_ key: String, comment: String) -> String {
    LocalizedStrings.string(forKey: key, table: nil, value: "")
}

public func NSLocalizedString(_ key: String, tableName: String, comment: String) -> String {
    LocalizedStrings.string(forKey: key, table: tableName, value: "")
}

public func NSLocalizedString(_ key: String, bundle: Bundle, comment: String) -> String {
    LocalizedStrings.string(forKey: key, table: nil, value: "")
}

public func NSLocalizedString(_ key: String, value: String, comment: String) -> String {
    LocalizedStrings.string(forKey: key, table: nil, value: value)
}

public func NSLocalizedString(_ key: String, tableName: String, bundle: Bundle, comment: String) -> String {
    LocalizedStrings.string(forKey: key, table: tableName, value: "")
}

public func NSLocalizedString(_ key: String, tableName: String, value: String, comment: String) -> String {
    LocalizedStrings.string(forKey: key, table: tableName, value: value)
}

public func NSLocalizedString(_ key: String, bundle: Bundle, value: String, comment: String) -> String {
    LocalizedStrings.string(forKey: key, table: nil, value: value)
}

public func NSLocalizedString(_ key: String, tableName: String, bundle: Bundle, value: String, comment: String) -> String {
    LocalizedStrings.string(forKey: key, table: tableName, value: value)
}
#endif

#endif
