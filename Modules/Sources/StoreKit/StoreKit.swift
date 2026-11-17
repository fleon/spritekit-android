// Stands in for StoreKit on Android, as far as the App Store storefront
// goes: a game that links to the right country's store asks for it. Play has
// no App Store storefront, so it answers none, and a game can swap an App
// Store link for its Google Play page (`PlayStorePage`). Purchases go through
// PlatformShim's `BillingBackend` instead.
@_exported import SpriteKitShim

public struct Storefront: Sendable {
    public let countryCode: String

    public static var current: Storefront? {
        get async { nil }
    }
}
