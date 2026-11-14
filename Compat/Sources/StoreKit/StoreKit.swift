// Stands in for StoreKit on Android. `StoreManager` has an Android body of
// its own (Platform/StoreManager.swift); the one other file that imports
// StoreKit, `SolutionShare`, asks it for the App Store storefront to link a
// shared film to the right country's store. Play has no App Store
// storefront, so it answers none; Android's `ShareSheet` then swaps the
// App Store link for the game's Google Play page (`PlayStorePage`).
@_exported import SpriteKitShim

public struct Storefront: Sendable {
    public let countryCode: String

    public static var current: Storefront? {
        get async { nil }
    }
}
