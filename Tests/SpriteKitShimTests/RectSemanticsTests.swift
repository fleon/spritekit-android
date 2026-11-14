#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import SpriteKitShim

/// `RectSemantics`, which Android's `CGRect` answers with, against the host's
/// own CoreGraphics: the same answer for every pair.
final class RectSemanticsTests: XCTestCase {
    private func same(_ a: CGRect, _ b: CGRect) -> Bool { a == b || (a.isNull && b.isNull) }

    func testEveryEdgeCaseOnAGridMatchesCoreGraphics() {
        var rects: [CGRect] = [.null, .infinite, .zero]
        for x: CGFloat in [0, 1, 2, 3] {
            for width: CGFloat in [0, 1, 2, -1] {
                for y: CGFloat in [0, 2] {
                    for height: CGFloat in [0, 2, -1] { rects.append(CGRect(x: x, y: y, width: width, height: height)) }
                }
            }
        }
        for a in rects {
            for b in rects {
                XCTAssertEqual(RectSemantics.intersects(a, b), a.intersects(b), "\(a) intersects \(b)")
                XCTAssertTrue(same(RectSemantics.intersection(a, b), a.intersection(b)), "\(a) ∩ \(b)")
                XCTAssertEqual(RectSemantics.contains(a, b), a.contains(b), "\(a) contains \(b)")
            }
        }
    }

    func testFractionalRectsSharingEdgesMatchCoreGraphics() {
        var random = SystemRandomNumberGenerator()
        let grid: [CGFloat] = (0..<12).map { CGFloat($0) * 0.1 } + [1.0 / 3, 2.0 / 3]
        func pick() -> CGFloat { grid.randomElement(using: &random)! + (Bool.random(using: &random) ? 0 : .random(in: -0.05...0.05, using: &random)) }
        for _ in 0..<50_000 {
            let a = CGRect(x: pick(), y: pick(), width: pick() - 0.4, height: pick() - 0.4)
            let b = CGRect(x: pick(), y: pick(), width: pick() - 0.4, height: pick() - 0.4)
            XCTAssertEqual(RectSemantics.intersects(a, b), a.intersects(b), "\(a) intersects \(b)")
            XCTAssertTrue(same(RectSemantics.intersection(a, b), a.intersection(b)), "\(a) ∩ \(b)")
            XCTAssertEqual(RectSemantics.contains(a, b), a.contains(b), "\(a) contains \(b)")
        }
    }

    func testTouchingRectsDoNotIntersectAndARectHoldsItself() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertFalse(RectSemantics.intersects(a, CGRect(x: 10, y: 0, width: 10, height: 10)))
        // maxX − minX rounds: 0.30000000000000004 − 0.1 isn't 0.2.
        let odd = CGRect(x: 0.1, y: 0, width: 0.2, height: 1)
        XCTAssertTrue(RectSemantics.contains(odd, odd))
    }
}
#endif
