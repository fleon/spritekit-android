import Foundation

/// Buying a game's products, with StoreKit taken out from under its store
/// code.
///
/// What a game keeps about what's owned is its own (Platform's
/// `StoreManager` keeps it for a game that uses it). Behind it sits one of
/// these backends: `StoreKitBilling` on Apple (in Platform's
/// `PlatformStore`), `PlayBilling` (Google Play, through `PlatformChannel`),
/// `SimulatedBilling` (a debug build's simulated purchases: granted
/// locally, no money moves) or `NoBilling` (no store at all, as on a host
/// test).
///
/// A product is owned (a non-consumable) or used up (a consumable): a
/// consumable bought is never owned, but handed to `deliver` once.
public protocol BillingBackend: AnyObject {
    /// The first product's price in the player's currency, once it is
    /// known: for a game that sells one product.
    var displayPrice: String? { get }
    /// A product's price in the player's currency, once it is known.
    func price(of productID: String) -> String?
    /// Hands the game each consumable bought: the product and how many.
    /// Until it is set, a consumable bought is held, neither delivered nor
    /// used up, so nothing is lost before the game can take it.
    var deliver: ((_ productID: String, _ quantity: Int) -> Void)? { get set }
    /// Products the player owns, as the service reports them.
    var ownedProducts: Set<String> { get }
    /// Products that cost nothing where the player shops.
    var freeProducts: Set<String> { get }
    /// Whether `ownedProducts` is the service's answer yet. Until it is, a
    /// game keeps what it last knew, so locks are right at launch and
    /// offline.
    var knowsOwnedProducts: Bool { get }
    /// Whether `freeProducts` is the service's answer yet (the prices have
    /// loaded once).
    var knowsFreeProducts: Bool { get }
    /// Loads prices and entitlements. Calls `changed` whenever either moves.
    func start(changed: @escaping () -> Void)
    /// Asks the store for the prices again, unless an answer is already on
    /// its way. A first load that failed (offline at launch) is never tried
    /// again by itself, so a game about to show prices calls this
    /// (`StoreManager.waitForPrices` does). Nothing before `start`.
    func reloadPrices()
    func purchase(_ productID: String) async -> BillingResult
    /// Asks the service to hand back what the player already owns.
    func restore() async -> Bool
    /// When each owned product was first bought, where the service says
    /// (StoreKit's `originalPurchaseDate`).
    var purchaseDates: [String: Date] { get }
}

public extension BillingBackend {
    var purchaseDates: [String: Date] { [:] }

    /// A backend whose prices are known at once, or never.
    func reloadPrices() {}

    /// A backend that answers at once.
    var knowsOwnedProducts: Bool { true }
    var knowsFreeProducts: Bool { true }

    /// A backend that sells one product, or keeps one price for all.
    func price(of productID: String) -> String? { displayPrice }

    /// A backend with no consumables.
    var deliver: ((_ productID: String, _ quantity: Int) -> Void)? {
        get { nil }
        set {}
    }
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
/// it across launches: a game's simulated purchases, as it may offer them on
/// Apple, with somewhere to put the result. A consumable is delivered, one
/// at a time, and never kept.
public final class SimulatedBilling: BillingBackend {
    private enum Key {
        static let simulated = "store.simulatedProducts"
    }

    /// The price a simulated product shows, as a game previewing prices
    /// without a store shows it. A game sets its own.
    nonisolated(unsafe) public static var previewPrice = "$0.99"

    private let defaults: UserDefaults
    private var changed: (() -> Void)?
    private var granted: Set<String>
    /// Consumables bought before the game could take them.
    private var held: [String] = []

    /// Products bought to be used up rather than owned.
    public let consumables: Set<String>
    public var deliver: ((_ productID: String, _ quantity: Int) -> Void)? {
        didSet { deliverHeld() }
    }

    public var displayPrice: String? { Self.previewPrice }
    public func price(of productID: String) -> String? { Self.previewPrice }
    public var ownedProducts: Set<String> { granted }
    public var freeProducts: Set<String> { [] }

    public init(defaults: UserDefaults = .standard, consumables: Set<String> = []) {
        self.defaults = defaults
        self.consumables = consumables
        granted = Set(defaults.stringArray(forKey: Key.simulated) ?? []).subtracting(consumables)
    }

    public func start(changed: @escaping () -> Void) {
        self.changed = changed
    }

    public func purchase(_ productID: String) async -> BillingResult {
        if consumables.contains(productID) {
            held.append(productID)
            deliverHeld()
            return .purchased
        }
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

    /// Takes the simulated purchases back, so what's free can be walked
    /// through again without clearing the app's data.
    public func forgetPurchases() {
        granted = []
        defaults.removeObject(forKey: Key.simulated)
        changed?()
    }

    private func deliverHeld() {
        guard let deliver else { return }
        let bought = held
        held = []
        for productID in bought { deliver(productID, 1) }
    }
}
