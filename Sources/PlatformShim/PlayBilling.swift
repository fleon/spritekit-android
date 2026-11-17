import Foundation

/// Google Play Billing behind `BillingBackend`: the full game's price, buying
/// it, acknowledging it, and what the player owns.
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
///     query, and the game unlocks then), `.cancelled` or `.failed`. Play's
///     "already owned" is taken as a restore: the query that follows decides.
///   - **Acknowledgement**: every purchased, unacknowledged purchase is
///     acknowledged once a session (Play refunds one left unacknowledged for
///     three days); one that fails is tried again after the next query.
///   - **When it was bought** is Play's `purchaseTime`, which stands in for
///     StoreKit's `originalPurchaseDate` in the launch event's rule.
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

        public init(products: [String], state: State, token: String, time: Date, acknowledged: Bool) {
            self.products = products
            self.state = state
            self.token = token
            self.time = time
            self.acknowledged = acknowledged
        }
    }

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

    public init(channel: PlatformChannel, products: [String]) {
        self.channel = channel
        productIDs = products
        channel.on(Self.service) { [weak self] event, body in self?.handle(event, body) }
    }

    // MARK: - BillingBackend

    public var displayPrice: String? { productIDs.lazy.compactMap { self.prices[$0] }.first }

    public var ownedProducts: Set<String> {
        Set(purchases.filter { $0.state == .purchased }.flatMap(\.products))
    }

    /// Play isn't offered in mainland China, the one place the full game is
    /// free on the App Store, so nothing is free here.
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
        purchases = Self.parse(body)
        acknowledgeWhatNeedsIt()
        let owned = ownedProducts
        for product in awaitingOwned {
            finishPurchases(of: product, owned.contains(product) ? .purchased : .failed)
        }
        awaitingOwned = []
        for product in owned { finishPurchases(of: product, .purchased) }
        changed?()
        finishRestores(owning: !owned.isEmpty)
    }

    /// The end of a purchase flow, or a purchase changing while the game runs.
    private func updated(_ body: PlatformChannel.Message) {
        let product = body["productId"] as? String
        switch body["code"] as? String {
        case "ok":
            let reported = Self.parse(body)
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
                case .purchased: .purchased
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
            // the query decides, and the game unlocks if it is so.
            awaitingOwned.formUnion(product.map { [$0] } ?? Array(purchaseWaiters.keys))
            channel.call("billing.restore")
        default:
            finish(product, .failed)
        }
    }

    private func acknowledgeWhatNeedsIt() {
        for purchase in purchases where purchase.state == .purchased && !purchase.acknowledged {
            guard acknowledging.insert(purchase.token).inserted else { continue }
            channel.call("billing.acknowledge", ["token": purchase.token])
        }
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
                acknowledged: item.bool("acknowledged") ?? false
            )
        }
    }
}
