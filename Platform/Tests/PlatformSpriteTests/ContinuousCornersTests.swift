import CoreGraphics
import Foundation
import Testing
@testable import PlatformSprite

/// The points each curve of a path ends at, and its control points, in order.
private func curves(_ path: CGPath) -> [[CGPoint]] {
    var found: [[CGPoint]] = []
    path.applyWithBlock { element in
        let e = element.pointee
        if e.type == .addCurveToPoint { found.append([e.points[0], e.points[1], e.points[2]]) }
    }
    return found
}

private func same(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0.x - $1.x) < 1e-6 && abs($0.y - $1.y) < 1e-6 }
}

/// UIKit's `UIBezierPath(roundedRect:cornerRadius:)`, as macOS 27.2 (Catalyst)
/// drew it: the top right corner's curves, controls then end.
struct ContinuousCornersTests {
    @Test func aCornerThatFitsIsUIKits() {
        let found = curves(path(.continuousRoundedRect(CGRect(x: 0, y: 0, width: 200, height: 100), 10)))
        #expect(found.count == 12)
        #expect(same(found[0], [CGPoint(x: 189.1150704238147, y: 0), CGPoint(x: 191.31593055936997, y: 0), CGPoint(x: 193.68506207169008, y: 0.7491138784701601)]))
        #expect(same(found[1], [CGPoint(x: 196.27176173374255, y: 1.6905955604437004), CGPoint(x: 198.30940443955632, y: 3.7282382662574673), CGPoint(x: 199.25088612152985, y: 6.314937928309925)]))
        #expect(same(found[2], [CGPoint(x: 200, y: 8.684069440630022), CGPoint(x: 200, y: 10.88492957618529), CGPoint(x: 200, y: 15.286649847295823)]))
    }

    @Test func pastThatTheCornerIsUIKitsSecondShape() {
        let found = curves(path(.continuousRoundedRect(CGRect(x: 0, y: 0, width: 200, height: 100), 40)))
        #expect(same(found[0], [CGPoint(x: 146.51285961907357, y: 0), CGPoint(x: 157.51716029684988, y: 0), CGPoint(x: 169.3628178584504, y: 3.745569392350802)]))
        #expect(same(found[1], [CGPoint(x: 187.75710983002548, y: 10.440544150405918), CGPoint(x: 200, y: 27.925203343417653), CGPoint(x: 200, y: 47.5)]))
        // Leaving the short side onto the bottom.
        #expect(same(found[2], [CGPoint(x: 200, y: 72.07479665658234), CGPoint(x: 187.75710983002548, y: 89.55945584959409), CGPoint(x: 169.3628178584504, y: 96.2544306076492)]))
        #expect(same(found[3], [CGPoint(x: 157.51716029684988, y: 100), CGPoint(x: 146.51285961907357, y: 100), CGPoint(x: 124.50425826352087, y: 100)]))
    }

    @Test func aRadiusOfHalfTheSideOrMoreOrASquareIsCircular() {
        let capsule = path(.continuousRoundedRect(CGRect(x: 0, y: 0, width: 200, height: 100), 80))
        let circular = path(.roundedRect(CGRect(x: 0, y: 0, width: 200, height: 100), 50))
        #expect(capsule.boundingBoxOfPath == circular.boundingBoxOfPath)
        #expect(curves(capsule).count == curves(circular).count)
        let square = curves(path(.continuousRoundedRect(CGRect(x: 0, y: 0, width: 100, height: 100), 40)))
        #expect(square.count == curves(path(.roundedRect(CGRect(x: 0, y: 0, width: 100, height: 100), 50))).count)
    }

    @Test func noRadiusIsARect() {
        let flat = path(.continuousRoundedRect(CGRect(x: 1, y: 2, width: 30, height: 40), 0))
        #expect(curves(flat).isEmpty)
        #expect(flat.boundingBoxOfPath == CGRect(x: 1, y: 2, width: 30, height: 40))
    }
}
