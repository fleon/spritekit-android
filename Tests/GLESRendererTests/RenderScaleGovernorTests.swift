import GLESRenderer
import Testing

@Suite("Auto's render scale")
struct RenderScaleGovernorTests {
    private let budget = 1.0 / 60

    /// Feeds frames `frame` long until the governor chooses or `seconds` of
    /// frames pass, a scene starting every `sceneSeconds`. Returns the
    /// seconds fed when it chose, nil if it didn't.
    @discardableResult
    private func play(_ governor: inout RenderScaleGovernor, seconds: Double, sceneSeconds: Double = 40, frame: (Double) -> Double) -> Double? {
        var time = 0.0, sceneTime = 0.0
        governor.startScene()
        while time < seconds {
            let length = frame(time)
            if governor.add(frame: length, budget: budget) { return time + length }
            time += length
            sceneTime += length
            if sceneTime >= sceneSeconds {
                sceneTime = 0
                governor.startScene()
            }
        }
        return nil
    }

    @Test("Auto chooses between Highest and Medium, at its rate alone")
    func autoSteps() {
        #expect(RenderScaleGovernor.autoSteps == [1, 0.875, 0.75])
        let governor = RenderScaleGovernor(rate: 60)
        #expect(governor.rate == 60)
        #expect(governor.scale == 1)
        #expect(!governor.isDecided)
    }

    @Test("A device on time keeps Highest, chosen after a minute")
    func onTime() throws {
        var governor = RenderScaleGovernor(rate: 60)
        let chosen = try #require(play(&governor, seconds: 600) { _ in budget })
        #expect(chosen >= RenderScaleGovernor.shortestMeasure)
        #expect(chosen < RenderScaleGovernor.shortestMeasure + 2)
        #expect(governor.isDecided)
        #expect(governor.scale == 1)
    }

    @Test("Late frames choose the largest scale that would fit, never below Medium")
    func choosesByDemand() {
        // 20% over the budget: High's 77% of the pixels fits.
        var high = RenderScaleGovernor(rate: 60)
        play(&high, seconds: 600) { _ in budget * 1.2 }
        #expect(high.scale == 0.875)
        // 60% over: Medium's 56% fits.
        var medium = RenderScaleGovernor(rate: 60)
        play(&medium, seconds: 600) { _ in budget * 1.6 }
        #expect(medium.scale == 0.75)
        // Three times over: nothing fits, Medium is the floor.
        var floor = RenderScaleGovernor(rate: 60)
        play(&floor, seconds: 600) { _ in budget * 3 }
        #expect(floor.scale == 0.75)
        #expect(floor.rate == 60)
    }

    @Test("Frames on whole refreshes judge by their mean")
    func pacedFrames() {
        // A GPU taking 1.25 budgets: every fourth frame waits a refresh more,
        // a mean of 1.25 budgets. High fits.
        var frames = 0
        var governor = RenderScaleGovernor(rate: 60)
        play(&governor, seconds: 600) { _ in
            frames += 1
            return frames % 4 == 0 ? 2 * budget : budget
        }
        #expect(governor.scale == 0.875)
    }

    @Test("A choice that's still changing waits until it settles")
    func unsettled() throws {
        // On time for the first 30 seconds, then late: at a minute the first
        // half and the whole disagree, so it measures on until they don't.
        var governor = RenderScaleGovernor(rate: 60)
        let chosen = try #require(play(&governor, seconds: 600) { $0 < 30 ? budget : budget * 1.6 })
        #expect(chosen > RenderScaleGovernor.shortestMeasure + 10)
        #expect(chosen <= RenderScaleGovernor.longestMeasure + 2)
        #expect(governor.scale == 0.75)
    }

    @Test("By three minutes it has chosen, settled or not")
    func longest() throws {
        // Late more and more: the heavier windows keep getting heavier.
        var governor = RenderScaleGovernor(rate: 60)
        let chosen = try #require(play(&governor, seconds: 600) { budget * (1 + $0 / 100) })
        #expect(chosen <= RenderScaleGovernor.longestMeasure + 2)
    }

    @Test("Once chosen, nothing moves it again")
    func neverAgain() {
        var governor = RenderScaleGovernor(rate: 60)
        play(&governor, seconds: 600) { _ in budget }
        #expect(governor.scale == 1)
        #expect(play(&governor, seconds: 600) { _ in budget * 3 } == nil)
        #expect(governor.scale == 1)
    }

    @Test("A choice kept from before stands, rounded down to a step")
    func decided() {
        var governor = RenderScaleGovernor(rate: 60, decided: 0.8)
        #expect(governor.isDecided)
        #expect(governor.scale == 0.75)
        #expect(play(&governor, seconds: 600) { _ in budget } == nil)
        #expect(governor.scale == 0.75)
    }

    @Test("A picked scale is the only one: nothing to choose")
    func picked() {
        let governor = RenderScaleGovernor(rate: 60, scales: [0.625])
        #expect(governor.isDecided)
        #expect(governor.scale == 0.625)
    }

    @Test("Stalls and scene starts say nothing of the pixels")
    func stalls() {
        // A half-second stall every scene start, otherwise on time.
        var governor = RenderScaleGovernor(rate: 60)
        var since = 0.0
        play(&governor, seconds: 600, sceneSeconds: 10) { time in
            defer { since = time }
            return Int(time / 10) != Int(since / 10) ? 0.5 : budget
        }
        #expect(governor.scale == 1)
    }

    @Test("Auto's rate is the fastest the screen paces evenly, none above 60")
    func autoRates() {
        #expect(RenderScaleGovernor.autoRates(refresh: 60).first == 60)
        #expect(RenderScaleGovernor.autoRates(refresh: 120).first == 60)
        #expect(RenderScaleGovernor.autoRates(refresh: 50).first == 50)
        #expect(RenderScaleGovernor.autoRates(refresh: 90).first == 60)
        #expect(RenderScaleGovernor.autoRates(refresh: 144).first == 60)
        #expect(RenderScaleGovernor.autoRates(refresh: 120, lowPower: true).first == 60)
        #expect(RenderScaleGovernor.pacedRefresh(120, lowPower: true) == 60)
        #expect(RenderScaleGovernor.pacedRefresh(120, lowPower: false) == 120)
    }
}
