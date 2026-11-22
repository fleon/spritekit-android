/// A macro that generates a required `init?(coder:)` initializer with a `fatalError`.
///
/// Use this macro on classes that inherit from `NSCoding`-conforming types (like `SKNode`)
/// but are only instantiated programmatically and don't support decoding from archives.
/// On a `public` or `open` class the initializer is `public`.
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

/// The superclass's designated initializers `@NSCodingUnsupported(inherit:)`
/// passes through.
public enum InheritedInit {
    /// `override init()`, as `SKNode` has it.
    case plain
    /// `required init()`, for a subclass of a class whose `init()` is
    /// `required` (a family of nodes its base makes by type); `override` is
    /// implied there.
    case requiredPlain
    /// `override init(size: CGSize)`, as `SKScene` has it.
    case size
}

/// `@NSCodingUnsupported`, and the superclass's designated initializers it
/// would otherwise stop the class inheriting: a class that adds
/// `init?(coder:)` inherits none of them, so a scene still made with
/// `init(size:)` writes it again.
///
///     @NSCodingUnsupported(inherit: .size)
///     final class TitleScene: SKScene {}
///
/// Expands to:
///
///     final class TitleScene: SKScene {
///
///         override init(size: CGSize) {
///             super.init(size: size)
///         }
///
///         required init?(coder aDecoder: NSCoder) {
///             fatalError("init(coder:) has not been implemented")
///         }
///     }
@attached(member, names: named(init(coder:)), named(init))
public macro NSCodingUnsupported(inherit first: InheritedInit, _ more: InheritedInit...) =
    #externalMacro(module: "MacrosPlugin", type: "NSCodingUnsupportedMacro")
