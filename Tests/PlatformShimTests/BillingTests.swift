import Foundation
import Testing
@testable import PlatformShim

// The backends with no store behind them: none at all, and the simulated
// one. (What a game keeps about what's owned is its own, and tested with it.)

private let fullGameID = "com.example.game.fullgame"

private func scratchDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Billing backends")
struct BillingBackendTests {
    @Test("With no store nothing is owned and a purchase fails")
    func noBilling() async {
        let billing = NoBilling()
        #expect(billing.ownedProducts.isEmpty)
        #expect(billing.displayPrice == nil)
        let result = await billing.purchase(fullGameID)
        #expect(result == .failed)
    }

    @Test("A simulated purchase grants at once and is kept")
    func simulatedPurchase() async {
        let name = UUID().uuidString
        let defaults = scratchDefaults(name)
        var changes = 0
        let billing = SimulatedBilling(defaults: defaults)
        billing.start { changes += 1 }

        #expect(billing.ownedProducts.isEmpty)
        let result = await billing.purchase(fullGameID)
        #expect(result == .purchased)
        #expect(billing.ownedProducts == [fullGameID])
        #expect(changes == 1)

        // A relaunch still owns it.
        #expect(SimulatedBilling(defaults: defaults).ownedProducts == [fullGameID])
        defaults.removePersistentDomain(forName: name)
    }

    @Test("Buying twice is quiet the second time")
    func purchaseTwice() async {
        let name = UUID().uuidString
        let defaults = scratchDefaults(name)
        var changes = 0
        let billing = SimulatedBilling(defaults: defaults)
        billing.start { changes += 1 }
        _ = await billing.purchase(fullGameID)
        _ = await billing.purchase(fullGameID)
        #expect(changes == 1)
        defaults.removePersistentDomain(forName: name)
    }

    @Test("Every backend answers a price by product")
    func pricesByProduct() {
        #expect(NoBilling().price(of: fullGameID) == nil)
        #expect(SimulatedBilling(defaults: scratchDefaults()).price(of: "any") == SimulatedBilling.previewPrice)
    }

    @Test("A simulated consumable is delivered, held till the game takes it, and never owned")
    func simulatedConsumable() async {
        let name = UUID().uuidString
        let defaults = scratchDefaults(name)
        let billing = SimulatedBilling(defaults: defaults, consumables: ["pack"])
        billing.start {}
        #expect(await billing.purchase("pack") == .purchased)
        var delivered: [String] = []
        billing.deliver = { product, quantity in delivered.append("\(product)×\(quantity)") }
        #expect(delivered == ["pack×1"])
        _ = await billing.purchase("pack")
        #expect(delivered == ["pack×1", "pack×1"])
        #expect(billing.ownedProducts.isEmpty)
        // A backend with no consumables takes `deliver` and ignores it.
        let none: BillingBackend = NoBilling()
        none.deliver = { _, _ in }
        #expect(none.deliver == nil)
        defaults.removePersistentDomain(forName: name)
    }

    @Test("Forgetting a simulated purchase leaves nothing owned")
    func forget() async {
        let name = UUID().uuidString
        let defaults = scratchDefaults(name)
        let billing = SimulatedBilling(defaults: defaults)
        billing.start {}
        _ = await billing.purchase(fullGameID)
        billing.forgetPurchases()
        #expect(billing.ownedProducts.isEmpty)
        defaults.removePersistentDomain(forName: name)
    }
}

@Suite("Achievements")
struct AchievementTests {
    @Test("Nobody is signed in, and the answer still comes")
    func answersAtOnce() {
        var answered = false
        LocalAchievements(defaults: scratchDefaults()).start { answered = true }
        #expect(answered, "the launch splash holds for this answer")
    }

    @Test("What was reported is what is loaded back")
    func reportsAndLoads() async {
        let name = UUID().uuidString
        let defaults = scratchDefaults(name)
        let service = LocalAchievements(defaults: defaults)
        #expect(await service.load().isEmpty)

        _ = await service.report(["com.example.game.achievement.levels.1": 100], showingBanners: true)
        #expect(await service.load() == ["com.example.game.achievement.levels.1": 100])

        // A relaunch still holds it.
        #expect(await LocalAchievements(defaults: defaults).load().count == 1)
        defaults.removePersistentDomain(forName: name)
    }

    @Test("Progress never goes backwards")
    func neverRegresses() async {
        let name = UUID().uuidString
        let defaults = scratchDefaults(name)
        let service = LocalAchievements(defaults: defaults)
        _ = await service.report(["a": 80], showingBanners: false)
        _ = await service.report(["a": 40], showingBanners: false)
        #expect(await service.load()["a"] == 80)
        defaults.removePersistentDomain(forName: name)
    }

    @Test("A reset clears everything")
    func reset() async {
        let name = UUID().uuidString
        let defaults = scratchDefaults(name)
        let service = LocalAchievements(defaults: defaults)
        _ = await service.report(["a": 100], showingBanners: false)
        #expect(await service.reset())
        #expect(await service.load().isEmpty)
        defaults.removePersistentDomain(forName: name)
    }

    @Test("There is no maker credit on Android")
    func noPlayer() async {
        #expect(await LocalAchievements(defaults: scratchDefaults()).localPlayer() == nil)
    }
}
