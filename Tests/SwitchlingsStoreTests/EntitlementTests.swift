import Foundation
import Testing
@testable import SwitchlingsStore

// What Switchlings asks of a store, with no store behind it: is the full game
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

@Suite("Pre-registration reward")
struct MainframeRewardTests {
    @Test("Play's reward keeps the secret worlds without the full game")
    func rewardAlone() {
        let entitlements = Entitlements(defaults: scratchDefaults())
        #expect(entitlements.keepsSecretWorlds(owns: false, rewarded: true))
    }

    @Test("The reward keeps them after the launch event, however late the full game was bought")
    func rewardAfterEvent() {
        let entitlements = Entitlements(defaults: scratchDefaults())
        entitlements.noteBought(at: Entitlements.launchEventEnd.addingTimeInterval(60 * 60 * 24 * 30))
        #expect(entitlements.keepsSecretWorlds(owns: true) == false)
        #expect(entitlements.keepsSecretWorlds(owns: true, rewarded: true))
    }

    @Test("The notice is shown once")
    func announcedOnce() {
        let defaults = scratchDefaults()
        #expect(Entitlements(defaults: defaults).rewardAnnounced == false)
        Entitlements(defaults: defaults).rewardAnnounced = true
        #expect(Entitlements(defaults: defaults).rewardAnnounced)
    }
}

@Suite("Claiming the pre-registration reward")
struct RewardClaimTests {
    @Test("While the launch event runs, the reward counts only once claimed")
    func claimDuringEvent() {
        let defaults = scratchDefaults()
        let entitlements = Entitlements(defaults: defaults)
        #expect(entitlements.rewardCounts(owned: true, eventRunning: true) == false)
        entitlements.rewardClaimed = true
        #expect(Entitlements(defaults: defaults).rewardCounts(owned: true, eventRunning: true))
    }

    @Test("Once the event is over, an unclaimed reward counts anyway, and no reward never does")
    func afterEvent() {
        let entitlements = Entitlements(defaults: scratchDefaults())
        #expect(entitlements.rewardCounts(owned: true, eventRunning: false))
        #expect(entitlements.rewardCounts(owned: false, eventRunning: false) == false)
        entitlements.rewardClaimed = true
        #expect(entitlements.rewardCounts(owned: false, eventRunning: true) == false)
    }
}
