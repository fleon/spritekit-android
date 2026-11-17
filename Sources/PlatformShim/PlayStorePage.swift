import Foundation
import SpriteKitShim

/// The game's page on Google Play, which Android's shares link in place of
/// the App Store's. A game builds its App Store link itself, in code that
/// compiles unchanged, so the share sheet swaps it for this as it sorts the
/// items (`ShareRequest`).
public enum PlayStorePage {
    /// The release app's ID (`AppIdentity`): a debug build's suffix never
    /// has a page of its own.
    public static var packageName: String { AppIdentity.current.bundleIdentifier }

    /// The page, in `language` (a BCP 47 code) when given.
    public static func url(language: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "play.google.com"
        components.path = "/store/apps/details"
        components.queryItems = [URLQueryItem(name: "id", value: packageName)]
        if let language { components.queryItems?.append(URLQueryItem(name: "hl", value: hl(for: language))) }
        // Built from constants, so it's always a valid URL.
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// Whether `url` is an App Store page, which means nothing on Android.
    public static func isAppStorePage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "apps.apple.com" || host == "itunes.apple.com"
    }

    /// Play's name for a language where it differs from the game's
    /// (script subtags become regions, Latin American Spanish is `es-419`).
    static func hl(for language: String) -> String {
        switch language {
        case "zh-Hans": "zh-CN"
        case "zh-Hant": "zh-TW"
        case "es-MX": "es-419"
        default: language
        }
    }
}
