import Foundation

/// A game's in-app purchases: what's owned and when it was bought, prices,
/// buying and restoring, and consumables handed to the game.
///
/// What's owned (bought, or free where the player shops) is cached in user
/// defaults, so locks are right at launch and offline, before the store has
/// answered: the cache stands until the backend says it knows
/// (`knowsOwnedProducts`, `knowsFreeProducts`). Simulated purchases are
/// never cached, so a debug build's grants don't outlive it. The earliest purchase date the store reports for each product
/// is kept, as is when this device first saw it owned, so a game can grant
/// something to whoever owned a product by a date (`owned(_:by:)`) even
/// where the store gives no date (free there, or simulated).
///
/// Behind it is a `BillingBackend`: `StoreKitBilling` on Apple,
/// `PlayBilling` on Android (`PlayBilling(channel:products:)`),
/// `SimulatedBilling` for a debug build's simulated purchases, `NoBilling`
/// with no store at all.
public final class StoreManager {
    /// Posted whenever prices or purchases change.
    public static let didChange = Notification.Name("StoreManager.didChange")

    public struct Configuration {
        public var products: [StoreProduct]
        /// A price to show before the store has said one (a debug preview).
        public var previewPrice: String?
        /// Hands the game a consumable bought: the product and how many.
        public var deliver: ((_ productID: String, _ quantity: Int) -> Void)?
        /// Prefixes the user defaults keys the manager keeps.
        public var keyPrefix: String
        public var defaults: UserDefaults
        /// The device's clock, for when a product was first seen owned.
        public var now: () -> Date

        public init(
            products: [StoreProduct],
            previewPrice: String? = nil,
            deliver: ((_ productID: String, _ quantity: Int) -> Void)? = nil,
            keyPrefix: String = "store.",
            defaults: UserDefaults = .standard,
            now: @escaping () -> Date = Date.init
        ) {
            self.products = products
            self.previewPrice = previewPrice
            self.deliver = deliver
            self.keyPrefix = keyPrefix
            self.defaults = defaults
            self.now = now
        }
    }

    /// What the manager knows of one product's ownership.
    public struct Ownership: Equatable, Sendable {
        /// Bought, or free where the player shops.
        public var isOwned: Bool
        public var isFree: Bool
        /// When it was first bought, by the store's clock.
        public var purchaseDate: Date?
        /// When this device first saw it owned, by the device's clock.
        public var firstSeenOwned: Date?

        /// The purchase date, else when it was first seen owned.
        public var ownedSince: Date? { purchaseDate ?? firstSeenOwned }
    }

    public let configuration: Configuration
    /// Where purchases go. Set before `start`.
    public var billing: BillingBackend

    private var owned: Set<String>
    private var free: Set<String>
    private var purchaseDates: [String: Date]
    private var firstSeenOwned: [String: Date]
    private var hasStarted = false
    private var priceWaiters: [CheckedContinuation<Void, Never>] = []

    public init(configuration: Configuration, billing: BillingBackend? = nil) {
        self.configuration = configuration
        self.billing = billing ?? Self.platformBilling(configuration.products)
        let defaults = configuration.defaults
        let key = Key(prefix: configuration.keyPrefix)
        owned = Set(defaults.stringArray(forKey: key.owned) ?? [])
        free = Set(defaults.stringArray(forKey: key.free) ?? [])
        purchaseDates = defaults.dictionary(forKey: key.purchaseDates) as? [String: Date] ?? [:]
        firstSeenOwned = defaults.dictionary(forKey: key.firstSeenOwned) as? [String: Date] ?? [:]
    }

    /// Loads prices and purchases, and keeps listening for changes made
    /// elsewhere (another device, a refund, a payment approved later).
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if let deliver = configuration.deliver {
            billing.deliver = deliver
        }
        billing.start { [weak self] in
            self?.backendChanged()
        }
        backendChanged()
    }

    // MARK: - Ownership

    /// Products owned: bought, or free where the player shops.
    public var ownedProducts: Set<String> { owned.union(free) }

    public func owns(_ productID: String) -> Bool {
        ownedProducts.contains(productID)
    }

    public func isFree(_ productID: String) -> Bool {
        free.contains(productID)
    }

    public func ownership(of productID: String) -> Ownership {
        Ownership(
            isOwned: owns(productID),
            isFree: isFree(productID),
            purchaseDate: purchaseDates[productID],
            firstSeenOwned: firstSeenOwned[productID]
        )
    }

    /// Whether `productID` is owned and was by `deadline`: bought by then,
    /// or, with no purchase date, seen owned here by then. A launch offer
    /// kept for whoever bought in time is this.
    public func owned(_ productID: String, by deadline: Date) -> Bool {
        let ownership = ownership(of: productID)
        guard ownership.isOwned, let since = ownership.ownedSince else { return false }
        return since <= deadline
    }

    // MARK: - Prices

    /// A product's price in the player's currency once the store has said,
    /// else the preview price.
    public func price(of productID: String) -> String? {
        billing.price(of: productID) ?? configuration.previewPrice
    }

    /// Whether the store has said every product's price.
    public var hasAllPrices: Bool {
        configuration.products.allSatisfy { billing.price(of: $0.id) != nil }
    }

    /// Waits until the store has said every price, or `timeout` seconds.
    public func waitForPrices(timeout: TimeInterval) async {
        guard !hasAllPrices else { return }
        await withCheckedContinuation { continuation in
            priceWaiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                self?.finishWaiting()
            }
        }
    }

    // MARK: - Buying

    /// Buys `productID`. A consumable is delivered before this returns
    /// `.purchased`, or, held until `deliver` is set, once it is.
    public func purchase(_ productID: String) async -> BillingResult {
        let result = await billing.purchase(productID)
        backendChanged()
        return result
    }

    /// Asks the store to hand back what the player already owns (and any
    /// consumable bought but not yet delivered). Returns whether anything
    /// is owned afterwards.
    @discardableResult
    public func restore() async -> Bool {
        _ = await billing.restore()
        backendChanged()
        return !ownedProducts.isEmpty
    }

    // MARK: - Keeping

    private struct Key {
        let owned: String
        let free: String
        let purchaseDates: String
        let firstSeenOwned: String

        init(prefix: String) {
            owned = prefix + "ownedProducts"
            free = prefix + "freeProducts"
            purchaseDates = prefix + "purchaseDates"
            firstSeenOwned = prefix + "firstSeenOwned"
        }
    }

    /// Takes whatever the backend now reports, keeps it and tells the game.
    /// Before the backend knows, only what it adds (a purchase) is taken, and
    /// the cache is left as it is.
    private func backendChanged() {
        let defaults = configuration.defaults
        let key = Key(prefix: configuration.keyPrefix)
        let consumables = configuration.products.consumableIDs
        let caches = !(billing is SimulatedBilling)
        let reported = billing.ownedProducts.subtracting(consumables)
        if billing.knowsOwnedProducts {
            if reported != owned {
                owned = reported
                if caches { defaults.set(reported.sorted(), forKey: key.owned) }
            }
        } else {
            owned.formUnion(reported)
        }
        let reportedFree = billing.freeProducts.subtracting(consumables)
        if billing.knowsFreeProducts, reportedFree != free {
            free = reportedFree
            if caches { defaults.set(reportedFree.sorted(), forKey: key.free) }
        }
        // The earliest date wins, so a later report never moves it on.
        var dates = purchaseDates
        for (id, date) in billing.purchaseDates where !consumables.contains(id) {
            dates[id] = min(dates[id] ?? date, date)
        }
        if dates != purchaseDates {
            purchaseDates = dates
            defaults.set(dates, forKey: key.purchaseDates)
        }
        let unseen = ownedProducts.filter { firstSeenOwned[$0] == nil }
        if !unseen.isEmpty {
            let now = configuration.now()
            for id in unseen {
                firstSeenOwned[id] = now
            }
            defaults.set(firstSeenOwned, forKey: key.firstSeenOwned)
        }
        if hasAllPrices { finishWaiting() }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func finishWaiting() {
        let waiters = priceWaiters
        priceWaiters = []
        waiters.forEach { $0.resume() }
    }

    private static func platformBilling(_ products: [StoreProduct]) -> BillingBackend {
        #if SPRITEKIT_SHIM
        NoBilling()
        #else
        StoreKitBilling(products: products)
        #endif
    }
}
