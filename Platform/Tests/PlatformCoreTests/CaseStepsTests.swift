import Testing
@testable import PlatformCore

private enum Speed: CaseIterable {
    case slow, normal, fast
}

struct CaseStepsTests {
    @Test func indexAndBack() {
        #expect(Speed.slow.index == 0)
        #expect(Speed.fast.index == 2)
        #expect(Speed.at(1) == .normal)
        #expect(Speed.at(3) == nil)
        #expect(Speed.at(-1) == nil)
    }

    @Test func stepsWrapByDefault() {
        #expect(Speed.slow.next() == .normal)
        #expect(Speed.fast.next() == .slow)
        #expect(Speed.slow.previous() == .fast)
        #expect(Speed.normal.previous() == .slow)
    }

    @Test func stepsHoldAtTheEndsWhenNotWrapping() {
        #expect(Speed.fast.next(wrapping: false) == .fast)
        #expect(Speed.slow.previous(wrapping: false) == .slow)
        #expect(Speed.slow.next(wrapping: false) == .normal)
    }
}
