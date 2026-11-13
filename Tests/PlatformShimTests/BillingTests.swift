import Foundation
import Testing
@testable import PlatformShim

// What the game asks of a store, with no store behind it: is the full game
// owned, and was it owned in time to keep the secret worlds. The launch
// event's rule is the one worth testing — it decides whether a player keeps
// The Mainframe for good, and it reads a date Apple's clock set.

private func scratchDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Entitlements")
struct EntitlementTests {
    @Test("Owning nothing keeps no secret worlds")
    func nothingOwned() {
        let entitlements = Entitlements(defaults: scratchDefaults())
        #expect(entitlements.keepsSecretWorlds(owns: false) == false)
    }

    @Test("Bought before the launch event ends keeps the secret worlds")
    func boughtInTime() {
        let entitlements = Entitlements(defaults: scratchDefaults())
        entitlements.noteBought(at: Entitlements.launchEventEnd.addingTimeInterval(-60))
        #expect(entitlements.keepsSecretWorlds(owns: true))
    }

    @Test("Bought after it ends does not")
    func boughtTooLate() {
        let entitlements = Entitlements(defaults: scratchDefaults())
        entitlements.noteBought(at: Entitlements.launchEventEnd.addingTimeInterval(60))
        #expect(entitlements.keepsSecretWorlds(owns: true) == false)
    }

    @Test("The earliest purchase date wins, so a later report cannot take the worlds away")
    func earliestWins() {
        let entitlements = Entitlements(defaults: scratchDefaults())
        entitlements.noteBought(at: Entitlements.launchEventEnd.addingTimeInterval(-60))
        entitlements.noteBought(at: Entitlements.launchEventEnd.addingTimeInterval(600))
        #expect(entitlements.keepsSecretWorlds(owns: true))
    }

    @Test("Owned with no purchase date during the event keeps them")
    func ownedDuringEvent() {
        let entitlements = Entitlements(defaults: scratchDefaults())
        entitlements.noteOwnedDuringEvent(owns: true, eventRunning: true)
        #expect(entitlements.wasOwnedDuringEvent)
        #expect(entitlements.keepsSecretWorlds(owns: true))
    }

    @Test("Owned with no purchase date after the event does not")
    func ownedAfterEvent() {
        let entitlements = Entitlements(defaults: scratchDefaults())
        entitlements.noteOwnedDuringEvent(owns: true, eventRunning: false)
        #expect(entitlements.wasOwnedDuringEvent == false)
        #expect(entitlements.keepsSecretWorlds(owns: true) == false)
    }

    @Test("A purchase date beats the seen-owned flag")
    func dateWinsOverFlag() {
        let entitlements = Entitlements(defaults: scratchDefaults())
        entitlements.noteOwnedDuringEvent(owns: true, eventRunning: true)
        entitlements.noteBought(at: Entitlements.launchEventEnd.addingTimeInterval(3600))
        #expect(entitlements.keepsSecretWorlds(owns: true) == false)
    }

    @Test("Owned products survive a relaunch")
    func ownedPersists() {
        let name = UUID().uuidString
        let defaults = scratchDefaults(name)
        Entitlements(defaults: defaults).owned = [Entitlements.fullGameID]
        #expect(Entitlements(defaults: defaults).owned == [Entitlements.fullGameID])
        defaults.removePersistentDomain(forName: name)
    }
}

@Suite("Billing backends")
struct BillingBackendTests {
    @Test("With no store nothing is owned and a purchase fails")
    func noBilling() async {
        let billing = NoBilling()
        #expect(billing.ownedProducts.isEmpty)
        #expect(billing.displayPrice == nil)
        let result = await billing.purchase(Entitlements.fullGameID)
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
        let result = await billing.purchase(Entitlements.fullGameID)
        #expect(result == .purchased)
        #expect(billing.ownedProducts == [Entitlements.fullGameID])
        #expect(changes == 1)

        // A relaunch still owns it.
        #expect(SimulatedBilling(defaults: defaults).ownedProducts == [Entitlements.fullGameID])
        defaults.removePersistentDomain(forName: name)
    }

    @Test("Buying twice is quiet the second time")
    func purchaseTwice() async {
        let name = UUID().uuidString
        let defaults = scratchDefaults(name)
        var changes = 0
        let billing = SimulatedBilling(defaults: defaults)
        billing.start { changes += 1 }
        _ = await billing.purchase(Entitlements.fullGameID)
        _ = await billing.purchase(Entitlements.fullGameID)
        #expect(changes == 1)
        defaults.removePersistentDomain(forName: name)
    }

    @Test("Forgetting a simulated purchase puts the free game back")
    func forget() async {
        let name = UUID().uuidString
        let defaults = scratchDefaults(name)
        let billing = SimulatedBilling(defaults: defaults)
        billing.start {}
        _ = await billing.purchase(Entitlements.fullGameID)
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

        _ = await service.report(["com.fleon.switchlings.achievement.levels.1": 100], showingBanners: true)
        #expect(await service.load() == ["com.fleon.switchlings.achievement.levels.1": 100])

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
