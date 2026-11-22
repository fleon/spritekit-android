#if canImport(AppKit)
import CoreGraphics
import Foundation
import Testing
@testable import SpriteKitShim

// `UIBezierPath(roundedRect:cornerRadius:)` and
// `UIBezierPath(roundedRect:byRoundingCorners:cornerRadii:)` on Android draw
// through `ContinuousCorners`. The expected curves are UIKit's, as macOS 27.2
// (Mac Catalyst) drew them, with the straight runs it records as degenerate
// curves left out. A sweep of 11,628 rects, radii and corner sets matched
// UIKit's fill to the pixel and its outline to 0.000001 pt.

/// The path's curves that bend, each `[control1, control2, end]` as six
/// numbers, in order.
private func curves(_ path: CGPath) -> [[CGFloat]] {
    var found: [[CGFloat]] = []
    path.applyWithBlock { element in
        let e = element.pointee
        if e.type == .addCurveToPoint {
            found.append([e.points[0].x, e.points[0].y, e.points[1].x, e.points[1].y, e.points[2].x, e.points[2].y])
        }
    }
    return found
}

private func same(_ a: [[CGFloat]], _ b: [[CGFloat]]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { x, y in zip(x, y).allSatisfy { abs($0 - $1) < 1e-6 } }
}

private func rounded(_ rect: CGRect, _ radius: CGFloat, _ corners: ContinuousCorners.Corners = .all) -> CGPath {
    let path = CGMutablePath()
    ContinuousCorners.addRoundedRect(to: path, in: rect, corners: corners, cornerRadius: radius)
    return path
}

private let wide = CGRect(x: 0, y: 0, width: 200, height: 100)

struct ContinuousCornersTests {
    @Test func aCornerThatFitsIsOneShapeScaledByTheRadius() {
        #expect(same(curves(rounded(wide, 10)), [
        [189.1150704, 0, 191.3159306, 0, 193.6850621, 0.7491138785],
        [196.2717617, 1.69059556, 198.3094044, 3.728238266, 199.2508861, 6.314937928],
        [200, 8.684069441, 200, 10.88492958, 200, 15.28664985],
        [200, 89.11507042, 200, 91.31593056, 199.2508861, 93.68506207],
        [198.3094044, 96.27176173, 196.2717617, 98.30940444, 193.6850621, 99.25088612],
        [191.3159306, 100, 189.1150704, 100, 184.7133502, 100],
        [10.88492958, 100, 8.684069441, 100, 6.314937928, 99.25088612],
        [3.728238266, 98.30940444, 1.69059556, 96.27176173, 0.7491138785, 93.68506207],
        [0, 91.31593056, 0, 89.11507042, 0, 84.71335015],
        [0, 10.88492958, 0, 8.684069441, 0.7491138785, 6.314937928],
        [1.69059556, 3.728238266, 3.728238266, 1.69059556, 6.314937928, 0.7491138785],
        [8.684069441, 0, 10.88492958, 0, 15.28664985, 0],
        ]))
    }

    /// Past half the shorter side, while 1.5287 × radius fits in half the
    /// longer side, the corners take UIKit's second shape.
    @Test func pastHalfTheShortSideTheCornerTakesUIKitsSecondShape() {
        #expect(same(curves(rounded(wide, 60)), [
        [146.5128596, 0, 157.5171603, 0, 169.3628179, 3.745569392],
        [187.7571098, 10.44054415, 200, 27.92520334, 200, 47.5],
        [200, 72.07479666, 187.7571098, 89.55945585, 169.3628179, 96.25443061],
        [157.5171603, 100, 146.5128596, 100, 124.5042583, 100],
        [53.48714038, 100, 42.4828397, 100, 30.63718214, 96.25443061],
        [12.24289017, 89.55945585, 0, 72.07479666, 0, 52.5],
        [0, 27.92520334, 12.24289017, 10.44054415, 30.63718214, 3.745569392],
        [42.4828397, 0, 53.48714038, 0, 75.49574174, 0],
        ]))
    }

    /// Once a corner doesn't fit along either side, UIKit draws a capsule,
    /// even short of a radius of half the shorter side.
    @Test func aCornerThatFitsNeitherSideMakesACapsule() {
        #expect(same(curves(rounded(CGRect(x: 0, y: 0, width: 100, height: 101), 40)), [
        [77.61423749, 0, 100, 22.38576251, 100, 50],
        [100, 78.61423749, 77.61423749, 101, 50, 101],
        [22.38576251, 101, 0, 78.61423749, 0, 51],
        [0, 22.38576251, 22.38576251, 0, 50, 0],
        ]))
        #expect(curves(rounded(CGRect(x: 0, y: 0, width: 100, height: 100), 40)).count == 4)
    }

    @Test func aNegativeRadiusTurnsTheCurvesInsideOut() {
        #expect(same(curves(rounded(wide, -5)), [
        [205.4424648, 0, 204.3420347, 0, 203.157469, -0.3745569392],
        [201.8641191, -0.8452977802, 200.8452978, -1.864119133, 200.3745569, -3.157468964],
        [200, -4.34203472, 200, -5.442464788, 200, -7.643324924],
        [200, 105.4424648, 200, 104.3420347, 200.3745569, 103.157469],
        [200.8452978, 101.8641191, 201.8641191, 100.8452978, 203.157469, 100.3745569],
        [204.3420347, 100, 205.4424648, 100, 207.6433249, 100],
        [-5.442464788, 100, -4.34203472, 100, -3.157468964, 100.3745569],
        [-1.864119133, 100.8452978, -0.8452977802, 101.8641191, -0.3745569392, 103.157469],
        [0, 104.3420347, 0, 105.4424648, 0, 107.6433249],
        [0, -5.442464788, 0, -4.34203472, -0.3745569392, -3.157468964],
        [-0.8452977802, -1.864119133, -1.864119133, -0.8452977802, -3.157468964, -0.3745569392],
        [-4.34203472, 0, -5.442464788, 0, -7.643324924, 0],
        ]))
    }

    @Test func noRadiusOrNoCornersIsARect() {
        for path in [rounded(wide, 0), rounded(wide, 20, [])] {
            #expect(curves(path).isEmpty)
            #expect(path.boundingBoxOfPath == wide)
        }
    }

    /// One rounded corner has the whole of each side to run along.
    @Test func aLoneCornerRunsAlongTheWholeSide() {
        let lone = rounded(wide, 60, .topLeft)
        #expect(same(curves(lone), [
        [0, 65.30957746, 0, 52.10441664, 4.494683271, 37.88962757],
        [10.14357336, 22.3694296, 22.3694296, 10.14357336, 37.88962757, 4.494683271],
        [52.10441664, 0, 65.30957746, 0, 91.71989908, 0],
        ]))
        // The other three stay square.
        var points: [CGPoint] = []
        lone.applyWithBlock { element in
            if [.moveToPoint, .addLineToPoint].contains(element.pointee.type) { points.append(element.pointee.points[0]) }
        }
        #expect([CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 100), CGPoint(x: 0, y: 100)].allSatisfy(points.contains))
        #expect(same(curves(rounded(wide, 66, .topLeft)), [
        [0, 27.92520334, 12.24289017, 10.44054415, 30.63718214, 3.745569392],
        [42.4828397, 0, 53.48714038, 0, 75.49574174, 0],
        ]))
    }

    /// A corner that fits along neither side is a circle's quarter of
    /// 0.93125 × half the shorter side, unless two opposite corners are
    /// rounded and none fits: then all four make a capsule.
    @Test func aCornerThatFitsNeitherSideIsASmallerCircle() {
        #expect(same(curves(rounded(wide, 1000, .topLeft)), [
        [0, 20.84673798, 20.84673798, 0, 46.5624925, 0],
        ]))
        #expect(same(curves(rounded(wide, 66, [.topLeft, .topRight, .bottomLeft])), [
        [179.153262, 0, 200, 20.84673798, 200, 46.5624925],
        [53.48714038, 100, 42.4828397, 100, 30.63718214, 96.25443061],
        [12.24289017, 89.55945585, 0, 72.07479666, 0, 52.5],
        [0, 20.84673798, 20.84673798, 0, 46.5624925, 0],
        ]))
        #expect(same(curves(rounded(wide, 1000, [.topLeft, .topRight, .bottomLeft])), [
        [177.6142375, 0, 200, 22.38576251, 200, 50],
        [200, 77.61423749, 177.6142375, 100, 150, 100],
        [22.38576251, 100, 0, 77.61423749, 0, 50],
        [0, 22.38576251, 22.38576251, 0, 50, 0],
        ]))
    }

    /// The second shape is scaled by half the side with less room, the
    /// longer one here.
    @Test func theSecondShapeScalesWithTheSideWithLessRoom() {
        #expect(same(curves(rounded(CGRect(x: 0, y: 0, width: 100, height: 110), 40, [.topLeft, .bottomLeft])), [
        [58.83585442, 110, 46.73112367, 110, 33.70090036, 105.8798737],
        [13.46717919, 98.51540143, 0, 79.28227632, 0, 57.75],
        [0, 30.71772368, 13.46717919, 11.48459857, 33.70090036, 4.120126332],
        [46.73112367, 0, 58.83585442, 0, 83.04531591, 0],
        ]))
    }
}
#endif
