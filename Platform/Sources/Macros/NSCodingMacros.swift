/// A macro that generates a required `init?(coder:)` initializer with a `fatalError`.
///
/// Use this macro on classes that inherit from `NSCoding`-conforming types (like `SKNode`)
/// but are only instantiated programmatically and don't support decoding from archives.
///
/// Example:
/// ```swift
/// @NSCodingUnsupported
/// class ButtonNode: SKNode {
///     init(title: String) {
///         // ...
///     }
/// }
/// ```
///
/// Expands to:
/// ```swift
/// class ButtonNode: SKNode {
///     init(title: String) {
///         // ...
///     }
///
///     required init?(coder aDecoder: NSCoder) {
///         fatalError("init(coder:) has not been implemented")
///     }
/// }
/// ```
@attached(member, names: named(init(coder:)))
public macro NSCodingUnsupported() =
    #externalMacro(module: "MacrosPlugin", type: "NSCodingUnsupportedMacro")
