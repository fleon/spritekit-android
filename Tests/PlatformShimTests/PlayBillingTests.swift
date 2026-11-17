import Foundation
import Testing
@testable import PlatformShim

// Play Billing's state machine, driven by the events Java would send. The
// Java side only reports; everything decided about a purchase is here.

/// Stands in for `PlatformServices.java`: records each call, answers nothing.
final class FakeJava {
    private(set) var calls: [(name: String, arguments: [String: Any])] = []
    /// What Java answers a call at once, by name (nothing for the rest).
    var answers: [String: [String: Any]] = [:]
    private(set) lazy var channel = PlatformChannel { [unowned self] name, data in
        let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        self.calls.append((name, arguments))
        return self.answers[name].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    }

    var names: [String] { calls.map(\.name) }

    func count(_ name: String) -> Int { names.filter { $0 == name }.count }

    /// Sends one event, through JSON as Java's would arrive.
    func send(_ service: String, _ event: String, _ body: [String: Any] = [:]) {
        var message = body
        message["service"] = service
        message["event"] = event
        let data = try! JSONSerialization.data(withJSONObject: [message])
        channel.deliver(data)
    }

    /// Lets queued tasks run until `name` has been called `times` times.
    func waitFor(_ name: String, times: Int = 1) async {
        for _ in 0..<1000 where count(name) < times {
            await Task.yield()
        }
    }
}

private let fullGame = "com.example.game.fullgame"
private let rewardID = "com.example.game.reward"
private let bought = 1_790_000_000_000.0 // ms since 1970: 21 September 2026

private func purchase(_ state: String, token: String = "t1", acknowledged: Bool = false, time: Double = bought) -> [String: Any] {
    ["products": [fullGame], "state": state, "token": token, "time": time, "acknowledged": acknowledged]
}

@Suite("Play Billing")
@MainActor
struct PlayBillingTests {
    @Test("Starting asks for the full game, and its price comes back localized")
    func price() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        var changes = 0
        billing.start { changes += 1 }
        #expect(java.names == ["billing.start"])
        #expect(java.calls[0].arguments["products"] as? [String] == [fullGame])
        #expect(billing.displayPrice == nil)
        java.send("billing", "product", ["productId": fullGame, "price": "6,99 €", "priceMicros": 6_990_000, "currency": "EUR"])
        #expect(billing.displayPrice == "6,99 €")
        #expect(changes == 1)
    }

    @Test("A purchase that goes through is owned, dated by Play and acknowledged")
    func purchased() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        let result = Task { await billing.purchase(fullGame) }
        await java.waitFor("billing.purchase")
        java.send("billing", "updated", ["code": "ok", "purchases": [purchase("purchased")]])
        #expect(await result.value == .purchased)
        #expect(billing.ownedProducts == [fullGame])
        #expect(billing.purchaseDates[fullGame] == Date(timeIntervalSince1970: bought / 1000))
        #expect(java.count("billing.acknowledge") == 1)
        #expect(java.calls.last?.arguments["token"] as? String == "t1")
    }

    @Test("A pending purchase unlocks nothing until it completes")
    func pending() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        var changes = 0
        billing.start { changes += 1 }
        let result = Task { await billing.purchase(fullGame) }
        await java.waitFor("billing.purchase")
        java.send("billing", "updated", ["code": "ok", "purchases": [purchase("pending")]])
        #expect(await result.value == .pending)
        #expect(billing.ownedProducts.isEmpty)
        #expect(billing.pendingProducts == [fullGame])
        #expect(java.count("billing.acknowledge") == 0)

        // Paid at the shop: Play tells the running game, which unlocks.
        java.send("billing", "updated", ["code": "ok", "purchases": [purchase("purchased")]])
        #expect(billing.ownedProducts == [fullGame])
        #expect(billing.pendingProducts.isEmpty)
        #expect(java.count("billing.acknowledge") == 1)
        #expect(changes == 2)
    }

    @Test("A pending purchase completed while away is found by the next query")
    func pendingCompletedAway() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("pending")]])
        #expect(billing.ownedProducts.isEmpty)
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased")]])
        #expect(billing.ownedProducts == [fullGame])
    }

    @Test("Cancelling buys nothing")
    func cancelled() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        let result = Task { await billing.purchase(fullGame) }
        await java.waitFor("billing.purchase")
        java.send("billing", "updated", ["code": "cancelled", "responseCode": 1])
        #expect(await result.value == .cancelled)
        #expect(billing.ownedProducts.isEmpty)
    }

    @Test("A flow that can't start fails rather than hanging")
    func failed() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        let result = Task { await billing.purchase(fullGame) }
        await java.waitFor("billing.purchase")
        java.send("billing", "updated", ["code": "unavailable", "responseCode": -1, "productId": fullGame])
        #expect(await result.value == .failed)
    }

    @Test("Billing unavailable fails a waiting purchase and restore")
    func unavailable() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        let bought = Task { await billing.purchase(fullGame) }
        await java.waitFor("billing.purchase")
        let restored = Task { await billing.restore() }
        await java.waitFor("billing.restore")
        java.send("billing", "unavailable", ["code": "unavailable", "responseCode": 3])
        #expect(await bought.value == .failed)
        #expect(await restored.value == false)
    }

    @Test("Already owned is settled by the query that follows")
    func alreadyOwned() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        let result = Task { await billing.purchase(fullGame) }
        await java.waitFor("billing.purchase")
        java.send("billing", "updated", ["code": "owned", "responseCode": 7, "productId": fullGame])
        #expect(java.count("billing.restore") == 1)
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased", acknowledged: true)]])
        #expect(await result.value == .purchased)
        #expect(billing.ownedProducts == [fullGame])
        #expect(java.count("billing.acknowledge") == 0)
    }

    @Test("Restoring after a reinstall finds the purchase")
    func restore() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        let result = Task { await billing.restore() }
        await java.waitFor("billing.restore")
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased", acknowledged: true)]])
        #expect(await result.value)
        #expect(billing.ownedProducts == [fullGame])
    }

    @Test("Restoring with nothing bought says so")
    func restoreNothing() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        let result = Task { await billing.restore() }
        await java.waitFor("billing.restore")
        java.send("billing", "owned", ["code": "ok", "purchases": [[String: Any]]()])
        #expect(await result.value == false)
    }

    @Test("Offline keeps the purchase; a refund takes it away")
    func offlineAndRefund() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased", acknowledged: true)]])
        java.send("billing", "owned", ["code": "unavailable", "responseCode": 12])
        #expect(billing.ownedProducts == [fullGame])
        java.send("billing", "owned", ["code": "ok", "purchases": [[String: Any]]()])
        #expect(billing.ownedProducts.isEmpty)
    }

    @Test("A failed acknowledgement is tried again after the next query, and only then")
    func acknowledgeRetry() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased")]])
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased")]])
        #expect(java.count("billing.acknowledge") == 1)
        java.send("billing", "acknowledged", ["code": "error", "token": "t1"])
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased")]])
        #expect(java.count("billing.acknowledge") == 2)
        java.send("billing", "acknowledged", ["code": "ok", "token": "t1"])
        #expect(billing.purchases.first?.acknowledged == true)
    }

    @Test("Buying what is owned asks Play nothing")
    func ownedAlready() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased", acknowledged: true)]])
        #expect(await billing.purchase(fullGame) == .purchased)
        #expect(java.count("billing.purchase") == 0)
    }

    @Test("The earliest of two purchase times dates the product")
    func earliestDate() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        java.send("billing", "owned", ["code": "ok", "purchases": [
            purchase("purchased", token: "late", acknowledged: true, time: bought + 86_400_000),
            purchase("purchased", token: "early", acknowledged: true),
        ]])
        #expect(billing.purchaseDates[fullGame] == Date(timeIntervalSince1970: bought / 1000))
    }

    @Test("A restore reports when the product was first bought, not when it reached this device")
    func purchaseTimeOnRestore() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        let longAgo = bought - 1000 * 60 * 60 * 24 * 365
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased", acknowledged: true, time: longAgo)]])
        #expect(billing.purchaseDates[fullGame] == Date(timeIntervalSince1970: longAgo / 1000))
    }
}

@Suite("Play Billing: the pre-registration reward")
@MainActor
struct PlayBillingRewardTests {
    @Test("Play's reward, found by the launch query with no order ID, is owned and acknowledged")
    func reward() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame])
        billing.start {}
        // A reward carries no order ID or developer payload; only these fields are read.
        java.send("billing", "owned", ["code": "ok", "purchases": [
            ["products": [rewardID], "state": "purchased", "token": "reward", "time": bought, "acknowledged": false],
        ]])
        #expect(billing.ownedProducts == [rewardID])
        await java.waitFor("billing.acknowledge")
        #expect(java.calls.last?.arguments["token"] as? String == "reward")
    }
}

// MARK: Consumables

private let smallPack = "com.example.game.pack_small"
private let largePack = "com.example.game.pack_large"

private func pack(_ product: String, _ state: String = "purchased", token: String, quantity: Int = 1) -> [String: Any] {
    ["products": [product], "state": state, "token": token, "time": bought, "acknowledged": false, "quantity": quantity]
}

private func freshDefaults() -> UserDefaults {
    let name = "PlayBillingTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Play Billing: consumables")
@MainActor
struct PlayBillingConsumableTests {
    @Test("Each product's price, by product")
    func prices() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [smallPack, largePack], consumables: [smallPack, largePack], defaults: freshDefaults())
        billing.start {}
        java.send("billing", "product", ["productId": largePack, "price": "€9.99"])
        java.send("billing", "product", ["productId": smallPack, "price": "€0.99"])
        #expect(billing.price(of: smallPack) == "€0.99")
        #expect(billing.price(of: largePack) == "€9.99")
    }

    @Test("A consumable bought is delivered once, consumed rather than acknowledged, and never owned")
    func deliveredAndConsumed() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [smallPack], consumables: [smallPack], defaults: freshDefaults())
        var delivered: [(String, Int)] = []
        billing.deliver = { delivered.append(($0, $1)) }
        billing.start {}
        let result = Task { await billing.purchase(smallPack) }
        await java.waitFor("billing.purchase")
        java.send("billing", "updated", ["code": "ok", "purchases": [pack(smallPack, token: "c1", quantity: 2)]])
        #expect(await result.value == .purchased)
        #expect(delivered.count == 1 && delivered[0].0 == smallPack && delivered[0].1 == 2)
        #expect(billing.ownedProducts.isEmpty)
        #expect(java.count("billing.acknowledge") == 0)
        #expect(java.count("billing.consume") == 1)
        #expect(java.calls.last?.arguments["token"] as? String == "c1")

        // Reported again before the consume lands: not delivered twice, nor consumed twice.
        java.send("billing", "owned", ["code": "ok", "purchases": [pack(smallPack, token: "c1")]])
        #expect(delivered.count == 1)
        #expect(java.count("billing.consume") == 1)

        java.send("billing", "consumed", ["code": "ok", "token": "c1"])
        #expect(billing.purchases.isEmpty)

        // Bought again: a new token, delivered again.
        let again = Task { await billing.purchase(smallPack) }
        await java.waitFor("billing.purchase", times: 2)
        java.send("billing", "updated", ["code": "ok", "purchases": [pack(smallPack, token: "c2")]])
        #expect(await again.value == .purchased)
        #expect(delivered.count == 2)
    }

    @Test("A consume that fails is tried again, and a token delivered before a restart is not granted again")
    func survivesFailureAndRestart() {
        let defaults = freshDefaults()
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [smallPack], consumables: [smallPack], defaults: defaults)
        var delivered = 0
        billing.deliver = { _, _ in delivered += 1 }
        billing.start {}
        java.send("billing", "owned", ["code": "ok", "purchases": [pack(smallPack, token: "c1")]])
        #expect(delivered == 1)
        java.send("billing", "consumed", ["code": "error", "token": "c1"])
        java.send("billing", "owned", ["code": "ok", "purchases": [pack(smallPack, token: "c1")]])
        #expect(java.count("billing.consume") == 2)
        #expect(delivered == 1)

        // The game stopped before the consume landed: the next launch's
        // query reports the token again.
        let nextJava = FakeJava()
        let next = PlayBilling(channel: nextJava.channel, products: [smallPack], consumables: [smallPack], defaults: defaults)
        var nextDelivered = 0
        next.deliver = { _, _ in nextDelivered += 1 }
        next.start {}
        nextJava.send("billing", "owned", ["code": "ok", "purchases": [pack(smallPack, token: "c1")]])
        #expect(nextDelivered == 0)
        #expect(nextJava.count("billing.consume") == 1)
        nextJava.send("billing", "consumed", ["code": "ok", "token": "c1"])
        #expect(defaults.stringArray(forKey: PlayBilling.deliveredKey) == [])
    }

    @Test("A pack Play reports before the game can take it is held, not consumed, until it can")
    func heldUntilDeliverIsSet() {
        let defaults = freshDefaults()
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [smallPack], consumables: [smallPack], defaults: defaults)
        billing.start {}
        java.send("billing", "owned", ["code": "ok", "purchases": [pack(smallPack, token: "c1", quantity: 2)]])
        #expect(java.count("billing.consume") == 0)
        #expect(defaults.stringArray(forKey: PlayBilling.deliveredKey) ?? [] == [])
        var delivered: [(String, Int)] = []
        billing.deliver = { delivered.append(($0, $1)) }
        #expect(delivered.map(\.0) == [smallPack])
        #expect(delivered.map(\.1) == [2])
        #expect(java.count("billing.consume") == 1)
    }

    @Test("A query under way when a pack is consumed doesn't deliver it again")
    func consumedThenStaleQuery() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [smallPack], consumables: [smallPack], defaults: freshDefaults())
        var delivered = 0
        billing.deliver = { _, _ in delivered += 1 }
        billing.start {}
        java.send("billing", "updated", ["code": "ok", "purchases": [pack(smallPack, token: "c1")]])
        #expect(delivered == 1)
        java.send("billing", "consumed", ["code": "ok", "token": "c1"])
        // A restore asked for before the consume answers with the token.
        java.send("billing", "owned", ["code": "ok", "purchases": [pack(smallPack, token: "c1")]])
        java.send("billing", "updated", ["code": "ok", "purchases": [pack(smallPack, token: "c1")]])
        #expect(delivered == 1)
        #expect(java.count("billing.consume") == 1)
        #expect(billing.purchases.isEmpty)
    }

    @Test("A pending pack is delivered only once paid for")
    func pending() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [smallPack], consumables: [smallPack], defaults: freshDefaults())
        var delivered = 0
        billing.deliver = { _, _ in delivered += 1 }
        billing.start {}
        java.send("billing", "updated", ["code": "ok", "purchases": [pack(smallPack, "pending", token: "p1")]])
        #expect(delivered == 0)
        #expect(java.count("billing.consume") == 0)
        java.send("billing", "updated", ["code": "ok", "purchases": [pack(smallPack, token: "p1")]])
        #expect(delivered == 1)
        #expect(java.count("billing.consume") == 1)
    }

    @Test("A non-consumable beside them is still owned and acknowledged")
    func mixed() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel, products: [fullGame, smallPack], consumables: [smallPack], defaults: freshDefaults())
        billing.deliver = { _, _ in }
        billing.start {}
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased"), pack(smallPack, token: "c1")]])
        #expect(billing.ownedProducts == [fullGame])
        #expect(java.count("billing.acknowledge") == 1)
        #expect(java.count("billing.consume") == 1)
    }
}
