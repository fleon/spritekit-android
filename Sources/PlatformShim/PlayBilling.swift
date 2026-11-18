import Foundation

/// Google Play Billing behind `BillingBackend`: a product's price, buying it,
/// acknowledging it, and what the player owns.
///
/// The Billing Library itself is in Java (`PlayBilling.java`), which only
/// reports. The decisions are here, where the host tests reach them:
///
///   - **Owned** is what Play's last successful query or purchase update
///     says is `PURCHASED`. A query that fails (no network) changes nothing,
///     so going offline never reads as a refund; a query that succeeds
///     without the product does take it away (a refund or a revoked family
///     share), as StoreKit's revocations do on Apple.
///   - **A purchase** ends `.purchased`, `.pending` (cash at a shop, a
///     parent's approval: it completes later, by an update or the next
///     query, and the game grants it then), `.cancelled` or `.failed`. Play's
///     "already owned" is taken as a restore: the query that follows decides.
///   - **Acknowledgement**: every purchased, unacknowledged purchase is
///     acknowledged once a session (Play refunds one left unacknowledged for
///     three days); one that fails is tried again after the next query.
///   - **When it was bought** is Play's `purchaseTime`, which stands in for
///     StoreKit's `originalPurchaseDate`.
///   - **Consumables** (StoreKit's consumable products) are never owned. A
///     purchased one is handed to `deliver` once, its token written down
///     (`deliveredKey`) before it's consumed, so a game that stops between
///     the two never grants it twice; then it's consumed, and Play lets the
///     player buy it again. Until the game sets `deliver`, nothing is
///     delivered or consumed, so a query answered before then loses
///     nothing. A token Play has said is consumed is never delivered again
///     this session, though a query already under way still lists it. A
///     consume that fails is tried again after the next query.
///   - **Confirming** (`confirm`), as StoreKit's backend does it: a game
///     whose server credits purchases sees each purchased one before it is
///     acknowledged or consumed, and nothing is until `confirm` says yes. One
///     Play already holds acknowledged is settled and never offered again. A
///     purchase it doesn't confirm is left as it is, its flow ends
///     `.failed`, and it's offered again after the next query (at launch,
///     on resume, on restore); Play refunds one still unacknowledged after
///     three days, which is logged. With `confirm` and no `deliver`, the
///     server's credit is a consumable's delivery.
///   - **Who consumes**: a consumable the server consumes itself (the
///     `serverConsumed` products), once confirmed, is neither consumed nor
///     acknowledged here, since the server's consume acknowledges it; it's
///     done for this session, and gone once Play stops listing it.
public final class PlayBilling: BillingBackend {
    public enum State: String, Sendable {
        case purchased
        case pending
        case unspecified
    }

    public struct Purchase: Equatable, Sendable {
        public var products: [String]
        public var state: State
        public var token: String
        public var time: Date
        public var acknowledged: Bool
        /// How many were bought at once (Play's multi-quantity purchases).
        public var quantity: Int
        /// Play's order ID (`GPA.…`); none for a promotional purchase.
        public var orderID: String?
        /// Play's purchase JSON and its signature, for a server to check.
        public var originalJSON: String?
        public var signature: String?

        public init(
            products: [String], state: State, token: String, time: Date, acknowledged: Bool, quantity: Int = 1,
            orderID: String? = nil, originalJSON: String? = nil, signature: String? = nil
        ) {
            self.products = products
            self.state = state
            self.token = token
            self.time = time
            self.acknowledged = acknowledged
            self.quantity = quantity
            self.orderID = orderID
            self.originalJSON = originalJSON
            self.signature = signature
        }
    }

    /// Where a confirmation that didn't go through is reported.
    nonisolated(unsafe) public static var log: (String) -> Void = { NSLog("%@", $0) }

    private static let service = "billing"

    private let channel: PlatformChannel
    private let productIDs: [String]
    private var prices: [String: String] = [:]
    private var changed: (() -> Void)?
    private var acknowledging: Set<String> = []
    private var purchaseWaiters: [String: [CheckedContinuation<BillingResult, Never>]] = [:]
    private var restoreWaiters: [CheckedContinuation<Bool, Never>] = []
    /// Purchases Play said were already owned: the next query settles them.
    private var awaitingOwned: Set<String> = []

    /// The purchases Play last reported, by token.
    public private(set) var purchases: [Purchase] = []
    /// Whether a query has answered yet: until then `ownedProducts` holds
    /// only what was bought this session.
    public private(set) var knowsOwnedProducts = false

    /// Products bought to be used up rather than owned.
    public let consumables: Set<String>
    /// Consumables the game's server consumes itself, once it has credited them.
    public let serverConsumed: Set<String>
    /// Runs before each purchased purchase is acknowledged or consumed;
    /// false leaves it as it is, to be offered again after the next query.
    public var confirm: ((Purchase) async -> Bool)? {
        didSet { if confirm != nil { acknowledgeWhatNeedsIt() } }
    }
    /// Tokens `confirm` said yes to, this session.
    private var confirmed: Set<String> = []
    private var confirming: Set<String> = []
    /// Tokens `confirm` said no to, offered again after the next query.
    private var declined: Set<String> = []
    /// Hands the game a consumable bought: the product and how many. Called
    /// once a purchase, before it is consumed (as StoreKit's game grants a
    /// consumable before it finishes the transaction).
    public var deliver: ((_ productID: String, _ quantity: Int) -> Void)? {
        didSet { if deliver != nil { acknowledgeWhatNeedsIt() } }
    }
    private let defaults: UserDefaults
    private var consuming: Set<String> = []
    /// Tokens Play has said are consumed, this session.
    private var consumed: Set<String> = []
    /// The user defaults key of the consumables' tokens already delivered
    /// and not yet known consumed.
    public static let deliveredKey = "billing.deliveredTokens"

    public init(
        channel: PlatformChannel, products: [String], consumables: Set<String> = [], serverConsumed: Set<String> = [],
        defaults: UserDefaults = .standard
    ) {
        self.channel = channel
        productIDs = products
        self.consumables = consumables
        self.serverConsumed = serverConsumed.intersection(consumables)
        self.defaults = defaults
        channel.on(Self.service) { [weak self] event, body in self?.handle(event, body) }
    }

    // MARK: - BillingBackend

    public var displayPrice: String? { productIDs.lazy.compactMap { self.prices[$0] }.first }

    /// A product's localized price, once Play has said it.
    public func price(of productID: String) -> String? { prices[productID] }

    public var ownedProducts: Set<String> {
        Set(purchases.filter { $0.state == .purchased }.flatMap(\.products)).subtracting(consumables)
    }

    /// Nothing is free here: a product priced free in one territory on the
    /// App Store (mainland China, say, where Play isn't offered) has no such
    /// price on Play.
    public var freeProducts: Set<String> { [] }

    /// The earliest purchase time of each product owned.
    public var purchaseDates: [String: Date] {
        var dates: [String: Date] = [:]
        for purchase in purchases where purchase.state == .purchased {
            for product in purchase.products {
                dates[product] = min(dates[product] ?? purchase.time, purchase.time)
            }
        }
        return dates
    }

    /// Products bought but not yet paid for.
    public var pendingProducts: Set<String> {
        Set(purchases.filter { $0.state == .pending }.flatMap(\.products)).subtracting(ownedProducts)
    }

    public func start(changed: @escaping () -> Void) {
        self.changed = changed
        channel.call("billing.start", ["products": productIDs])
    }

    /// On the main actor, as Play's answers are delivered there
    /// (`PlatformBridge`): run off it, as a nonisolated `async` method
    /// does, it called into Java and changed the waiters from a
    /// libdispatch worker while the frame thread handled events.
    @MainActor
    public func purchase(_ productID: String) async -> BillingResult {
        if ownedProducts.contains(productID) { return .purchased }
        return await withCheckedContinuation { continuation in
            let first = purchaseWaiters[productID, default: []].isEmpty
            purchaseWaiters[productID, default: []].append(continuation)
            if first { channel.call("billing.purchase", ["productId": productID]) }
        }
    }

    @MainActor
    public func restore() async -> Bool {
        await withCheckedContinuation { continuation in
            let first = restoreWaiters.isEmpty
            restoreWaiters.append(continuation)
            if first { channel.call("billing.restore") }
        }
    }

    // MARK: - Events

    private func handle(_ event: String, _ body: PlatformChannel.Message) {
        switch event {
        case "product":
            guard let id = body["productId"] as? String, let price = body["price"] as? String else { return }
            prices[id] = price
            changed?()
        case "owned":
            owned(body)
        case "updated":
            updated(body)
        case "acknowledged":
            guard let token = body["token"] as? String else { return }
            if body["code"] as? String == "ok" {
                for index in purchases.indices where purchases[index].token == token {
                    purchases[index].acknowledged = true
                }
            } else {
                // Left in the set, nothing would try again; out of it, the
                // next query does.
                acknowledging.remove(token)
            }
        case "consumed":
            guard let token = body["token"] as? String else { return }
            consuming.remove(token)
            if body["code"] as? String == "ok" {
                consumed.insert(token)
                purchases.removeAll { $0.token == token }
                delivered.remove(token)
            }
        case "unavailable":
            finishRestores(owning: !ownedProducts.isEmpty)
            finishPurchases(.failed)
        default:
            break
        }
    }

    /// A query's answer: every one-time purchase Play holds for the player.
    private func owned(_ body: PlatformChannel.Message) {
        guard body["code"] as? String == "ok" else {
            finishRestores(owning: !ownedProducts.isEmpty)
            for product in awaitingOwned { finishPurchases(of: product, .failed) }
            awaitingOwned = []
            return
        }
        purchases = Self.parse(body).filter { !consumed.contains($0.token) }
        knowsOwnedProducts = true
        declined = []
        acknowledgeWhatNeedsIt()
        let owned = ownedProducts
        let settled = settledProducts
        for product in awaitingOwned where !settled.contains(product) && !awaitingConfirmation.contains(product) {
            finishPurchases(of: product, .failed)
        }
        awaitingOwned = []
        // A purchase still being confirmed finishes when it's confirmed.
        for product in settled { finishPurchases(of: product, .purchased) }
        changed?()
        finishRestores(owning: !owned.isEmpty)
    }

    /// The end of a purchase flow, or a purchase changing while the game runs.
    private func updated(_ body: PlatformChannel.Message) {
        let product = body["productId"] as? String
        switch body["code"] as? String {
        case "ok":
            let reported = Self.parse(body).filter { !consumed.contains($0.token) }
            for purchase in reported {
                if let index = purchases.firstIndex(where: { $0.token == purchase.token }) {
                    purchases[index] = purchase
                } else {
                    purchases.append(purchase)
                }
            }
            acknowledgeWhatNeedsIt()
            for purchase in reported {
                let result: BillingResult? = switch purchase.state {
                // Being confirmed, it finishes when it's confirmed.
                case .purchased: isSettled(purchase) ? .purchased : nil
                case .pending: .pending
                case .unspecified: nil
                }
                if let result {
                    for product in purchase.products { finishPurchases(of: product, result) }
                }
            }
            changed?()
        case "cancelled":
            finish(product, .cancelled)
        case "owned":
            // Bought already (on another device, or before a reinstall):
            // the query decides, and the game grants it if it is so.
            awaitingOwned.formUnion(product.map { [$0] } ?? Array(purchaseWaiters.keys))
            channel.call("billing.restore")
        default:
            finish(product, .failed)
        }
    }

    /// Consumable tokens handed to the game and not yet known consumed:
    /// kept across launches so none is granted twice.
    private var delivered: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.deliveredKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.deliveredKey) }
    }

    private func isConsumable(_ purchase: Purchase) -> Bool {
        !purchase.products.isEmpty && purchase.products.allSatisfy(consumables.contains)
    }

    private func isServerConsumed(_ purchase: Purchase) -> Bool {
        !purchase.products.isEmpty && purchase.products.allSatisfy(serverConsumed.contains)
    }

    /// Whether a purchased purchase is past `confirm` (or there's none). One
    /// Play holds acknowledged was settled before, on this device or another:
    /// it isn't offered again, so an owned product stays owned offline.
    private func isSettled(_ purchase: Purchase) -> Bool {
        confirm == nil || purchase.acknowledged || confirmed.contains(purchase.token)
    }

    /// Products with a purchased purchase past `confirm`.
    private var settledProducts: Set<String> {
        Set(purchases.filter { $0.state == .purchased && isSettled($0) }.flatMap(\.products))
    }

    /// Products with a purchased purchase `confirm` hasn't answered for yet.
    private var awaitingConfirmation: Set<String> {
        Set(purchases.filter { $0.state == .purchased && confirming.contains($0.token) }.flatMap(\.products))
    }

    private func acknowledgeWhatNeedsIt() {
        if let confirm {
            for purchase in purchases where purchase.state == .purchased && !isSettled(purchase)
                && !consumed.contains(purchase.token) && !declined.contains(purchase.token) {
                guard confirming.insert(purchase.token).inserted else { continue }
                Task { @MainActor [weak self] in
                    let isConfirmed = await confirm(purchase)
                    self?.didConfirm(purchase, isConfirmed)
                }
            }
        }
        for purchase in purchases where purchase.state == .purchased && isConsumable(purchase) && isSettled(purchase) {
            // The server consumes it, which acknowledges it too.
            guard !consumed.contains(purchase.token), !isServerConsumed(purchase) else { continue }
            if !delivered.contains(purchase.token) {
                if let deliver {
                    delivered.insert(purchase.token)
                    for product in purchase.products { deliver(product, max(1, purchase.quantity)) }
                } else if confirm == nil {
                    // Held, unconsumed, until the game can take it.
                    continue
                }
                // Confirmed and no `deliver`: the server's credit was the delivery.
            }
            guard consuming.insert(purchase.token).inserted else { continue }
            channel.call("billing.consume", ["token": purchase.token])
        }
        for purchase in purchases where purchase.state == .purchased && !purchase.acknowledged && !isConsumable(purchase) && isSettled(purchase) {
            guard acknowledging.insert(purchase.token).inserted else { continue }
            channel.call("billing.acknowledge", ["token": purchase.token])
        }
    }

    private func didConfirm(_ purchase: Purchase, _ isConfirmed: Bool) {
        confirming.remove(purchase.token)
        guard isConfirmed else {
            declined.insert(purchase.token)
            Self.log("billing: \(purchase.products.joined(separator: ", ")) not confirmed; offered again after the next query "
                + "(Play refunds a purchase left unacknowledged for three days)")
            for product in purchase.products { finishPurchases(of: product, .failed) }
            return
        }
        confirmed.insert(purchase.token)
        acknowledgeWhatNeedsIt()
        for product in purchase.products { finishPurchases(of: product, .purchased) }
        changed?()
    }

    private func finish(_ product: String?, _ result: BillingResult) {
        if let product {
            finishPurchases(of: product, result)
        } else {
            finishPurchases(result)
        }
    }

    private func finishPurchases(of product: String, _ result: BillingResult) {
        guard let waiters = purchaseWaiters.removeValue(forKey: product) else { return }
        for waiter in waiters { waiter.resume(returning: result) }
    }

    private func finishPurchases(_ result: BillingResult) {
        for product in Array(purchaseWaiters.keys) { finishPurchases(of: product, result) }
    }

    private func finishRestores(owning: Bool) {
        let waiters = restoreWaiters
        restoreWaiters = []
        for waiter in waiters { waiter.resume(returning: owning) }
    }

    private static func parse(_ body: PlatformChannel.Message) -> [Purchase] {
        (body["purchases"] as? [PlatformChannel.Message] ?? []).compactMap { item in
            guard let token = item["token"] as? String, let products = item["products"] as? [String] else { return nil }
            return Purchase(
                products: products,
                state: State(rawValue: item["state"] as? String ?? "") ?? .unspecified,
                token: token,
                time: Date(timeIntervalSince1970: (item.double("time") ?? 0) / 1000),
                acknowledged: item.bool("acknowledged") ?? false,
                quantity: (item["quantity"] as? Int) ?? item.double("quantity").map { Int($0) } ?? 1,
                orderID: (item["orderId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                originalJSON: item["originalJson"] as? String,
                signature: item["signature"] as? String
            )
        }
    }
}
