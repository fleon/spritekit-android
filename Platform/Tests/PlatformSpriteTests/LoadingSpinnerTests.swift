import CoreGraphics
import Foundation
import Testing
@testable import PlatformSprite

/// The spinner's arc: out to the whole ring by halfway through a period,
/// then back to nothing.
struct LoadingSpinnerTests {
    @Test("It starts and ends a period at nothing, and closes the ring halfway")
    func endsAndMiddle() {
        #expect(LoadingSpinnerSweep.angle(at: 0) == 0)
        #expect(abs(LoadingSpinnerSweep.angle(at: 0.5) - .pi * 2) < 1e-9)
        #expect(abs(LoadingSpinnerSweep.angle(at: 1)) < 1e-9)
    }

    @Test("It grows at a steady pace and shrinks at the same")
    func steady() {
        #expect(abs(LoadingSpinnerSweep.angle(at: 0.25) - .pi) < 1e-9)
        #expect(abs(LoadingSpinnerSweep.angle(at: 0.75) - .pi) < 1e-9)
    }

    @Test("Progress past either end holds there")
    func clamped() {
        #expect(LoadingSpinnerSweep.angle(at: -1) == 0)
        #expect(abs(LoadingSpinnerSweep.angle(at: 2)) < 1e-9)
    }
}
