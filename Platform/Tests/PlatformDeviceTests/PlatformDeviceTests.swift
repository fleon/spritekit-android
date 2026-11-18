import Foundation
import Testing
@testable import PlatformDevice

/// Values kept in memory, as a game's storage would keep them.
private final class Memory {
    var values: [String: Any] = [:]
    var writes = 0

    var storage: ValueStorage {
        // Held strongly: a test may keep only the storage.
        ValueStorage(
            object: { self.values[$0] },
            set: { value, key in
                self.values[key] = value
                self.writes += 1
            },
            keys: { Array(self.values.keys) }
        )
    }
}

@MainActor
@Suite(.serialized)
struct HapticsTests {
    private func reset(supported: Bool) -> (Memory, () -> [HapticsManager.Feedback]) {
        let memory = Memory()
        var played: [HapticsManager.Feedback] = []
        HapticsManager.storage = memory.storage
        HapticsManager.settingKey = "settings.hapticsEnabled"
        HapticsManager.enabledByDefault = true
        HapticsManager.supported = { supported }
        HapticsManager.player = { played.append($0) }
        return (memory, { played })
    }

    @Test("Feedback plays by default where the device has haptics")
    func onByDefault() {
        let (_, played) = reset(supported: true)
        #expect(HapticsManager.isHapticsEnabled)
        HapticsManager.lightImpact()
        HapticsManager.success()
        HapticsManager.error()
        #expect(played() == [.light, .success, .error])
    }

    @Test("Turned off, nothing plays, and the switch is saved where the game keeps it")
    func switchedOff() {
        let (memory, played) = reset(supported: true)
        HapticsManager.isHapticsEnabled = false
        #expect(memory.values["settings.hapticsEnabled"] as? Bool == false)
        #expect(!HapticsManager.isHapticsEnabled)
        HapticsManager.mediumImpact()
        HapticsManager.selectionChanged()
        #expect(played().isEmpty)
    }

    @Test("Nothing plays where the device has no haptics, whatever the switch says")
    func unsupported() {
        let (memory, played) = reset(supported: false)
        memory.values["settings.hapticsEnabled"] = true
        #expect(!HapticsManager.isHapticsEnabled)
        HapticsManager.softImpact()
        #expect(played().isEmpty)
    }

    @Test("A game's own key and default, and the key it syncs")
    func configured() {
        let (memory, played) = reset(supported: true)
        HapticsManager.settingKey = "game.vibration"
        HapticsManager.enabledByDefault = false
        #expect(!HapticsManager.isHapticsEnabled)
        memory.values["game.vibration"] = true
        HapticsManager.warning()
        #expect(played() == [.warning])
        #expect(HapticsManager.syncedKeys == ["game.vibration": .latest])
    }
}

@MainActor
@Suite(.serialized)
struct ReviewPromptTests {
    @Test("Milestones ask once each, the lowest reached first, and are kept as a list")
    func milestones() {
        let memory = Memory()
        var cleared = 4
        var requests = 0
        ReviewPrompt.requestReview = {
            requests += 1
            return true
        }
        let prompt = ReviewPrompt(key: "review.milestones", rule: .milestones([10, 5, 20], progress: { cleared }), storage: memory.storage)

        #expect(!prompt.isDue)
        cleared = 12
        #expect(prompt.pendingMilestone == 5)
        #expect(prompt.requestIfDue())
        #expect(memory.values["review.milestones"] as? [Int] == [5])
        #expect(prompt.requestIfDue())
        #expect(memory.values["review.milestones"] as? [Int] == [5, 10])
        #expect(!prompt.requestIfDue())
        cleared = 25
        #expect(prompt.requestIfDue())
        #expect(requests == 3)
        #expect(!prompt.isDue)
    }

    @Test("Play time asks once, after the minimum")
    func playTime() {
        let memory = Memory()
        var played: TimeInterval = 60
        ReviewPrompt.requestReview = { true }
        let prompt = ReviewPrompt(key: "review.asked", rule: .playTime(minimum: 300, total: { played }), storage: memory.storage)

        #expect(!prompt.requestIfDue())
        played = 301
        #expect(prompt.requestIfDue())
        #expect(memory.values["review.asked"] as? Bool == true)
        played = 10_000
        #expect(!prompt.isDue)
    }

    @Test("Nothing is recorded when nothing could show the card, or the game holds prompts back")
    func notAsked() {
        let memory = Memory()
        ReviewPrompt.requestReview = { false }
        let prompt = ReviewPrompt(key: "review.once", rule: .once { true }, storage: memory.storage)
        #expect(!prompt.requestIfDue())
        #expect(memory.values.isEmpty)

        ReviewPrompt.requestReview = { true }
        let held = ReviewPrompt(key: "review.once", rule: .once { true }, storage: memory.storage, isEnabled: { false })
        #expect(!held.isDue)
    }

    @Test("A snooze holds the prompt back until it ends")
    func snooze() {
        let memory = Memory()
        var now = Date(timeIntervalSince1970: 1_000)
        let prompt = ReviewPrompt(key: "review.flow", rule: .once { true }, storage: memory.storage, now: { now })
        #expect(prompt.isDue)

        prompt.snooze(for: 3 * 86_400)
        #expect(!prompt.isDue)
        now = Date(timeIntervalSince1970: 1_000 + 3 * 86_400 + 1)
        #expect(prompt.isDue)
        prompt.markRequested()
        #expect(!prompt.isDue)
    }
}

@MainActor
struct AppUsageTrackerTests {
    @Test("Play time adds up this device's sessions and every other device's")
    func total() {
        let memory = Memory()
        memory.values["usage.other-device"] = 120.0
        memory.values["unrelated"] = 999.0
        let deviceDefaults = UserDefaults(suiteName: UUID().uuidString)!
        var now = Date(timeIntervalSince1970: 0)
        let tracker = AppUsageTracker(
            storage: memory.storage, keyPrefix: "usage.", deviceDefaults: deviceDefaults, checkpointInterval: nil, now: { now }
        )

        tracker.startTracking()
        now = Date(timeIntervalSince1970: 30)
        #expect(tracker.liveTotalSeconds == 150)
        tracker.stopTracking()
        now = Date(timeIntervalSince1970: 500)
        #expect(tracker.totalSeconds == 150)

        tracker.startTracking()
        now = Date(timeIntervalSince1970: 510)
        #expect(tracker.totalSeconds == 160)
        #expect(memory.values.keys.filter { $0.hasPrefix("usage.") }.count == 2)
    }
}
