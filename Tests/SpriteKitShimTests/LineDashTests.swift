import XCTest
@testable import SpriteKitShim

#if canImport(Darwin)
import CoreGraphics

/// `setLineDash(phase:lengths:)` against CoreGraphics' own context on the
/// Mac: the same dashed strokes, read back pixel by pixel.
final class LineDashTests: XCTestCase {
    private struct Case {
        var phase: CGFloat
        var lengths: [CGFloat]
        var width: CGFloat
        var cap: CGLineCap
    }

    private let cases = [
        Case(phase: 0, lengths: [6, 4], width: 2, cap: .butt),
        Case(phase: 3, lengths: [6, 4], width: 2, cap: .butt),
        Case(phase: 0, lengths: [5, 3, 1, 3], width: 3, cap: .square),
        // Odd: the second time round, on and off swap.
        Case(phase: 0, lengths: [5, 3, 2], width: 2, cap: .butt),
        Case(phase: 4, lengths: [6], width: 2, cap: .butt),
    ]

    func testADashedLineCoversWhatCoreGraphicsCovers() throws {
        let width = 48, height = 8
        for (index, dash) in cases.enumerated() {
            let ours = BitmapContext(width: width, height: height)
            ours.setStroke(.white)
            ours.setLineWidth(dash.width)
            ours.setLineCap(dash.cap)
            ours.setLineDash(phase: dash.phase, lengths: dash.lengths)
            ours.move(to: CGPoint(x: 2, y: 4))
            ours.addLine(to: CGPoint(x: 46, y: 4))
            ours.strokePath()
            let image = try XCTUnwrap(ours.makeImage())

            let space = CGColorSpaceCreateDeviceRGB()
            let apple = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            apple.setStrokeColor(CGColor(gray: 1, alpha: 1))
            apple.setLineWidth(dash.width)
            apple.setLineCap(dash.cap)
            apple.setLineDash(phase: dash.phase, lengths: dash.lengths)
            // CoreGraphics counts y up from the bottom: y 4 of 8 is the same row.
            apple.move(to: CGPoint(x: 2, y: 4))
            apple.addLine(to: CGPoint(x: 46, y: 4))
            apple.strokePath()
            let data = try XCTUnwrap(apple.data).assumingMemoryBound(to: UInt8.self)

            var worst = 0
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let theirs = Int(data[(y * width + x) * 4 + 3])
                    let mine = Int(image.pixels[(y * image.width + x) * 4 + 3])
                    worst = max(worst, abs(theirs - mine))
                }
            }
            XCTAssertLessThanOrEqual(worst, 8, "case \(index): coverage differs by \(worst) of 255")
        }
    }

    func testAnEllipseStartsWhereCoreGraphicsStartsIt() throws {
        let rect = CGRect(x: 2, y: 3, width: 20, height: 10)
        let apple = CGMutablePath()
        apple.addEllipse(in: rect)
        let theirs = apple.pathElements
        let ours = BitmapContext.ellipse(in: rect)
        XCTAssertEqual(ours.count, theirs.count)
        func points(_ element: PathElement) -> [CGPoint] {
            switch element {
            case let .move(p), let .line(p): return [p]
            case let .quadCurve(p, c): return [c, p]
            case let .curve(p, c1, c2): return [c1, c2, p]
            default: return []
            }
        }
        for (a, b) in zip(ours, theirs) {
            let pa = points(a), pb = points(b)
            XCTAssertEqual(pa.count, pb.count, "\(a) vs \(b)")
            for (x, y) in zip(pa, pb) {
                XCTAssertEqual(x.x, y.x, accuracy: 0.01, "\(a) vs \(b)")
                XCTAssertEqual(x.y, y.y, accuracy: 0.01, "\(a) vs \(b)")
            }
        }
    }

    func testAnEmptyPatternStrokesSolidAgain() throws {
        let context = BitmapContext(width: 20, height: 6)
        context.setStroke(.white)
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [2, 2])
        context.setLineDash(phase: 0, lengths: [])
        context.move(to: CGPoint(x: 0, y: 3))
        context.addLine(to: CGPoint(x: 20, y: 3))
        context.strokePath()
        let image = try XCTUnwrap(context.makeImage())
        for x in 0 ..< 20 {
            XCTAssertEqual(image.pixels[(2 * image.width + x) * 4 + 3], 255, "x \(x)")
        }
    }
}
#endif
