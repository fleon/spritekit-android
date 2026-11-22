/// Which `LaunchArgumentReader` method `@LaunchArgument(as:)` reads with,
/// where the declared type's own pick isn't the one wanted (`.fraction` for
/// `"1/60"`, say).
public enum LaunchArgumentRead: Sendable {
    case bool, string, int, double, value, list, numbers, size, fraction
}

/// Writes a `var`'s getter as a read of one debug launch argument through
/// a `LaunchArgumentReader` (`PlatformCore`), so a release build takes the
/// fixed `release:` value.
///
/// The reader is the enclosing type's static `reader`
/// (`static let reader = LaunchArgumentReader(enabled: ...)`, `enabled` in
/// debug builds only), or the expression `reader:` names as a string
/// (`reader: "Debug.reader"`). Make it `nonisolated` where a `nonisolated`
/// property reads it.
///
/// The declared type, written out, picks the method:
///
/// | Type | Reads with | Unset reads as |
/// |---|---|---|
/// | `Bool` | `bool` | `false`, or `unset:` |
/// | `String?`, `URL?` | `string` | `nil` |
/// | `Int?` | `int` | `nil` |
/// | `Double?`, `TimeInterval?`, `CGFloat?`, `Float?` | `double` | `nil` |
/// | `CGSize?` | `size` (`1376x1032`) | `nil` |
/// | `UInt64?` and the other integers | `string` | `nil` |
/// | `[String]?`, `[Int]?`, `[URL]?` | `list` | `nil` |
/// | `[Double]?`, `[TimeInterval]?`, `[CGFloat]?` | `numbers` | `nil` |
/// | any other `T?`, `[T]?` | `value` (a `String`-backed enum) | `nil` |
///
/// A non-optional type reads as its zero (`0`, `""`, `[]`, `.zero`) when the
/// key isn't given, or as `unset:`, else `release:`; a non-optional enum
/// needs one of them. `release:` defaults to `unset:`, else to the
/// type's zero or `nil`. `as:` picks another method (`.fraction` for a
/// `Double?`, `.string` for a `String`-convertible type), `separator:` a
/// list's separator. Write enum cases out in full (`Mode.fast`, not `.fast`):
/// the arguments are type-checked before the property's type is known.
///
/// ```swift
/// enum Debug {
///     static let reader = LaunchArgumentReader(enabled: isDebugBuild)
///
///     @LaunchArgument("HideStats") static var hidesStats: Bool
///     @LaunchArgument("StartLevel") static var startLevel: String?
///     @LaunchArgument("AnimationSlowdown", unset: 1) static var slowdown: Double
///     @LaunchArgument("FixedFrameStep", as: .fraction) static var frameStep: TimeInterval?
///     @LaunchArgument("Tour", separator: ";") static var tour: [String]
///     @LaunchArgument("Playtest", unset: true) static var playtests: Bool
/// }
/// ```
///
/// expands `hidesStats` to `get { Self.reader.bool("HideStats") }` and
/// `slowdown` to `get { Self.reader.double("AnimationSlowdown") ?? 1 }`.
@attached(accessor)
public macro LaunchArgument(
    _ key: String,
    unset: Any? = nil,
    release: Any? = nil,
    as read: LaunchArgumentRead? = nil,
    separator: Character? = nil,
    reader: String? = nil
) = #externalMacro(module: "MacrosPlugin", type: "LaunchArgumentMacro")
