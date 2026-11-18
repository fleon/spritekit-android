import Foundation
import Testing
@testable import PlatformStore

// The manager over simulated and fake stores: what's owned and kept,
// prices, purchase dates and deadlines, consumables.

private let unlock = "com.example.game.unlock"
private let pack = "com.example.game.pack"
private let products: [StoreProduct] = [.nonConsumable(unlock), .consumable(pack)]

private func scratchDefaults() -> UserDefaults {
    let name = UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private final class FakeBilling: BillingBackend {
    var prices: [String: String] = [:]
    var ownedProducts: Set<String> = []
    var freeProducts: Set<String> = []
    var purchaseDates: [String: Date] = [:]
    var knowsOwnedProducts = true
    var knowsFreeProducts = true
    var changed: (() -> Void)?

    var displayPrice: String? { prices[unlock] }
    func price(of productID: String) -> String? { prices[productID] }

    func start(changed: @escaping () -> Void) {
        self.changed = changed
    }

    func purchase(_ productID: String) async -> BillingResult {
        ownedProducts.insert(productID)
        changed?()
        return .purchased
    }

    func restore() async -> Bool { !ownedProducts.isEmpty }
}

@Suite("Store manager")
@MainActor
struct StoreManagerTests {
    private func store(
        _ billing: BillingBackend,
        defaults: UserDefaults,
        now: Date = Date(timeIntervalSince1970: 1_000),
        deliver: ((String, Int) -> Void)? = nil
    ) -> StoreManager {
        StoreManager(
            configuration: .init(products: products, previewPrice: "$9.99", deliver: deliver, defaults: defaults, now: { now }),
            billing: billing
        )
    }

    @Test("A purchase is owned, and known at the next launch before the store answers")
    func ownedAndKept() async {
        let defaults = scratchDefaults()
        let manager = store(FakeBilling(), defaults: defaults)
        manager.start()
        #expect(!manager.owns(unlock))
        #expect(await manager.purchase(unlock) == .purchased)
        #expect(manager.owns(unlock))

        // A relaunch with a store that hasn't answered yet.
        let silent = FakeBilling()
        silent.knowsOwnedProducts = false
        silent.knowsFreeProducts = false
        let relaunched = store(silent, defaults: defaults)
        relaunched.start()
        #expect(relaunched.owns(unlock))
    }

    @Test("The cache stands until the store answers, which then replaces it")
    func cacheUntilKnown() {
        let defaults = scratchDefaults()
        let free = "com.example.game.free"
        defaults.set([unlock], forKey: "store.ownedProducts")
        defaults.set([free], forKey: "store.freeProducts")
        let billing = FakeBilling()
        billing.knowsOwnedProducts = false
        billing.knowsFreeProducts = false
        let manager = store(billing, defaults: defaults)
        manager.start()
        billing.prices = [unlock: "4,99 €"]
        billing.changed?()
        #expect(manager.owns(unlock))
        #expect(manager.owns(free))
        #expect(defaults.stringArray(forKey: "store.ownedProducts") == [unlock])
        #expect(defaults.stringArray(forKey: "store.freeProducts") == [free])

        // Entitlements answer first (refunded meanwhile), the prices later.
        billing.knowsOwnedProducts = true
        billing.changed?()
        #expect(!manager.owns(unlock))
        #expect(manager.owns(free))
        #expect(defaults.stringArray(forKey: "store.ownedProducts") == [])
        #expect(defaults.stringArray(forKey: "store.freeProducts") == [free])
        billing.knowsFreeProducts = true
        billing.changed?()
        #expect(!manager.owns(free))
        #expect(defaults.stringArray(forKey: "store.freeProducts") == [])
    }

    @Test("A purchase before the store has answered is owned, and the cache is left alone")
    func purchaseBeforeKnown() async {
        let defaults = scratchDefaults()
        defaults.set(["com.example.game.other"], forKey: "store.ownedProducts")
        let billing = FakeBilling()
        billing.knowsOwnedProducts = false
        let manager = store(billing, defaults: defaults)
        manager.start()
        #expect(await manager.purchase(unlock) == .purchased)
        #expect(manager.owns(unlock))
        #expect(manager.owns("com.example.game.other"))
        #expect(defaults.stringArray(forKey: "store.ownedProducts") == ["com.example.game.other"])
    }

    @Test("Simulated purchases never reach the cache")
    func simulatedNotCached() async {
        let defaults = scratchDefaults()
        let manager = store(SimulatedBilling(products: products, defaults: scratchDefaults()), defaults: defaults)
        manager.start()
        #expect(await manager.purchase(unlock) == .purchased)
        #expect(manager.owns(unlock))
        #expect(defaults.stringArray(forKey: "store.ownedProducts") == nil)
        #expect(!store(FakeBilling(), defaults: defaults).owns(unlock))
    }

    @Test("Free where the player shops counts as owned")
    func free() {
        let billing = FakeBilling()
        billing.freeProducts = [unlock]
        let manager = store(billing, defaults: scratchDefaults())
        manager.start()
        #expect(manager.owns(unlock))
        #expect(manager.isFree(unlock))
        #expect(manager.ownership(of: unlock).purchaseDate == nil)
    }

    @Test("A refund takes ownership away")
    func refund() {
        let billing = FakeBilling()
        billing.ownedProducts = [unlock]
        let manager = store(billing, defaults: scratchDefaults())
        manager.start()
        #expect(manager.owns(unlock))
        billing.ownedProducts = []
        billing.changed?()
        #expect(!manager.owns(unlock))
    }

    @Test("The earliest purchase date is kept, and decides a deadline")
    func purchaseDates() {
        let defaults = scratchDefaults()
        let billing = FakeBilling()
        let early = Date(timeIntervalSince1970: 100)
        billing.ownedProducts = [unlock]
        billing.purchaseDates = [unlock: early]
        let manager = store(billing, defaults: defaults)
        manager.start()
        billing.purchaseDates = [unlock: Date(timeIntervalSince1970: 500)]
        billing.changed?()
        #expect(manager.ownership(of: unlock).purchaseDate == early)
        #expect(manager.owned(unlock, by: Date(timeIntervalSince1970: 200)))
        #expect(!manager.owned(unlock, by: Date(timeIntervalSince1970: 50)))
        #expect(store(NoBilling(), defaults: defaults).ownership(of: unlock).purchaseDate == early)
    }

    @Test("With no purchase date, when it was first seen owned decides")
    func firstSeen() {
        let defaults = scratchDefaults()
        let billing = FakeBilling()
        billing.freeProducts = [unlock]
        store(billing, defaults: defaults, now: Date(timeIntervalSince1970: 300)).start()
        let later = store(billing, defaults: defaults, now: Date(timeIntervalSince1970: 900))
        later.start()
        #expect(later.ownership(of: unlock).firstSeenOwned == Date(timeIntervalSince1970: 300))
        #expect(later.owned(unlock, by: Date(timeIntervalSince1970: 400)))
        #expect(!later.owned(unlock, by: Date(timeIntervalSince1970: 200)))
        // Not owned: no deadline is met.
        #expect(!later.owned(pack, by: .distantFuture))
    }

    @Test("A consumable is delivered and never owned")
    func consumable() async {
        var delivered: [String] = []
        let manager = store(
            SimulatedBilling(products: products, defaults: scratchDefaults()), defaults: scratchDefaults(),
            deliver: { product, quantity in delivered.append("\(product)×\(quantity)") }
        )
        manager.start()
        #expect(await manager.purchase(pack) == .purchased)
        #expect(await manager.purchase(pack) == .purchased)
        #expect(delivered == ["\(pack)×1", "\(pack)×1"])
        #expect(!manager.owns(pack))
    }

    @Test("A consumable a store reports owned is still not owned")
    func consumableNeverCached() {
        let billing = FakeBilling()
        billing.ownedProducts = [pack]
        let manager = store(billing, defaults: scratchDefaults())
        manager.start()
        #expect(!manager.owns(pack))
    }

    @Test("Prices come from the store, else the preview")
    func prices() async {
        let billing = FakeBilling()
        let manager = store(billing, defaults: scratchDefaults())
        manager.start()
        #expect(manager.price(of: unlock) == "$9.99")
        #expect(!manager.hasAllPrices)
        let waiting = Task { await manager.waitForPrices(timeout: 30) }
        billing.prices = [unlock: "4,99 €", pack: "0,99 €"]
        billing.changed?()
        await waiting.value
        #expect(manager.price(of: pack) == "0,99 €")
        #expect(manager.hasAllPrices)
    }

    @Test("Waiting for prices gives up")
    func pricesTimeOut() async {
        let manager = store(FakeBilling(), defaults: scratchDefaults())
        manager.start()
        await manager.waitForPrices(timeout: 0.01)
        #expect(!manager.hasAllPrices)
    }

    @Test("Every change is posted")
    func notifies() async {
        let billing = FakeBilling()
        let manager = store(billing, defaults: scratchDefaults())
        final class Count: @unchecked Sendable { var posts = 0 }
        let count = Count()
        let observer = NotificationCenter.default.addObserver(forName: StoreManager.didChange, object: manager, queue: nil) { _ in
            count.posts += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        manager.start()
        _ = await manager.purchase(unlock)
        #expect(count.posts >= 2)
        #expect(await manager.restore())
    }
}
