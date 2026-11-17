import Foundation

/// Who the app is, for everything in the runtime that names it: Apple's
/// `CFBundleName` and `CFBundleIdentifier`, the logcat tag, the window's
/// title, the `debug.<key>.*` system properties, the Google Play page and
/// the Play Games saved game.
///
/// The game's entry sets it before anything else runs
/// (`Shell.start(app:game:…)`); the default names no game.
public struct AppIdentity: Sendable, Equatable {
    /// The app's name: `CFBundleName`, the logcat tag and the window title.
    public var name: String
    /// The bundle identifier, which is also the Play package name (a game
    /// keeps the same ID in both stores, so one product ID serves both).
    public var bundleIdentifier: String
    /// A short lowercase key: `debug.<key>.*` properties and the saved game's
    /// name, `<key>-progress`.
    public var key: String

    public init(name: String, bundleIdentifier: String, key: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.key = key
    }

    /// The app this process is. Set once, at launch, before any other thread
    /// starts.
    nonisolated(unsafe) public static var current = AppIdentity(name: "SpriteKit", bundleIdentifier: "", key: "spritekit")
}
