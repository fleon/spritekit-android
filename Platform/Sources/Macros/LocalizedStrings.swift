import Foundation

/// How `localized` fills a case's associated values into its string.
public enum LocalizedFormatting {
    /// `String(format:)`, the values in order.
    case plain
    /// `String.localizedStringWithFormat`, the values in order (the current
    /// locale's digits and a `.stringsdict`'s plurals).
    case localized
    /// The enum's own `customLocalized(_ format: String) -> String`, handed
    /// the looked-up string.
    case custom
}

/// Where `localized` looks a key up.
public enum LocalizedLookup {
    /// `NSLocalizedString`, with the enum's `table` and `bundle`.
    case foundation
    /// The enum's own `static func lookup(_ key: String, fallback: String) -> String`,
    /// or `lookup(_ key: String) -> String` when no case has a fallback.
    case custom
}

/// A case whose key is built at run time.
public enum LocalizedKey {
    /// The enum's own `customKey` (and `customFallback` and `customComment`,
    /// when other cases have them) answers for the case.
    case custom
}

/// A type-safe strings layer: an enum whose every case carries `@L(...)`
/// gets `key`, `fallback` and `comment` (each when any case gives one) and
/// `localized`, one switch apiece. Generated members carry the enum's
/// `public` or `package` and its `nonisolated`.
///
/// ```swift
/// @LocalizedStrings
/// enum LocalizedString {
///     @L("title.play", "Play", comment: "Title screen button")
///     case play
///     @L("levels.completed", "%d of %d", comment: "Completed and total levels")
///     case completedLevels(Int, Int)
/// }
/// ```
///
/// `localized` is `NSLocalizedString(key, value: fallback, comment: comment)`,
/// then, for a case with associated values, `String(format:)` with them in
/// order. `table` and `bundle` go to `NSLocalizedString`; `lookup: .custom`
/// reads the enum's own `lookup` instead; `formatting` is every case's default.
///
/// Each case needs `@L`; a fallback whose placeholders don't match the
/// associated values, and a key used twice, are errors.
@attached(member, names: named(key), named(fallback), named(comment), named(localized))
public macro LocalizedStrings(
    table: String? = nil,
    bundle: Bundle? = nil,
    lookup: LocalizedLookup = .foundation,
    formatting: LocalizedFormatting = .plain
) = #externalMacro(module: "MacrosPlugin", type: "LocalizedStringsMacro")

/// A `@LocalizedStrings` case: its key, its English fallback, its comment
/// for translators, and how its associated values are filled in (else the
/// enum's `formatting`).
@attached(peer)
public macro L(
    _ key: String,
    _ fallback: String? = nil,
    comment: String? = nil,
    formatting: LocalizedFormatting? = nil
) = #externalMacro(module: "MacrosPlugin", type: "LocalizedCaseMacro")

/// A `@LocalizedStrings` case whose key is built at run time, by the enum's
/// `customKey`. Its string is returned as looked up unless `formatting` is
/// given (`.plain` or `.localized` fill in its associated values, `.custom`
/// hands it to `customLocalized(_:)`).
@attached(peer)
public macro L(
    _ key: LocalizedKey,
    formatting: LocalizedFormatting? = nil
) = #externalMacro(module: "MacrosPlugin", type: "LocalizedCaseMacro")
