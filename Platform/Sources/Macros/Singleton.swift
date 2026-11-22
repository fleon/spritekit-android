/// Makes a type its own one instance: `static let shared = TypeName()` (as
/// public as the type), and a `private init() {}` unless the type writes its
/// own `init()`, which it does when making the instance takes work (reading
/// saved data, observing). A subclass of `NSObject` gets
/// `private override init() { super.init() }`. The instance takes the
/// type's isolation: main-actor in a main-actor module, none in a
/// `nonisolated` type.
///
/// ```swift
/// @Singleton
/// final class ProgressStore {
///     private(set) var cleared: Set<Int> = []
/// }
///
/// @Singleton
/// final class Feed {
///     private let session: URLSession
///     private init() {
///         session = URLSession(configuration: .ephemeral)
///     }
/// }
/// ```
///
/// A type whose only initializers take arguments can't be one: make its
/// instance where its arguments are known (`static let shared =
/// Manager(configuration: ...)`).
@attached(member, names: named(shared), named(init))
public macro Singleton() = #externalMacro(module: "MacrosPlugin", type: "SingletonMacro")
