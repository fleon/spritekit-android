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

    /// Windows of late frames at `frame` it takes to run late for
    /// `sustainedLate` seconds.
    private func sustained(_ frame: Double) -> Int {
        Int((RenderScaleGovernor.sustainedLate / (frame * Double(RenderScaleGovernor.window))).rounded(.up))
    }

    /// A scene start, then its warm-up window.
    private func startScene(_ governor: inout RenderScaleGovernor, frame: Double) -> Bool {
        let changed = governor.startScene()
        for _ in 0..<RenderScaleGovernor.warmUpWindows { window(&governor, frame: frame) }
        return changed
    }

    /// Plays `scenes` scenes of `windows` windows each as a caller does,
    /// frames taking what `device` says at the rung drawn: what's drawn
    /// changes as a scene starts, or at once for a try stepping back or a
    /// step down. Returns the rungs drawn, scene by scene, how often it
    /// stepped down under a scene (a try stepping back as it began aside)
    /// and how often it went up under one.
    private func play(
        _ governor: inout RenderScaleGovernor, scenes: Int, windows: Int = 60,
        device: (Rung) -> Double
    ) -> (drawn: [Rung], downs: Int, ups: Int) {
        var drawn = governor.rung
        var perScene: [Rung] = []
        var downs = 0, ups = 0
        for _ in 0..<scenes {
            governor.startScene()
            drawn = governor.rung
            for index in 0..<windows {
                let frame = device(drawn)
                let changed = window(&governor, frame: frame, budget: 1 / Double(drawn.rate), holding: governor.rung != drawn)
                if changed {
                    let trial = RenderScaleGovernor.warmUpWindows + RenderScaleGovernor.trialWindows
                    if governor.rung.load > drawn.load { ups += 1 } else if !(governor.backedOff && index < trial) { downs += 1 }
                    drawn = governor.rung
                }
            }
            perScene.append(drawn)
        }
        return (perScene, downs, ups)
    }

    // MARK: Scales alone (a picked frame rate)

    @Test("A phone that keeps time stays at full size")
    func keepsTime() {
        var governor = RenderScaleGovernor()
        for _ in 0..<40 { window(&governor, frame: budget) }
        #expect(governor.scale == 1)
    }

    @Test("A late window is a hitch; late for seconds on end, a step down")
    func sustainedLateStepsDown() {
        var governor = RenderScaleGovernor()
        let late = 0.025
        for _ in 0..<(sustained(late) - 1) { #expect(!window(&governor, frame: late)) }
        // On time again: the run starts over.
        window(&governor, frame: budget)
        for _ in 0..<(sustained(late) - 1) { #expect(!window(&governor, frame: late)) }
        #expect(window(&governor, frame: late))
        #expect(governor.scale == 0.875)
        #expect(governor.blockedLoad == 60)
    }

    @Test("A frame the CPU held up doesn't give up pixels")
    func cpuBoundHolds() {
        var governor = RenderScaleGovernor()
        for _ in 0..<(sustained(0.03) * 2) { #expect(!window(&governor, frame: 0.030, cpu: 0.028)) }
        #expect(governor.scale == 1)
    }

    @Test("Frames on time never step up under a scene, only as the next starts")
    func triesUpOnlyAtSceneStart() {
        var governor = RenderScaleGovernor(scale: 0.5)
        for _ in 0..<200 { #expect(!window(&governor, frame: budget)) }
        #expect(governor.scale == 0.5)
        #expect(startScene(&governor, frame: budget))
        #expect(governor.scale == 0.625)
        #expect(governor.tries == 1)
    }

    @Test("A try that runs late steps back at once and isn't tried again")
    func failedTryBlocks() {
        var governor = RenderScaleGovernor(scale: 0.5)
        for _ in 0..<RenderScaleGovernor.patience { window(&governor, frame: budget) }
        #expect(startScene(&governor, frame: budget))
        #expect(window(&governor, frame: 0.025, cpu: 0.024))
        #expect(governor.backedOff)
        #expect(governor.scale == 0.5)
        #expect(governor.failedTries == 1)
        // However long it keeps time after, scene after scene.
        for _ in 0..<20 {
            for _ in 0..<40 { window(&governor, frame: budget) }
            #expect(!startScene(&governor, frame: budget))
        }
        #expect(governor.scale == 0.5)
    }

    @Test("A try that holds through its scene's start stays, and the next scene tries again")
    func climbsBack() {
        var governor = RenderScaleGovernor(scale: 0.75)
        for _ in 0..<2 {
            for _ in 0..<RenderScaleGovernor.patience { window(&governor, frame: budget) }
            #expect(startScene(&governor, frame: budget))
        }
        #expect(governor.scale == 1)
    }

    @Test("A starting scale between steps rounds down to one")
    func startingScale() {
        #expect(RenderScaleGovernor(scale: 0.7).scale == 0.625)
        #expect(RenderScaleGovernor(scale: 0.1).scale == 0.5)
    }

    // MARK: Settling

    @Test("A device just under a rung settles within a few scenes and never flips under one")
    func settles() {
        // 30 at full size holds; 60 at full size runs at 30.
        let device: (Rung) -> Double = { $0.load > 40 ? 1.0 / 30 : 1.0 / Double($0.rate) }
        // From where it settled last launch: one try, then still.
        var measured = RenderScaleGovernor(rates: [60, 30], load: 30)
        let fromLoad = play(&measured, scenes: 12, device: device)
        #expect(fromLoad.downs == 0)
        #expect(fromLoad.ups == 0)
        #expect(measured.tries == 1)
        #expect(measured.failedTries == 1)
        #expect(fromLoad.drawn.suffix(10).allSatisfy { $0 == Rung(rate: 30, scale: 1) })
        // From nothing known: down once, seconds into its first scene, and
        // still.
        var fresh = RenderScaleGovernor(rates: [60, 30])
        let fromNothing = play(&fresh, scenes: 12, device: device)
        #expect(fromNothing.downs == 1)
        #expect(fromNothing.ups == 0)
        #expect(fresh.tries == 0)
        #expect(fromNothing.drawn.dropFirst().allSatisfy { $0 == Rung(rate: 30, scale: 1) })
        // The next launch, the failure kept: no try at all.
        var next = RenderScaleGovernor(rates: [60, 30], load: 45, blocked: measured.blockedLoad)
        _ = play(&next, scenes: 12, device: device)
        #expect(next.tries == 0)
        #expect(next.rung == Rung(rate: 30, scale: 1))
    }

    @Test("A device just under a scale step settles there, scales alone")
    func settlesOnScale() {
        // At 60, every scale above 0.75 runs late.
        let device: (Rung) -> Double = { $0.scale > 0.76 ? 0.025 : 1.0 / 60 }
        var governor = RenderScaleGovernor(rates: [60], scales: RenderScaleGovernor.steps, load: 60 * 0.75 * 0.75)
        let run = play(&governor, scenes: 12, device: device)
        #expect(run.downs == 0)
        #expect(run.ups == 0)
        #expect(governor.tries == 1)
        #expect(run.drawn.suffix(10).allSatisfy { $0.scale == 0.75 })
    }

    @Test("Several rungs too costly: it comes down them within its first scene, then holds")
    func settlesWithinAScene() {
        // As a Galaxy Tab A8 found: only 30 at three quarters keeps time.
        let device: (Rung) -> Double = { $0.load > 17 ? 0.045 : 1.0 / Double($0.rate) }
        var governor = RenderScaleGovernor(rates: [60, 30])
        let run = play(&governor, scenes: 12, device: device)
        #expect(run.drawn.allSatisfy { $0 == Rung(rate: 30, scale: 0.75) })
        #expect(run.downs == 3)
        #expect(run.ups == 0)
        #expect(governor.tries == 0)
    }

    @Test("Hitches now and then never move it")
    func hitches() {
        var governor = RenderScaleGovernor(rates: [60, 30])
        for index in 0..<300 { #expect(!window(&governor, frame: index % 3 == 0 ? 0.05 : budget)) }
        #expect(governor.rung == Rung(rate: 60, scale: 1))
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
        for _ in 0..<sustained(0.025) { window(&governor, frame: 0.025) }
        #expect(governor.rung == Rung(rate: 30, scale: 1))
        var cpuBound = RenderScaleGovernor(rates: [60, 30])
        for _ in 0..<sustained(0.025) { window(&cpuBound, frame: 0.025, cpu: 0.024) }
        #expect(cpuBound.rung == Rung(rate: 30, scale: 1))
        // At 30 a frame on time is 33 ms: it holds.
        for _ in 0..<20 { #expect(!window(&governor, frame: 1.0 / 30)) }
    }

    @Test("Only when 30 at full size doesn't hold does the scale come down")
    func thenScale() {
        var governor = RenderScaleGovernor(rates: [60, 30], load: 30)
        for _ in 0..<sustained(0.05) { window(&governor, frame: 0.050) }
        #expect(governor.rung == Rung(rate: 30, scale: 0.875))
        // CPU-bound at 30: fewer pixels wouldn't help.
        for _ in 0..<(sustained(0.05) * 2) { #expect(!window(&governor, frame: 0.050, cpu: 0.045)) }
    }

    @Test("At 30 it tries 60 as a scene starts, and backs off if that runs late")
    func triesRateUp() {
        var governor = RenderScaleGovernor(rates: [60, 30], load: 30)
        #expect(governor.rung == Rung(rate: 30, scale: 1))
        for _ in 0..<RenderScaleGovernor.patience { window(&governor, frame: 1.0 / 30) }
        #expect(governor.rung == Rung(rate: 30, scale: 1))
        #expect(startScene(&governor, frame: 1.0 / 60))
        #expect(governor.rung == Rung(rate: 60, scale: 1))
        #expect(window(&governor, frame: 0.025))
        #expect(governor.backedOff)
        #expect(governor.rung == Rung(rate: 30, scale: 1))
        #expect(governor.blockedLoad == 60)
    }

    @Test("A faster rate isn't tried while the CPU alone takes longer than its frame")
    func cpuHoldsRate() {
        var governor = RenderScaleGovernor(rates: [60, 30], load: 30)
        for _ in 0..<(RenderScaleGovernor.patience * 2) { #expect(!window(&governor, frame: 1.0 / 30, cpu: 0.020)) }
        let tried = governor.startScene()
        #expect(!tried)
        #expect(governor.rate == 30)
    }

    @Test("A rung waiting to be applied counts windows but judges nothing")
    func holding() {
        var governor = RenderScaleGovernor(rates: [60, 30])
        for _ in 0..<sustained(0.025) { window(&governor, frame: 0.025, cpu: 0.024) }
        let windows = governor.windows
        for _ in 0..<20 { #expect(!window(&governor, frame: 0.050, holding: true)) }
        #expect(governor.rung == Rung(rate: 30, scale: 1))
        #expect(governor.windows == windows + 20)
    }

    @Test("A launch starts at the best rung no costlier than where it settled")
    func startsFromLoad() {
        #expect(RenderScaleGovernor(rates: [60, 30], load: 60).rung == Rung(rate: 60, scale: 1))
        #expect(RenderScaleGovernor(rates: [60, 30], load: 45).rung == Rung(rate: 30, scale: 1))
        #expect(RenderScaleGovernor(rates: [60, 30], load: 17).rung == Rung(rate: 30, scale: 0.75))
        #expect(RenderScaleGovernor(rates: [60, 30], load: 1).rung == Rung(rate: 30, scale: 0.5))
        #expect(RenderScaleGovernor(rates: [60, 30], load: nil).rung == Rung(rate: 60, scale: 1))
        // Short of a rung that ran late lately.
        #expect(RenderScaleGovernor(rates: [60, 30], load: 60, blocked: 60).rung == Rung(rate: 30, scale: 1))
        #expect(RenderScaleGovernor(rates: [60, 30], load: nil, blocked: 30).rung == Rung(rate: 30, scale: 0.875))
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
