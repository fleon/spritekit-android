import Foundation
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

/// How much the splash grows or shrinks: laid out for the iPhone 16 Pro
/// (393 × 852, turned when the view is landscape) and fitted to the view.
struct StudioSplashScaleTests {
    @Test("The design's own size is 1")
    func designSize() {
        #expect(studioSplashScale(for: CGSize(width: 393, height: 852)) == 1)
    }

    @Test("A larger phone grows by its tighter side")
    func phone() {
        // iPhone 16 Pro Max: 440 / 393 ≈ 1.120, 956 / 852 ≈ 1.122.
        let scale = studioSplashScale(for: CGSize(width: 440, height: 956))
        #expect(abs(scale - 440.0 / 393.0) < 0.0001)
    }

    @Test("An iPad fits by its height, so nothing crops")
    func iPad() {
        // iPad Pro 13": 1032 / 393 ≈ 2.63, 1376 / 852 ≈ 1.62.
        let scale = studioSplashScale(for: CGSize(width: 1032, height: 1376))
        #expect(abs(scale - 1376.0 / 852.0) < 0.0001)
    }

    @Test("Landscape turns the design, so a turned view scales as it did upright")
    func landscape() {
        let upright = studioSplashScale(for: CGSize(width: 1032, height: 1376))
        let turned = studioSplashScale(for: CGSize(width: 1376, height: 1032))
        #expect(upright == turned)
        #expect(studioSplashScale(for: CGSize(width: 852, height: 393)) == 1)
    }

    @Test("A TV fits the turned design by its width")
    func tv() {
        // 1920 × 1080 against 852 × 393: 2.25 across, 2.75 down.
        let scale = studioSplashScale(for: CGSize(width: 1920, height: 1080))
        #expect(abs(scale - 1920.0 / 852.0) < 0.0001)
    }

    @Test("An empty view leaves sizes as given")
    func empty() {
        #expect(studioSplashScale(for: .zero) == 1)
    }
}
