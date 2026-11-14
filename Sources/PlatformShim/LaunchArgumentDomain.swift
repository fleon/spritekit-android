import Foundation

/// What Foundation makes of a launch's arguments on Apple: `UserDefaults`'
/// argument domain (`NSArgumentDomain`), which `LaunchArguments` and the
/// settings read.
///
/// On Apple the process's argv fills it. An Android app's argv is the
/// zygote's, so the shell hands over the intent's arguments
/// (`ShellArguments`) and puts this in the domain itself.
public enum LaunchArgumentDomain {
    /// `-Key value` pairs, each value read as a property list where it is
    /// one (`<false/>`, `(garden-1,garden-2)`, `{a = 1;}`, `"quoted"`), else
    /// kept as text, so `YES` stays the string `bool(forKey:)` reads as true.
    /// A key with no value after it is skipped, and as on Apple anything
    /// starting with a dash is never a value (not `-0.1`, not `-`), so
    /// `-Markers -StartLevel x` sets only `StartLevel`.
    public static func parse(_ values: [String]) -> [String: Any] {
        var domain: [String: Any] = [:]
        var index = 0
        while index < values.count {
            let key = values[index]
            guard key.hasPrefix("-"), key.count > 1, index + 1 < values.count, !isKey(values[index + 1]) else {
                index += 1
                continue
            }
            domain[String(key.dropFirst())] = value(values[index + 1])
            index += 2
        }
        return domain
    }

    private static func isKey(_ text: String) -> Bool { text.hasPrefix("-") }

    private static func value(_ text: String) -> Any {
        guard let first = text.first, "<({\"".contains(first), let data = text.data(using: .utf8),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return text }
        return parsed
    }
}
