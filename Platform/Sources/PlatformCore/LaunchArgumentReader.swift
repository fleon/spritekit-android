import Foundation
import SpriteKitShim

/// Reads a game's debug launch arguments (`-StartLevel x -HideStats YES`)
/// from `UserDefaults`' argument domain, typed: where a game's debug build
/// reads them and its release build takes fixed values, it makes one reader
/// with `enabled` false in release and every read answers its `release`
/// value. The arguments themselves (their keys and meanings) are the game's.
///
/// Values read as `UserDefaults` reads them: `bool` takes `YES`, `true` or
/// a non-zero number; a plain `NO` reads as false. Lists are split on a
/// separator (empty items left out, as `split` leaves them out), each item
/// trimmed of spaces.
public nonisolated struct LaunchArgumentReader: @unchecked Sendable {
    public let defaults: UserDefaults
    public let isEnabled: Bool

    public init(defaults: UserDefaults = .standard, enabled: Bool) {
        self.defaults = defaults
        isEnabled = enabled
    }

    /// Whether `key` was given at all.
    public func isSet(_ key: String) -> Bool {
        isEnabled && defaults.object(forKey: key) != nil
    }

    public func bool(_ key: String, release: Bool = false) -> Bool {
        isEnabled ? defaults.bool(forKey: key) : release
    }

    /// `key`'s value as a bool where given, else `fallback` (`-Playtest NO`
    /// against a default that depends on the device, say).
    public func bool(_ key: String, unset fallback: Bool, release: Bool) -> Bool {
        guard isEnabled else { return release }
        return isSet(key) ? defaults.bool(forKey: key) : fallback
    }

    public func string(_ key: String, release: String? = nil) -> String? {
        isEnabled ? defaults.string(forKey: key) : release
    }

    public func double(_ key: String, release: Double? = nil) -> Double? {
        guard isEnabled else { return release }
        return isSet(key) ? defaults.double(forKey: key) : nil
    }

    public func int(_ key: String, release: Int? = nil) -> Int? {
        guard isEnabled else { return release }
        return isSet(key) ? defaults.integer(forKey: key) : nil
    }

    /// One of a `String`-backed enum's cases, by its raw value.
    public func value<Value: RawRepresentable>(_ key: String, release: Value? = nil) -> Value? where Value.RawValue == String {
        guard isEnabled else { return release }
        return defaults.string(forKey: key).flatMap(Value.init(rawValue:))
    }

    /// `"a,b, c"` as `["a", "b", "c"]`; nil when `key` isn't given.
    public func list(_ key: String, separator: Character = ",", release: [String]? = nil) -> [String]? {
        guard isEnabled else { return release }
        return defaults.string(forKey: key).map { Self.split($0, separator: separator) }
    }

    /// `"0,1.4,2.8"` as numbers, skipping what doesn't read as one; nil
    /// when `key` isn't given.
    public func numbers(_ key: String, separator: Character = ",", release: [Double]? = nil) -> [Double]? {
        guard isEnabled else { return release }
        return defaults.string(forKey: key).map { Self.split($0, separator: separator).compactMap(Double.init) }
    }

    /// `"1376x1032"` as a size.
    public func size(_ key: String, release: CGSize? = nil) -> CGSize? {
        guard isEnabled else { return release }
        let parts = defaults.string(forKey: key)?.split(separator: "x").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    /// `"1/30"` or `"0.033"` as a positive number.
    public func fraction(_ key: String, release: Double? = nil) -> Double? {
        guard isEnabled else { return release }
        guard let value = defaults.string(forKey: key) else { return nil }
        let parts = value.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let result = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : parts.count == 1 ? parts[0] : 0
        return result > 0 ? result : nil
    }

    static func split(_ text: String, separator: Character) -> [String] {
        text.split(separator: separator).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
