import Foundation

/// Buying the full game, with StoreKit taken out from under `StoreManager`.
///
/// ## What is real here and what is not
///
/// Real: the entitlement — whether the full game is owned — is kept on the
/// device, read before anything asks a service, and settable. That is what
/// the rest of the game reads through `StoreManager.isUnlocked(_:)`, so
/// every lock, padlock, offer and secret-world rule behaves correctly.
///
/// Not real: there is no Play Billing. `com.fleon.switchlings.fullgame` has
/// not been created in the Play Console, so there is no product to query, no
/// price to show and nothing to buy. `Tools/Store/apply_iap_prices.py` does
/// not carry across either — Play has its own territories and price points.
/// `PlayBilling` is therefore a name for the gap, not an implementation:
/// `Tools/Play/PLAY-CONSOLE-SETUP.md` §6 is what has to happen first.
///
/// What ships meanwhile is `SimulatedBilling`, which is the Apple build's own
/// `-SimulatePurchases` path: a purchase succeeds at once, locally, at a
/// stated price. That is far more useful than untested JNI — the whole
/// unlock flow, both offers and the launch-event rule can be walked through
/// on a device — and it cannot be mistaken for a real purchase, because no
/// money moves and nothing leaves the device.
public protocol BillingBackend: AnyObject {
    /// The product's price in the player's currency, once it is known.
    var displayPrice: String? { get }
    /// Products the player owns, as the service reports them.
    var ownedProducts: Set<String> { get }
    /// Products that cost nothing where the player shops (China mainland).
    var freeProducts: Set<String> { get }
    /// Loads prices and entitlements. Calls `changed` whenever either moves.
    func start(changed: @escaping () -> Void)
    func purchase(_ productID: String) async -> BillingResult
    /// Asks the service to hand back what the player already owns.
    func restore() async -> Bool
}

public enum BillingResult: Sendable {
    case purchased
    case pending
    case cancelled
    case failed
}

/// No billing service: nothing is owned, nothing has a price, and a purchase
/// fails rather than quietly succeeding. What an Android build uses when
/// purchases are not simulated — honest about having no store behind it.
public final class NoBilling: BillingBackend {
    public var displayPrice: String? { nil }
    public var ownedProducts: Set<String> { [] }
    public var freeProducts: Set<String> { [] }

    public init() {}

    public func start(changed: @escaping () -> Void) {}
    public func purchase(_ productID: String) async -> BillingResult { .failed }
    public func restore() async -> Bool { false }
}

/// Grants the purchase on this device at once, without a service, and keeps
/// it across launches. The Apple build's `-SimulatePurchases` with somewhere
/// to put the result.
public final class SimulatedBilling: BillingBackend {
    private enum Key {
        static let simulated = "store.simulatedProducts"
    }

    /// The full game's US price, as `-PreviewPrices` shows it when StoreKit
    /// has no products.
    public static let previewPrice = "$6.99"

    private let defaults: UserDefaults
    private var changed: (() -> Void)?
    private var granted: Set<String>

    public var displayPrice: String? { Self.previewPrice }
    public var ownedProducts: Set<String> { granted }
    public var freeProducts: Set<String> { [] }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        granted = Set(defaults.stringArray(forKey: Key.simulated) ?? [])
    }

    public func start(changed: @escaping () -> Void) {
        self.changed = changed
    }

    public func purchase(_ productID: String) async -> BillingResult {
        guard !granted.contains(productID) else { return .purchased }
        granted.insert(productID)
        defaults.set(granted.sorted(), forKey: Key.simulated)
        changed?()
        return .purchased
    }

    public func restore() async -> Bool {
        changed?()
        return !granted.isEmpty
    }

    /// Takes the simulated purchase back, so the free game can be walked
    /// through again without clearing the app's data.
    public func forgetPurchases() {
        granted = []
        defaults.removeObject(forKey: Key.simulated)
        changed?()
    }
}

/// What the game keeps about the full game once a backend has spoken: what
/// is owned, when it was bought, and whether that was in time to keep the
/// secret worlds.
///
/// This is the half of `StoreManager` that has nothing to do with any store,
/// so it is here, tested on the host, rather than inside a body nobody can
/// run.
public struct Entitlements {
    public enum Key {
        public static let owned = "store.ownedProducts"
        public static let free = "store.freeProducts"
        /// When the full game was first bought.
        public static let boughtAt = "store.fullGameBoughtAt"
        /// Seen owned, with no purchase date, during the launch event.
        public static let ownedInEvent = "store.ownedDuringLaunchEvent"
    }

    public static let fullGameID = "com.fleon.switchlings.fullgame"

    /// When the launch event ends, and with it the chance to keep the secret
    /// worlds: as its App Store In-App Event does, 14 February 2027 at
    /// midnight, GMT+1. The same instant on both platforms, deliberately —
    /// a player who owns the game on one keeps the worlds on the other.
    public static let launchEventEnd = DateComponents(
        calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 3600), year: 2027, month: 2, day: 14
    ).date ?? .distantFuture

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var owned: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.owned) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Key.owned) }
    }

    public var free: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.free) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Key.free) }
    }

    /// Keeps when the full game was first bought; the earliest wins, so a
    /// later report cannot push a player out of the launch event.
    public func noteBought(at date: Date) {
        let earlier = (defaults.object(forKey: Key.boughtAt) as? Date).map { min($0, date) }
        defaults.set(earlier ?? date, forKey: Key.boughtAt)
    }

    public var boughtAt: Date? { defaults.object(forKey: Key.boughtAt) as? Date }

    /// Owned with no purchase date while the event runs (free here, or
    /// simulated): the secret worlds are kept.
    public func noteOwnedDuringEvent(owns: Bool, eventRunning: Bool) {
        guard owns, eventRunning, boughtAt == nil else { return }
        defaults.set(true, forKey: Key.ownedInEvent)
    }

    public var wasOwnedDuringEvent: Bool { defaults.bool(forKey: Key.ownedInEvent) }

    /// Whether the secret worlds are the player's for good.
    public func keepsSecretWorlds(owns: Bool) -> Bool {
        guard owns else { return false }
        if let boughtAt { return boughtAt <= Self.launchEventEnd }
        return wasOwnedDuringEvent
    }
}
