import GLESRenderer
import Testing

@Suite("Render scale and frame rate")
struct RenderScaleGovernorTests {
    private typealias Rung = RenderScaleGovernor.Rung
    private let budget = 1.0 / 60

    /// Feeds one window of frames, each `frame` long with `cpu` of it the CPU's.
    @discardableResult
    private func window(_ governor: inout RenderScaleGovernor, frame: Double, cpu: Double = 0.005, budget: Double? = nil, holding: Bool = false) -> Bool {
        var changed = false
        for _ in 0..<RenderScaleGovernor.window {
            changed = governor.add(frame: frame, cpu: cpu, budget: budget ?? 1 / Double(governor.rate), holding: holding) || changed
        }
        return changed
    }

    // MARK: Scales alone (a picked frame rate)

    @Test("A phone that keeps time stays at full size")
    func keepsTime() {
        var governor = RenderScaleGovernor()
        for _ in 0..<40 { window(&governor, frame: budget) }
        #expect(governor.scale == 1)
    }

    @Test("Late frames step down a step at a time, to the smallest")
    func lateStepsDown() {
        var governor = RenderScaleGovernor()
        #expect(window(&governor, frame: 0.052))
        #expect(governor.scale == 0.875)
        for _ in 0..<10 { window(&governor, frame: 0.030) }
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
        #expect(governor.scale == 0.625)
        // The try runs late, even CPU-bound: back down, then a longer wait.
        #expect(window(&governor, frame: 0.025, cpu: 0.024))
        #expect(governor.scale == 0.5)
        #expect(governor.backedOff)
        for _ in 0..<(2 * RenderScaleGovernor.patience - 1) { #expect(!window(&governor, frame: budget)) }
        #expect(window(&governor, frame: budget))
        #expect(governor.scale == 0.625)
    }

    @Test("From a lower start, frames on time try their way back to full size")
    func climbsBack() {
        var governor = RenderScaleGovernor(scale: 0.75)
        for _ in 0..<40 { window(&governor, frame: budget) }
        #expect(governor.scale == 1)
    }

    @Test("A starting scale between steps rounds down to one")
    func startingScale() {
        #expect(RenderScaleGovernor(scale: 0.7).scale == 0.625)
        #expect(RenderScaleGovernor(scale: 0.1).scale == 0.5)
    }

    // MARK: Rates Auto offers

    @Test("Auto offers the rates each screen paces evenly, none above 60")
    func autoRates() {
        #expect(RenderScaleGovernor.autoRates(refresh: 60) == [60, 30])
        #expect(RenderScaleGovernor.autoRates(refresh: 120) == [60, 40, 30])
        #expect(RenderScaleGovernor.autoRates(refresh: 50) == [50, 25])
        #expect(RenderScaleGovernor.autoRates(refresh: 90) == [60, 45, 30])
        #expect(RenderScaleGovernor.autoRates(refresh: 144) == [60, 48, 36, 30])
        // The Apple TV HD's Auto stops at 30.
        #expect(RenderScaleGovernor.autoRates(refresh: 60, ceiling: 30) == [30])
        #expect(RenderScaleGovernor.autoRates(refresh: 50, ceiling: 30) == [25])
    }

    @Test("In Low Power Mode a 120 Hz screen paces as 60 Hz: 60 and 30, never 40")
    func lowPowerRates() {
        #expect(RenderScaleGovernor.autoRates(refresh: 120, lowPower: true) == [60, 30])
        #expect(RenderScaleGovernor.pacedRefresh(120, lowPower: true) == 60)
        // Screens at 60 Hz or slower are as they were.
        #expect(RenderScaleGovernor.autoRates(refresh: 60, lowPower: true) == [60, 30])
        #expect(RenderScaleGovernor.autoRates(refresh: 50, lowPower: true) == [50, 25])
        #expect(RenderScaleGovernor.pacedRefresh(120, lowPower: false) == 120)
    }

    @Test("The ladder keeps every pixel while the rate drops, then shrinks at the slowest")
    func ladder() {
        let ladder = RenderScaleGovernor.ladder(rates: [60, 40, 30], scales: [1, 0.85, 0.75, 0.5])
        #expect(ladder == [
            Rung(rate: 60, scale: 1), Rung(rate: 40, scale: 1), Rung(rate: 30, scale: 1),
            Rung(rate: 30, scale: 0.85), Rung(rate: 30, scale: 0.75), Rung(rate: 30, scale: 0.5),
        ])
        // Each rung asks less of the GPU than the one above it, at every step.
        for rates in [[60, 30], [60, 40, 30], [50, 25], [60, 48, 36, 30]] {
            let full = RenderScaleGovernor.ladder(rates: rates, scales: RenderScaleGovernor.steps)
            #expect(zip(full, full.dropFirst()).allSatisfy { $0.load > $1.load })
        }
        // A picked side: its value alone.
        #expect(RenderScaleGovernor.ladder(rates: [60], scales: [1, 0.85, 0.75]) == [Rung(rate: 60, scale: 1), Rung(rate: 60, scale: 0.85), Rung(rate: 60, scale: 0.75)])
        #expect(RenderScaleGovernor.ladder(rates: [60, 30], scales: [0.75]) == [Rung(rate: 60, scale: 0.75), Rung(rate: 30, scale: 0.75)])
    }

    // MARK: Both on Auto

    @Test("Late at 60 at full size gives up the rate first, even CPU-bound")
    func rateFirst() {
        var governor = RenderScaleGovernor(rates: [60, 30])
        #expect(window(&governor, frame: 0.025))
        #expect(governor.rung == Rung(rate: 30, scale: 1))
        var cpuBound = RenderScaleGovernor(rates: [60, 30])
        #expect(window(&cpuBound, frame: 0.025, cpu: 0.024))
        #expect(cpuBound.rung == Rung(rate: 30, scale: 1))
        // At 30 a frame on time is 33 ms: it holds.
        for _ in 0..<4 { #expect(!window(&governor, frame: 1.0 / 30)) }
    }

    @Test("Only when 30 at full size doesn't hold does the scale come down")
    func thenScale() {
        var governor = RenderScaleGovernor(rates: [60, 30])
        window(&governor, frame: 0.040)
        #expect(governor.rung == Rung(rate: 30, scale: 1))
        window(&governor, frame: 0.050)
        #expect(governor.rung == Rung(rate: 30, scale: 0.875))
        // CPU-bound at 30: fewer pixels wouldn't help.
        #expect(!window(&governor, frame: 0.050, cpu: 0.045))
    }

    @Test("At 30 it tries 60 again, and backs off if that runs late")
    func triesRateUp() {
        var governor = RenderScaleGovernor(rates: [60, 30], load: 30)
        #expect(governor.rung == Rung(rate: 30, scale: 1))
        for _ in 0..<RenderScaleGovernor.patience { window(&governor, frame: 1.0 / 30) }
        #expect(governor.rung == Rung(rate: 60, scale: 1))
        #expect(window(&governor, frame: 0.025))
        #expect(governor.backedOff)
        #expect(governor.rung == Rung(rate: 30, scale: 1))
    }

    @Test("A faster rate isn't tried while the CPU alone takes longer than its frame")
    func cpuHoldsRate() {
        var governor = RenderScaleGovernor(rates: [60, 30], load: 30)
        for _ in 0..<(RenderScaleGovernor.patience * 2) { #expect(!window(&governor, frame: 1.0 / 30, cpu: 0.020)) }
        #expect(governor.rate == 30)
    }

    @Test("A rung waiting to be applied counts windows but judges nothing")
    func holding() {
        var governor = RenderScaleGovernor(rates: [60, 30])
        window(&governor, frame: 0.025, cpu: 0.024)
        let windows = governor.windows
        #expect(!window(&governor, frame: 0.050, holding: true))
        #expect(governor.rung == Rung(rate: 30, scale: 1))
        #expect(governor.windows == windows + 1)
    }

    @Test("A launch starts at the best rung no costlier than where it settled")
    func startsFromLoad() {
        #expect(RenderScaleGovernor(rates: [60, 30], load: 60).rung == Rung(rate: 60, scale: 1))
        #expect(RenderScaleGovernor(rates: [60, 30], load: 45).rung == Rung(rate: 30, scale: 1))
        #expect(RenderScaleGovernor(rates: [60, 30], load: 17).rung == Rung(rate: 30, scale: 0.75))
        #expect(RenderScaleGovernor(rates: [60, 30], load: 1).rung == Rung(rate: 30, scale: 0.5))
        #expect(RenderScaleGovernor(rates: [60, 30], load: nil).rung == Rung(rate: 60, scale: 1))
    }

    @Test("A pick takes its side at once and keeps the other where it stood")
    func picks() {
        let here = Rung(rate: 30, scale: 0.75)
        // A picked rate: the scale stays.
        #expect(RenderScaleGovernor(rates: [60], near: here).rung == Rung(rate: 60, scale: 0.75))
        #expect(RenderScaleGovernor(rates: [120], near: Rung(rate: 60, scale: 1)).rung == Rung(rate: 120, scale: 1))
        // A picked quality: the rate stays.
        #expect(RenderScaleGovernor(rates: [60, 30], scales: [1], near: here).rung == Rung(rate: 30, scale: 1))
        // Auto again: from where it stands.
        #expect(RenderScaleGovernor(rates: [60, 30], near: here).rung == here)
    }
}
