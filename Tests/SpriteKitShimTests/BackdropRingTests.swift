import XCTest
@testable import SpriteKitShim

#if canImport(Darwin)
import CoreGraphics
#endif

/// What the backdrop ring added to the shim: actions the backdrops run
/// (`reversed`, `follow`, the shortest-arc turn), CoreGraphics' image
/// orientation and tiled draws, and Core Image's blur.
final class BackdropRingTests: XCTestCase {
    private func tick(_ node: SKNode, _ seconds: TimeInterval) {
        let steps = max(1, Int(seconds * 8))
        for _ in 0..<steps { node.tickActions(seconds / TimeInterval(steps)) }
    }

    // MARK: Actions

    func testAReversedMoveByComesBack() {
        let node = SKNode()
        let up = SKAction.moveBy(x: 0, y: 10, duration: 1)
        node.run(.sequence([up, up.reversed()]))
        tick(node, 1)
        XCTAssertEqual(node.position.y, 10, accuracy: 0.001)
        tick(node, 1)
        XCTAssertEqual(node.position.y, 0, accuracy: 0.001)
    }

    func testAReversedSequenceRunsBackwards() {
        let node = SKNode()
        let there = SKAction.sequence([.moveBy(x: 10, y: 0, duration: 1), .moveBy(x: 0, y: 5, duration: 1)])
        node.run(.sequence([there, there.reversed()]))
        tick(node, 3)
        // Back along y first, then x.
        XCTAssertEqual(node.position.x, 10, accuracy: 0.001)
        XCTAssertEqual(node.position.y, 0, accuracy: 0.001)
        tick(node, 1)
        XCTAssertEqual(node.position.x, 0, accuracy: 0.001)
    }

    func testReversingAnEaseInEasesOut() {
        let move = SKAction.moveBy(x: 1, y: 0, duration: 1)
        move.timingMode = .easeIn
        XCTAssertEqual(move.reversed().timingMode, .easeOut)
    }

    func testFollowGoesAlongThePathAtAnEvenSpeed() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 30, y: 0))
        path.addLine(to: CGPoint(x: 30, y: 10))
        let node = SKNode()
        node.run(.follow(path, asOffset: false, orientToPath: false, duration: 4))
        tick(node, 3)
        // Three quarters of 40 points: 30 along, at the corner.
        XCTAssertEqual(node.position.x, 30, accuracy: 0.01)
        XCTAssertEqual(node.position.y, 0, accuracy: 0.01)
        tick(node, 1)
        XCTAssertEqual(node.position.y, 10, accuracy: 0.01)
    }

    func testFollowAsAnOffsetStartsWhereTheNodeStands() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 10, y: 0))
        let node = SKNode()
        node.position = CGPoint(x: 100, y: 50)
        node.run(.follow(path, asOffset: true, orientToPath: true, duration: 1))
        tick(node, 1)
        XCTAssertEqual(node.position.x, 110, accuracy: 0.01)
        XCTAssertEqual(node.position.y, 50, accuracy: 0.01)
        XCTAssertEqual(node.zRotation, 0, accuracy: 0.001)
    }

    func testTheShortestArcTurnsTheShortWayRound() {
        let node = SKNode()
        node.zRotation = 3
        node.run(.rotate(toAngle: -3, duration: 1, shortestUnitArc: true))
        tick(node, 1)
        // 3 → -3 the short way passes π rather than 0.
        XCTAssertEqual(node.zRotation, 2 * .pi - 3, accuracy: 0.001)
    }

    // MARK: Images

    /// Two rows: red on top, blue below.
    private func redOverBlue() -> RasterImage {
        RasterImage(width: 1, height: 2, pixels: [255, 0, 0, 255, 0, 0, 255, 255])
    }

    private func pixel(_ image: RasterImage, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * image.width + x) * 4
        return Array(image.pixels[i..<i + 4])
    }

    func testAnImageInAYDownContextComesOutUpsideDown() throws {
        // As CoreGraphics draws into UIKit's flipped context: its top on the
        // rect's maxY, which is the bottom here.
        let context = BitmapContext(width: 1, height: 2)
        context.interpolationQuality = .none
        context.draw(redOverBlue(), in: CGRect(x: 0, y: 0, width: 1, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 0, 0), [0, 0, 255, 255])
        XCTAssertEqual(pixel(image, 0, 1), [255, 0, 0, 255])
    }

    func testFlippedYUpTheImageIsTheRightWayUp() throws {
        // What `BoardGroundingArt` and `CircuitBoardNode` do before drawing.
        let context = BitmapContext(width: 1, height: 2)
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: 2)
        context.scaleBy(x: 1, y: -1)
        context.draw(redOverBlue(), in: CGRect(x: 0, y: 0, width: 1, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 0, 0), [255, 0, 0, 255])
        XCTAssertEqual(pixel(image, 0, 1), [0, 0, 255, 255])
    }

    func testATiledImageCoversTheWholeCanvas() throws {
        let context = BitmapContext(width: 4, height: 6)
        context.interpolationQuality = .none
        context.draw(redOverBlue(), in: CGRect(x: 1, y: 1, width: 1, height: 2), byTiling: true)
        let image = try XCTUnwrap(context.makeImage())
        for y in 0..<6 {
            for x in 0..<4 { XCTAssertEqual(pixel(image, x, y)[3], 255, "\(x),\(y) is covered") }
        }
        // Rows alternate with the tile's period, starting from the rect.
        XCTAssertEqual(pixel(image, 0, 1), pixel(image, 3, 3))
        XCTAssertNotEqual(pixel(image, 0, 1), pixel(image, 0, 2))
    }

    // MARK: Core Image

    func testTheBlurSpreadsAPointAndKeepsItsWeight() throws {
        var pixels = [UInt8](repeating: 0, count: 21 * 21 * 4)
        let middle = (10 * 21 + 10) * 4
        pixels[middle..<middle + 4] = [255, 255, 255, 255]
        let source = RasterImage(width: 21, height: 21, pixels: pixels)
        let image = SpriteKitShim.CIImage(cgImage: source)
        let blurred = image.applyingGaussianBlur(sigma: 2).cropped(to: image.extent)
        let out = try XCTUnwrap(SpriteKitShim.CIContext().createCGImage(blurred, from: image.extent))
        let alpha = stride(from: 3, to: out.pixels.count, by: 4).map { Int(out.pixels[$0]) }
        XCTAssertLessThan(alpha[10 * 21 + 10], 255)
        XCTAssertGreaterThan(alpha[10 * 21 + 12], 0, "two sigma away still shows")
        XCTAssertEqual(alpha[0], 0, "the far corner stays clear")
        // About one pixel's worth of alpha in all, give or take rounding.
        XCTAssertEqual(Double(alpha.reduce(0, +)), 255, accuracy: 60)
    }

    func testAClampedBlurKeepsAFullEdgeFull() throws {
        let source = RasterImage(width: 8, height: 8, pixels: [UInt8](repeating: 255, count: 8 * 8 * 4))
        let image = SpriteKitShim.CIImage(cgImage: source)
        let clamped = image.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: image.extent)
        let loose = image.applyingGaussianBlur(sigma: 3)
        let context = SpriteKitShim.CIContext()
        let kept = try XCTUnwrap(context.createCGImage(clamped, from: image.extent))
        let faded = try XCTUnwrap(context.createCGImage(loose, from: image.extent))
        XCTAssertEqual(kept.pixels[3], 255)
        XCTAssertLessThan(faded.pixels[3], 200, "unclamped, the edge fades into clear")
    }

    func testBoxesMatchTheSigma() {
        // Three boxes of widths w give a variance of Σ (w² − 1) / 12.
        for sigma in [1.0, 2.5, 7, 30] {
            let boxes = SpriteKitShim.CIImage.boxes(sigma: sigma)
            let variance = boxes.reduce(0.0) { $0 + Double($1 * $1 - 1) / 12 }
            XCTAssertEqual(variance.squareRoot(), sigma, accuracy: sigma * 0.1 + 0.3)
        }
    }

    func testTheBlurMixesInLinearLightAsCoreImageDoes() throws {
        // Black and white stripes a pixel wide, blurred: Core Image on a Mac
        // writes 187 in the middle (half the light, encoded as sRGB), not 128.
        let size = 40
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in stride(from: 1, to: size, by: 2) {
                for channel in 0..<3 { pixels[(y * size + x) * 4 + channel] = 0 }
            }
        }
        let image = SpriteKitShim.CIImage(cgImage: RasterImage(width: size, height: size, pixels: pixels))
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 4).cropped(to: image.extent)
        let out = try XCTUnwrap(SpriteKitShim.CIContext().createCGImage(blurred, from: image.extent))
        XCTAssertEqual(Int(out.pixels[(20 * size + 20) * 4]), 187, accuracy: 2)
    }

    func testAWhiteMaskOnClearKeepsItsAlphaAsBlurred() throws {
        // Colour is converted unpremultiplied: white stays white, so the
        // premultiplied colour follows alpha, which Core Image leaves linear.
        var pixels = [UInt8](repeating: 0, count: 40 * 40 * 4)
        for y in 0..<40 {
            for x in 20..<40 { pixels[(y * 40 + x) * 4..<(y * 40 + x) * 4 + 4] = [255, 255, 255, 255] }
        }
        let image = SpriteKitShim.CIImage(cgImage: RasterImage(width: 40, height: 40, pixels: pixels))
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: image.extent)
        let out = try XCTUnwrap(SpriteKitShim.CIContext().createCGImage(blurred, from: image.extent))
        for x in 12..<28 {
            let pixel = (20 * 40 + x) * 4
            XCTAssertEqual(Int(out.pixels[pixel]), Int(out.pixels[pixel + 3]), accuracy: 1)
        }
        // Core Image on a Mac: 51 two pixels short of the edge, 204 two past it.
        XCTAssertEqual(Int(out.pixels[(20 * 40 + 17) * 4 + 3]), 51, accuracy: 8)
        XCTAssertEqual(Int(out.pixels[(20 * 40 + 22) * 4 + 3]), 204, accuracy: 8)
    }
}
