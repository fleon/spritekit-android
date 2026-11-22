/// Writes `init(from:)` for a struct or class, decoding each stored property
/// the way synthesized `Decodable` does, except that a property with an
/// initial value takes that value when its key is missing or null.
///
/// - `var x: T = value` (or `var x = value`): `decodeIfPresent ?? value`.
/// - `var x: T?` with no initial value: `decodeIfPresent`.
/// - `var x: T` or `let x: T`: `decode`.
/// - `let x = value` can't be overwritten, so it isn't decoded (a warning,
///   as synthesized `Decodable` gives).
/// - Static, computed and `lazy` properties are skipped.
///
/// A `CodingKeys` enum the type declares is honoured: its raw values rename
/// keys, and a property without a case is left at its initial value. With
/// none, the macro adds a private one. The type gets `Decodable` if it
/// doesn't say so; synthesized `Encodable` is untouched. On a `nonisolated`
/// type the initializer is `nonisolated` too.
///
/// A struct gets the initializer in an extension, so it keeps its memberwise
/// initializer. A class gets it in its body (`required` unless `final`) and
/// can't have a superclass whose initializer it would have to call. A
/// `private` struct gets it in its body too, since an extension couldn't name
/// it: it loses its memberwise initializer and declares `Decodable` (or
/// `Codable`) itself.
///
/// ```swift
/// @DecodableDefaults
/// nonisolated struct Profile: Codable {
///     var name: String
///     var coins = 0
///     var badges: [String] = []
///     var avatar: String?
/// }
/// ```
///
/// Expands to:
/// ```swift
/// nonisolated struct Profile: Codable {
///     var name: String
///     var coins = 0
///     var badges: [String] = []
///     var avatar: String?
///
///     private enum CodingKeys: String, CodingKey {
///         case name, coins, badges, avatar
///     }
/// }
///
/// extension Profile {
///     nonisolated init(from decoder: Decoder) throws {
///         let container = try decoder.container(keyedBy: CodingKeys.self)
///         self.name = try container.decode(String.self, forKey: .name)
///         self.coins = try container.decodeIfPresent(forKey: .coins) ?? 0
///         self.badges = try container.decodeIfPresent([String].self, forKey: .badges) ?? []
///         self.avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
///     }
/// }
/// ```
@attached(member, names: named(CodingKeys), named(init(from:)))
@attached(extension, conformances: Decodable, names: named(init(from:)))
public macro DecodableDefaults() =
    #externalMacro(module: "MacrosPlugin", type: "DecodableDefaultsMacro")

extension KeyedDecodingContainer {
    /// `decodeIfPresent(_:forKey:)` with the type taken from the context, for
    /// `@DecodableDefaults` properties declared without one (`var count = 0`).
    public func decodeIfPresent<T: Decodable>(forKey key: Key) throws -> T? {
        try decodeIfPresent(T.self, forKey: key)
    }
}
