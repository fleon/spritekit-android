import Foundation

/// Buying the full game, with StoreKit taken out from under `StoreManager`.
///
/// What a game keeps about what's owned is its own (Switchlings':
/// `Entitlements`, in `SwitchlingsStore`). Behind it sits one of three backends: `PlayBilling` (Google Play, through
/// `PlatformChannel`), `SimulatedBilling` (the Apple build's
/// `-SimulatePurchases`: granted locally, no money moves) or `NoBilling`
/// (no store at all, as on a host test).
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
    /// When each owned product was first bought, where the service says:
    /// what the launch event's rule reads, in place of `Date()`.
    var purchaseDates: [String: Date] { get }
}

public extension BillingBackend {
    var purchaseDates: [String: Date] { [:] }
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
