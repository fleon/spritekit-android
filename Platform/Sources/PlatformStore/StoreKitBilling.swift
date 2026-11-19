#if !SPRITEKIT_SHIM
import Foundation
import StoreKit
import UIKit

/// StoreKit 2 behind `BillingBackend`: products and their prices, buying,
/// restoring, and what the player owns.
///
///   - **Owned** is `Transaction.currentEntitlements` (verified, not
///     revoked), kept up to date by `Transaction.updates`: purchases made on
///     other devices, approved later (Ask to Buy) or refunded. A product
///     priced at nothing where the player shops is free.
///   - **Consumables** are never owned. Each transaction is handed to
///     `deliver` once, its ID written down first so a game that stops
///     before it is finished never grants it twice, then finished. Until
///     `deliver` is set they stay unfinished, and StoreKit hands them back;
///     with `confirm` and no `deliver`, the server's credit is the delivery.
///   - **Confirming** (`confirm`): a game whose server credits purchases
///     sees each transaction, verified or not, before it is finished; one
///     it doesn't confirm stays unfinished and is tried again at the next
///     launch, and its purchase ends `.failed`.
///   - **Promoted purchases**: one started on the App Store's product page
///     (`PurchaseIntent`, iPhone, iPad and Mac) is bought once the app is in
///     front; a promotion (`promoted`) is hidden on a device that owns its
///     product and shown again if a refund takes it away (iPhone and iPad).
public final class StoreKitBilling: BillingBackend {
    /// A transaction as `confirm` sees it.
    public struct Purchase: Sendable {
        public var productID: String
        public var transactionID: UInt64
        public var quantity: Int
        public var purchaseDate: Date
        public var originalPurchaseDate: Date
        /// Whether StoreKit verified it on the device.
        public var isVerified: Bool
        /// StoreKit's signed transaction, for a server to check.
        public var jwsRepresentation: String
    }

    private static let deliveredKey = "store.deliveredTransactions"

    private let productIDs: [String]
    private let consumables: Set<String>
    private let promoted: Set<String>
    private let defaults: UserDefaults
    private var products: [String: Product] = [:]
    private var owned: Set<String> = []
    private var free: Set<String> = []
    private var dates: [String: Date] = [:]
    private var changed: (() -> Void)?
    /// The products' load under way, so a reload and a purchase share it.
    private var productLoad: Task<Void, Never>?
    private var updates: Task<Void, Never>?
    private var intents: Task<Void, Never>?
    /// Transactions being handled, so a purchase and a listener never both
    /// handle one.
    private var handling: Set<UInt64> = []
    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// What this device last asked the App Store to do with each promotion.
    private var promotionHidden: [String: Bool] = [:]
    #endif

    /// Runs before each transaction is finished; false leaves it unfinished.
    public var confirm: ((Purchase) async -> Bool)?

    public var deliver: ((_ productID: String, _ quantity: Int) -> Void)? {
        didSet {
            guard deliver != nil, changed != nil else { return }
            Task { await handleUnfinished() }
        }
    }

    public init(products: [StoreProduct], promoted: Set<String> = [], defaults: UserDefaults = .standard) {
        productIDs = products.ids
        consumables = products.consumableIDs
        self.promoted = promoted
        self.defaults = defaults
    }

    /// StoreKit's product, once loaded, for what the protocol doesn't carry.
    public func product(_ productID: String) -> Product? {
        products[productID]
    }

    // MARK: - BillingBackend

    public var displayPrice: String? { productIDs.lazy.compactMap { self.products[$0]?.displayPrice }.first }

    public func price(of productID: String) -> String? { products[productID]?.displayPrice }

    public var ownedProducts: Set<String> { owned }
    public var freeProducts: Set<String> { free }
    /// After the first pass over `Transaction.currentEntitlements`. Until
    /// then a promotion is left as it is, too, rather than shown and then
    /// hidden again.
    public private(set) var knowsOwnedProducts = false
    /// After the products have loaded once.
    public private(set) var knowsFreeProducts = false
    public var purchaseDates: [String: Date] { dates }

    public func start(changed: @escaping () -> Void) {
        guard self.changed == nil else { return }
        self.changed = changed
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                _ = await self?.handle(result)
            }
        }
        #if os(iOS)
        if #available(iOS 16.4, macCatalyst 16.4, *) {
            intents = Task { [weak self] in
                for await intent in PurchaseIntent.intents {
                    await self?.buy(intent.product)
                }
            }
        }
        #endif
        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshEntitlements()
            await self?.handleUnfinished()
        }
    }

    public func purchase(_ productID: String) async -> BillingResult {
        if products[productID] == nil { await loadProducts() }
        guard let product = products[productID] else { return .failed }
        do {
            switch try await product.purchase() {
            case let .success(verification):
                return await handle(verification)
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed
            }
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            return .failed
        }
    }

    /// Syncs with the App Store (which may ask the player to sign in) and
    /// reloads what's owned and what waits to be delivered.
    public func restore() async -> Bool {
        try? await AppStore.sync()
        await refreshEntitlements()
        await handleUnfinished()
        return !owned.isEmpty
    }

    // MARK: - Transactions

    public func reloadPrices() {
        guard changed != nil, productIDs.contains(where: { products[$0] == nil }) else { return }
        Task { [weak self] in await self?.loadProducts() }
    }

    /// Loads the products, or waits for the load under way. One that fails
    /// (offline) leaves the next call to try again.
    private func loadProducts() async {
        if let productLoad { return await productLoad.value }
        let load = Task { [weak self] in
            guard let self else { return }
            await self.fetchProducts()
        }
        productLoad = load
        await load.value
        productLoad = nil
    }

    private func fetchProducts() async {
        guard let loaded = try? await Product.products(for: productIDs) else { return }
        for product in loaded {
            products[product.id] = product
        }
        free = Set(loaded.filter { $0.price == 0 && !consumables.contains($0.id) }.map(\.id))
        knowsFreeProducts = true
        updatePromotions()
        changed?()
    }

    private func refreshEntitlements() async {
        var current: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result, transaction.revocationDate == nil,
                  !consumables.contains(transaction.productID)
            else { continue }
            current.insert(transaction.productID)
            noteBought(transaction)
        }
        // The first answer reaches the game even when it is "nothing".
        let wasKnown = knowsOwnedProducts
        knowsOwnedProducts = true
        if !wasKnown, current == owned { changed?() }
        setOwned(current)
        updatePromotions()
    }

    private func handleUnfinished() async {
        for await result in Transaction.unfinished {
            _ = await handle(result)
        }
    }

    /// Grants or delivers a transaction (or takes back a refunded one) and
    /// finishes it.
    private func handle(_ result: VerificationResult<Transaction>) async -> BillingResult {
        let transaction = result.unsafePayloadValue
        var isVerified = false
        if case .verified = result { isVerified = true }
        guard isVerified || confirm != nil else { return .failed }
        guard handling.insert(transaction.id).inserted else { return .purchased }
        defer { handling.remove(transaction.id) }
        let productID = transaction.productID

        if transaction.revocationDate != nil {
            setOwned(owned.subtracting([productID]))
            await transaction.finish()
            return .failed
        }
        if let confirm {
            let purchase = Purchase(
                productID: productID,
                transactionID: transaction.id,
                quantity: transaction.purchasedQuantity,
                purchaseDate: transaction.purchaseDate,
                originalPurchaseDate: transaction.originalPurchaseDate,
                isVerified: isVerified,
                jwsRepresentation: result.jwsRepresentation
            )
            guard await confirm(purchase) else { return .failed }
        }
        if consumables.contains(productID) {
            // Held, unfinished, until the game can take it.
            guard deliver != nil || confirm != nil else { return .purchased }
            let id = String(transaction.id)
            if let deliver, !delivered.contains(id) {
                delivered.insert(id)
                deliver(productID, max(1, transaction.purchasedQuantity))
            }
            await transaction.finish()
            delivered.remove(id)
            return .purchased
        }
        noteBought(transaction)
        setOwned(owned.union([productID]))
        await transaction.finish()
        return .purchased
    }

    /// Consumable transactions delivered and not yet known finished: kept
    /// across launches so none is delivered twice.
    private var delivered: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.deliveredKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.deliveredKey) }
    }

    private func noteBought(_ transaction: Transaction) {
        let date = transaction.originalPurchaseDate
        dates[transaction.productID] = min(dates[transaction.productID] ?? date, date)
    }

    private func setOwned(_ ids: Set<String>) {
        guard ids != owned else { return }
        owned = ids
        updatePromotions()
        changed?()
    }

    #if os(iOS)
    /// A purchase started on the App Store's product page: StoreKit's sheet
    /// shows once the app is in front.
    private func buy(_ product: Product) async {
        guard productIDs.contains(product.id) else { return }
        if UIApplication.shared.applicationState != .active {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                break
            }
        }
        products[product.id] = product
        _ = await purchase(product.id)
        changed?()
    }
    #endif

    /// Hides each promotion on a device that owns its product, and shows it
    /// again if that changes. iPhone and iPad only: the Mac can't hide one.
    private func updatePromotions() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard #available(iOS 18.0, *), knowsOwnedProducts else { return }
        for id in promoted {
            let hidden = owned.union(free).contains(id)
            guard promotionHidden[id] != hidden else { continue }
            promotionHidden[id] = hidden
            Task {
                try? await Product.PromotionInfo.updateProductVisibility(hidden ? .hidden : .appStoreConnectDefault, for: id)
            }
        }
        #endif
    }
}
#endif
