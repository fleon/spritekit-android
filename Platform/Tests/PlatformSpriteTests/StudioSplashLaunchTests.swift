import Foundation
import Testing
@testable import PlatformSprite

/// A launch's steps, as a view controller's layouts and appearing drive
/// them: presented once on a real size, begun once both shown and
/// appeared, with what was ready meanwhile, and handed off once.
struct StudioSplashLaunchStepsTests {
    @Test("The splash waits for the view's first real size, and is presented once")
    func presentsOnce() {
        var steps = StudioSplashLaunchSteps()
        let empty = steps.layout(hasSize: false)
        #expect(!empty)
        let first = steps.layout(hasSize: true)
        #expect(first)
        let again = steps.layout(hasSize: true)
        #expect(!again)
    }

    @Test("Its clock begins once it shows and the view has appeared, in that order")
    func shownThenAppeared() {
        var steps = StudioSplashLaunchSteps()
        _ = steps.layout(hasSize: true)
        let shown = steps.shown()
        #expect(shown == nil)
        let appeared = steps.appeared()
        #expect(appeared.startWaits)
        #expect(appeared.begin == [])
        #expect(steps.hasBegun)
    }

    @Test("…or the other way round (a splash that waits for its logo)")
    func appearedThenShown() {
        var steps = StudioSplashLaunchSteps()
        _ = steps.layout(hasSize: true)
        let appeared = steps.appeared()
        #expect(appeared.startWaits)
        #expect(appeared.begin == nil)
        let shown = steps.shown()
        #expect(shown == [])
    }

    @Test("What's ready before the splash shows is handed to it as it begins")
    func readyEarly() {
        var steps = StudioSplashLaunchSteps()
        let appeared = steps.appeared()
        #expect(appeared.begin == nil)
        let heard = steps.ready("service")
        #expect(!heard)
        _ = steps.layout(hasSize: true)
        let shown = steps.shown()
        #expect(shown == ["service"])
        let later = steps.ready("feed")
        #expect(later)
    }

    @Test("Appearing again starts nothing again")
    func appearsTwice() {
        var steps = StudioSplashLaunchSteps()
        _ = steps.layout(hasSize: true)
        _ = steps.shown()
        _ = steps.appeared()
        let again = steps.appeared()
        #expect(!again.startWaits)
        #expect(again.begin == nil)
    }

    @Test("The hand-off happens once")
    func handOffOnce() {
        var steps = StudioSplashLaunchSteps()
        let first = steps.handOff()
        #expect(first)
        let second = steps.handOff()
        #expect(!second)
    }
}
