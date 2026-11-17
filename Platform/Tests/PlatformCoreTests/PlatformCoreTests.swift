import Foundation
import Testing
@testable import PlatformCore

struct GeometryTests {
    @Test func shorthandsMatchTheInitializers() {
        #expect(pt(1, 2) == CGPoint(x: 1, y: 2))
        #expect(sz(3) == CGSize(width: 3, height: 3))
        #expect(rect(sz(4, 5)) == CGRect(x: 0, y: 0, width: 4, height: 5))
        #expect(rect(10, 20).anchor(0.5) == CGRect(x: -5, y: -10, width: 10, height: 20))
    }

    @Test func lerpAndUnlerpUndoEachOther() {
        let value = CGFloat(0.25).lerp(10, 30)
        #expect(value == 15)
        #expect(value.unlerp(10, 30) == 0.25)
        #expect(CGFloat(2).clamp(0, 1) == 1)
        #expect(pt(5, -5).clamp(pt(0, 0), pt(1, 1)) == pt(1, 0))
    }
}

struct TimingCurveTests {
    @Test func curvesRunFromZeroToOne() {
        for curve in [TimingCurve.linear, .easeIn, .easeOut, .easeInOut, .cssEaseOut, .quintOut, .backOut, .backIn, .backInOut] {
            #expect(abs(curve(0)) < 1e-4)
            #expect(abs(curve(1) - 1) < 1e-4)
        }
    }

    @Test func bezierMatchesCSSEase() {
        // CSS `ease-in-out` at half time is half way, by symmetry.
        #expect(abs(TimingCurve.easeInOut(0.5) - 0.5) < 1e-4)
        #expect(TimingCurve.backOut(0.8) > 1)
    }
}

struct RandomTests {
    @Test func seededStreamsRepeatAndDiffer() {
        Random.seed = 7
        defer { Random.seed = nil }
        var a = Random("a"), again = Random("a"), b = Random("b")
        let first = (0..<4).map { _ in a.next() }
        #expect(first == (0..<4).map { _ in again.next() })
        #expect(first != (0..<4).map { _ in b.next() })
    }
}
