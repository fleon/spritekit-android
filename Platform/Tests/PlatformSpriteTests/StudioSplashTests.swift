import Testing
@testable import PlatformSprite

/// The splash's timing: at least the minimum, until everything it waits for
/// is ready, never past the maximum, and done only once.
struct StudioSplashTests {
    @Test("With nothing to wait for, it's done once the minimum has passed")
    func minimumAlone() {
        var gate = StudioSplashGate()
        let done1 = gate.minimumElapsed()
        #expect(done1)
        #expect(gate.finished)
    }

    @Test("It holds past the minimum until every condition is ready")
    func waitsForConditions() {
        var gate = StudioSplashGate(waitingFor: ["gameCenter", "feed"])
        let done2 = gate.minimumElapsed()
        #expect(!done2)
        let done3 = gate.ready("feed")
        #expect(!done3)
        let done4 = gate.ready("gameCenter")
        #expect(done4)
        #expect(gate.pending.isEmpty)
    }

    @Test("Conditions ready before the minimum wait for it")
    func readyEarly() {
        var gate = StudioSplashGate(waitingFor: ["gameCenter"])
        let done5 = gate.ready("gameCenter")
        #expect(!done5)
        let done6 = gate.minimumElapsed()
        #expect(done6)
    }

    @Test("The maximum ends it whatever it still waits for, and only once")
    func maximum() {
        var gate = StudioSplashGate(waitingFor: ["gameCenter"])
        let done7 = gate.minimumElapsed()
        #expect(!done7)
        let done8 = gate.maximumElapsed()
        #expect(done8)
        let done9 = gate.ready("gameCenter")
        #expect(!done9)
        let done10 = gate.maximumElapsed()
        #expect(!done10)
    }

    @Test("A condition it doesn't wait for changes nothing")
    func unknownCondition() {
        var gate = StudioSplashGate(waitingFor: ["gameCenter"])
        let done11 = gate.minimumElapsed()
        #expect(!done11)
        let done12 = gate.ready("somethingElse")
        #expect(!done12)
        #expect(gate.pending == ["gameCenter"])
    }
}
