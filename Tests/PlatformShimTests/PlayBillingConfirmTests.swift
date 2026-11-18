import Foundation
import Testing
@testable import PlatformShim

// Play Billing for a game whose server credits each purchase (`confirm`),
// as StoreKit's backend does it on Apple: nothing is acknowledged or
// consumed until the server has said yes.

private let fullGame = "com.example.game.fullgame"
private let coins = "com.example.game.coins"
private let gems = "com.example.game.gems"
private let bought = 1_790_000_000_000.0

private func purchase(
    _ product: String, state: String = "purchased", token: String = "t1", acknowledged: Bool = false, quantity: Int = 1
) -> [String: Any] {
    ["products": [product], "state": state, "token": token, "time": bought, "acknowledged": acknowledged, "quantity": quantity,
     "orderId": "GPA.3301-\(token)", "originalJson": "{\"purchaseToken\":\"\(token)\"}", "signature": "c2ln"]
}

/// A server that answers each confirmation when the test says.
@MainActor
private final class Server {
    var answer = true
    private(set) var seen: [PlayBilling.Purchase] = []
    func confirm(_ purchase: PlayBilling.Purchase) async -> Bool {
        seen.append(purchase)
        return answer
    }
}

@Suite("Play Billing, confirmed by a server")
@MainActor
struct PlayBillingConfirmTests {
    private func billing(_ java: FakeJava, _ server: Server, serverConsumed: Set<String> = []) -> PlayBilling {
        let billing = PlayBilling(channel: java.channel, products: [fullGame, coins, gems], consumables: [coins, gems],
                                  serverConsumed: serverConsumed, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        billing.confirm = { await server.confirm($0) }
        billing.start {}
        return billing
    }

    /// Lets the confirmation's task run.
    private func settle() async {
        for _ in 0 ..< 50 { await Task.yield() }
    }

    @Test("A confirmed purchase is acknowledged after the server's yes, and its flow ends purchased")
    func confirmed() async {
        let java = FakeJava(), server = Server()
        let billing = billing(java, server)
        let result = Task { await billing.purchase(fullGame) }
        await java.waitFor("billing.purchase")
        java.send("billing", "updated", ["code": "ok", "purchases": [purchase(fullGame)]])
        #expect(await result.value == .purchased)
        #expect(server.seen.count == 1)
        #expect(server.seen.first?.orderID == "GPA.3301-t1")
        #expect(server.seen.first?.originalJSON == "{\"purchaseToken\":\"t1\"}")
        #expect(server.seen.first?.signature == "c2ln")
        #expect(java.count("billing.acknowledge") == 1)
    }

    @Test("A purchase the server turns down is left alone and fails, then a confirmed retry after the next query acknowledges")
    func declinedThenRetried() async {
        let java = FakeJava(), server = Server()
        server.answer = false
        var logged: [String] = []
        PlayBilling.log = { logged.append($0) }
        defer { PlayBilling.log = { NSLog("%@", $0) } }
        let billing = billing(java, server)
        let result = Task { await billing.purchase(fullGame) }
        await java.waitFor("billing.purchase")
        java.send("billing", "updated", ["code": "ok", "purchases": [purchase(fullGame)]])
        #expect(await result.value == .failed)
        #expect(java.count("billing.acknowledge") == 0)
        #expect(logged.count == 1 && logged[0].contains("three days"))

        // Another update isn't the next query: not offered again yet.
        java.send("billing", "updated", ["code": "ok", "purchases": [purchase(fullGame)]])
        await settle()
        #expect(server.seen.count == 1)

        // The next query (launch, resume, restore) offers it again.
        server.answer = true
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase(fullGame)]])
        await settle()
        #expect(server.seen.count == 2)
        #expect(java.count("billing.acknowledge") == 1)
        #expect(billing.ownedProducts == [fullGame])
    }

    @Test("A consumable the app consumes is consumed after the yes; with no deliver, the server's credit is the delivery")
    func clientConsumed() async {
        let java = FakeJava(), server = Server()
        let billing = billing(java, server)
        let result = Task { await billing.purchase(coins) }
        await java.waitFor("billing.purchase")
        java.send("billing", "updated", ["code": "ok", "purchases": [purchase(coins)]])
        #expect(await result.value == .purchased)
        #expect(java.count("billing.consume") == 1)
        #expect(java.count("billing.acknowledge") == 0)
        #expect(billing.ownedProducts.isEmpty)
    }

    @Test("A consumable the server consumes is neither consumed nor acknowledged here, nor confirmed twice in a session")
    func serverConsumed() async {
        let java = FakeJava(), server = Server()
        var delivered: [(String, Int)] = []
        let billing = billing(java, server, serverConsumed: [coins])
        billing.deliver = { delivered.append(($0, $1)) }
        let result = Task { await billing.purchase(coins) }
        await java.waitFor("billing.purchase")
        java.send("billing", "updated", ["code": "ok", "purchases": [purchase(coins)]])
        #expect(await result.value == .purchased)
        #expect(java.count("billing.consume") == 0)
        #expect(java.count("billing.acknowledge") == 0)
        #expect(delivered.isEmpty)

        // Play still lists it until the server's consume lands: done here.
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase(coins)]])
        await settle()
        #expect(server.seen.count == 1)
        java.send("billing", "owned", ["code": "ok", "purchases": []])
        #expect(billing.purchases.isEmpty)
    }

    @Test("Several bought at once are delivered as one quantity after the yes, and consumed once")
    func quantity() async {
        let java = FakeJava(), server = Server()
        var delivered: [(String, Int)] = []
        let billing = billing(java, server)
        billing.deliver = { delivered.append(($0, $1)) }
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase(gems, token: "t3", quantity: 3)]])
        #expect(delivered.isEmpty)
        await settle()
        #expect(server.seen.first?.quantity == 3)
        #expect(delivered.count == 1 && delivered[0].0 == gems && delivered[0].1 == 3)
        #expect(java.count("billing.consume") == 1)
    }

    @Test("After a relaunch an acknowledged unlock is owned at once and never confirmed again, offline included")
    func acknowledgedIsSettled() async {
        let java = FakeJava(), server = Server()
        server.answer = false   // the server is unreachable
        let billing = billing(java, server)
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase(fullGame, acknowledged: true)]])
        await settle()
        #expect(server.seen.isEmpty)
        #expect(billing.ownedProducts == [fullGame])
        #expect(java.count("billing.acknowledge") == 0)
        // Buying it again asks Play nothing: it's owned.
        #expect(await billing.purchase(fullGame) == .purchased)
        #expect(java.count("billing.purchase") == 0)
    }

    @Test("Nothing is acknowledged while the server is still answering")
    func waitsForTheAnswer() async {
        let java = FakeJava()
        var answer: CheckedContinuation<Bool, Never>?
        let billing = PlayBilling(channel: java.channel, products: [fullGame], defaults: UserDefaults(suiteName: UUID().uuidString)!)
        billing.confirm = { _ in await withCheckedContinuation { answer = $0 } }
        billing.start {}
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase(fullGame)]])
        await settle()
        #expect(answer != nil)
        #expect(java.count("billing.acknowledge") == 0)
        // Another query meanwhile doesn't ask twice.
        java.send("billing", "owned", ["code": "ok", "purchases": [purchase(fullGame)]])
        answer?.resume(returning: true)
        await settle()
        #expect(java.count("billing.acknowledge") == 1)
    }
}
