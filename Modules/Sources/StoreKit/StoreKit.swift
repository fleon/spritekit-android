// Stands in for StoreKit on Android.
//
// Purchases have a game-side body of their own (Switchlings'
// `Platform/StoreManager.swift`, on `PlayBilling`). What is here is what a
// game calls straight into StoreKit for:
//
// - the App Store storefront, which Switchlings' `SolutionShare` asks to link
//   a shared film to the right country's store. Play has no App Store
//   storefront, so it answers none; Android's `ShareSheet` then swaps the
//   App Store link for the game's Google Play page (`PlayStorePage`);
// - a rating request (`SKStoreReviewController`, `AppStore.requestReview`),
//   which goes to Play In-App Review (`StoreReview` in PlatformShim).
@_exported import SpriteKitShim
import PlatformShim

public struct Storefront: Sendable {
    public let countryCode: String

    public static var current: Storefront? {
        get async { nil }
    }
}

/// Asks for a rating: Play In-App Review's card, if Play chooses to show it.
public final class SKStoreReviewController {
    private init() {}

    public static func requestReview(in windowScene: UIWindowScene) {
        StoreReview.request()
    }

    public static func requestReview() {
        StoreReview.request()
    }
}

/// StoreKit 2's name for the same request.
public enum AppStore {
    @MainActor
    public static func requestReview(in windowScene: UIWindowScene) {
        StoreReview.request()
    }
}
