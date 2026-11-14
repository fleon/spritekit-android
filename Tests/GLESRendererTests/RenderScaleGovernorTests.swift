import GLESRenderer
import Testing

@Suite("Render scale")
struct RenderScaleGovernorTests {
    private let budget = 1.0 / 60

    /// Feeds one window of frames, each `frame` long with `cpu` of it the CPU's.
    private func window(_ governor: inout RenderScaleGovernor, frame: Double, cpu: Double = 0.005) -> Bool {
        var changed = false
        for _ in 0..<RenderScaleGovernor.window {
            changed = governor.add(frame: frame, cpu: cpu, budget: budget) || changed
        }
        return changed
    }

    @Test("A phone that keeps time stays at full size")
    func keepsTime() {
        var governor = RenderScaleGovernor()
        for _ in 0..<40 { _ = window(&governor, frame: budget) }
        #expect(governor.scale == 1)
    }

    @Test("Late frames step down a step at a time, to the smallest")
    func lateStepsDown() {
        var governor = RenderScaleGovernor()
        #expect(window(&governor, frame: 0.052))
        #expect(governor.scale == 0.85)
        for _ in 0..<10 { _ = window(&governor, frame: 0.030) }
        #expect(governor.scale == 0.5)
    }

    @Test("A frame the CPU held up doesn't give up pixels")
    func cpuBoundHolds() {
        var governor = RenderScaleGovernor()
        #expect(!window(&governor, frame: 0.030, cpu: 0.028))
        #expect(governor.scale == 1)
    }

    @Test("Frames on time try a step up, and a failed try waits twice as long")
    func triesUp() {
        var governor = RenderScaleGovernor(scale: 0.5)
        for _ in 0..<(RenderScaleGovernor.patience - 1) { #expect(!window(&governor, frame: budget)) }
        #expect(window(&governor, frame: budget))
        #expect(governor.scale == 0.58)
        // The try runs late, even CPU-bound: back down, then a longer wait.
        #expect(window(&governor, frame: 0.025, cpu: 0.024))
        #expect(governor.scale == 0.5)
        for _ in 0..<(2 * RenderScaleGovernor.patience - 1) { #expect(!window(&governor, frame: budget)) }
        #expect(window(&governor, frame: budget))
        #expect(governor.scale == 0.58)
    }

    @Test("A starting scale between steps rounds down to one")
    func startingScale() {
        #expect(RenderScaleGovernor(scale: 0.7).scale == 0.67)
        #expect(RenderScaleGovernor(scale: 0.1).scale == 0.5)
    }
}
