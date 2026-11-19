#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

// Formatting a `.stringsdict` format (`StringsDict`) as Foundation does on
// Apple, where the format string carries its plural rules. Swift prefers
// these to Foundation's `CVarArg...` methods when every argument is an
// `Int`, which is how a count is passed; any other call is Foundation's.
// A format nothing registered goes to Foundation's unchanged.

extension String {
    /// Foundation's, resolving a `.stringsdict` format's plurals in the
    /// current locale and formatting its numbers for it.
    public static func localizedStringWithFormat(_ format: String, _ arguments: Int...) -> String {
        guard let entry = StringsDict.entry(for: format) else {
            return String(format: format, locale: Locale.current, arguments: arguments)
        }
        return StringsDict.format(entry, locale: Locale.current, pluralLocale: Locale.current, arguments: arguments)
    }

    /// Foundation's, resolving a `.stringsdict` format's plurals in the
    /// current locale; its numbers are formatted without one, as Foundation's.
    public init(format: String, _ arguments: Int...) {
        guard let entry = StringsDict.entry(for: format) else {
            self = String(format: format, locale: nil, arguments: arguments)
            return
        }
        self = StringsDict.format(entry, locale: nil, pluralLocale: Locale.current, arguments: arguments)
    }

    /// Foundation's, resolving a `.stringsdict` format's plurals in `locale`.
    public init(format: String, locale: Locale?, _ arguments: Int...) {
        guard let entry = StringsDict.entry(for: format) else {
            self = String(format: format, locale: locale, arguments: arguments)
            return
        }
        self = StringsDict.format(entry, locale: locale, pluralLocale: locale ?? Locale.current, arguments: arguments)
    }
}
#endif
