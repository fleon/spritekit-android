import Foundation
import Testing
@testable import PlatformShim

// Play Billing's state machine, driven by the events Java would send. The
// Java side only reports; everything decided about a purchase is here.

/// Stands in for `PlatformServices.java`: records each call, answers nothing.
final class FakeJava {
    private(set) var calls: [(name: String, arguments: [String: Any])] = []
    private(set) lazy var channel = PlatformChannel { [unowned self] name, data in
        let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        self.calls.append((name, arguments))
        return nil
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

private let fullGame = Entitlements.fullGameID
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
        let billing = PlayBilling(channel: java.channel)
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
        let billing = PlayBilling(channel: java.channel)
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
        let billing = PlayBilling(channel: java.channel)
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
        let billing = PlayBilling(channel: java.channel)
        billing.start {}
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("pending")]])
        #expect(billing.ownedProducts.isEmpty)
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased")]])
        #expect(billing.ownedProducts == [fullGame])
    }

    @Test("Cancelling buys nothing")
    func cancelled() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel)
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
        let billing = PlayBilling(channel: java.channel)
        billing.start {}
        let result = Task { await billing.purchase(fullGame) }
        await java.waitFor("billing.purchase")
        java.send("billing", "updated", ["code": "unavailable", "responseCode": -1, "productId": fullGame])
        #expect(await result.value == .failed)
    }

    @Test("Billing unavailable fails a waiting purchase and restore")
    func unavailable() async {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel)
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
        let billing = PlayBilling(channel: java.channel)
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
        let billing = PlayBilling(channel: java.channel)
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
        let billing = PlayBilling(channel: java.channel)
        billing.start {}
        let result = Task { await billing.restore() }
        await java.waitFor("billing.restore")
        java.send("billing", "owned", ["code": "ok", "purchases": [[String: Any]]()])
        #expect(await result.value == false)
    }

    @Test("Offline keeps the purchase; a refund takes it away")
    func offlineAndRefund() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel)
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
        let billing = PlayBilling(channel: java.channel)
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
        let billing = PlayBilling(channel: java.channel)
        billing.start {}
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased", acknowledged: true)]])
        #expect(await billing.purchase(fullGame) == .purchased)
        #expect(java.count("billing.purchase") == 0)
    }

    @Test("The earliest of two purchase times dates the product")
    func earliestDate() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel)
        billing.start {}
        java.send("billing", "owned", ["code": "ok", "purchases": [
            purchase("purchased", token: "late", acknowledged: true, time: bought + 86_400_000),
            purchase("purchased", token: "early", acknowledged: true),
        ]])
        #expect(billing.purchaseDates[fullGame] == Date(timeIntervalSince1970: bought / 1000))
    }

    @Test("Play's purchase time decides the launch event, not the day it reached this device")
    func launchEventByPurchaseTime() {
        let java = FakeJava()
        let billing = PlayBilling(channel: java.channel)
        billing.start {}
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let entitlements = Entitlements(defaults: defaults)
        let beforeEnd = Entitlements.launchEventEnd.addingTimeInterval(-3600).timeIntervalSince1970 * 1000
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase("purchased", acknowledged: true, time: beforeEnd)]])
        // Restored long after the event, on a new phone.
        if let date = billing.purchaseDates[fullGame] { entitlements.noteBought(at: date) }
        #expect(entitlements.keepsSecretWorlds(owns: true))
    }
}
