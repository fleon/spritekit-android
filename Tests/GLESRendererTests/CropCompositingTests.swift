import XCTest
@testable import GLESRenderer
@testable import SpriteKitShim

#if canImport(Darwin)
import CoreGraphics
#endif

/// Which crops draw offscreen (`CropCompositing`), and over what.
final class CropCompositingTests: XCTestCase {

    private func shape(fill: SKColor = .white, stroke: SKColor = .clear, lineWidth: CGFloat = 0, alpha: CGFloat = 1) -> DrawList.Shape {
        DrawList.Shape(
            transform: .identity, path: CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil),
            fillColor: fill, strokeColor: stroke, lineWidth: lineWidth, lineCap: .butt, lineJoin: .miter, alpha: alpha
        )
    }

    private func spriteBatch(_ rect: CGRect) -> SpriteBatcher.Pass {
        var batch = SpriteBatcher.Batch(blendMode: .alpha)
        for (x, y) in [(rect.minX, rect.minY), (rect.maxX, rect.maxY)] {
            batch.vertices += [Float(x), Float(y), 0, 0, 1, 1, 1, 1, 0]
        }
        batch.indices = [0, 1, 0]
        return .batches([batch])
    }

    func testASpriteMaskStaysOnTheStencil() {
        for mode in [CropCompositing.Mode.stencil, .hybrid, .composited] {
            XCTAssertFalse(CropCompositing.composites([spriteBatch(CGRect(x: 0, y: 0, width: 10, height: 10))], mode: mode))
        }
    }

    func testAnOpaqueShapeMaskIsCompositedOnlyWhenEveryShapeMaskIs() {
        let mask: [SpriteBatcher.Pass] = [.shape(shape())]
        XCTAssertFalse(CropCompositing.composites(mask, mode: .stencil))
        XCTAssertFalse(CropCompositing.composites(mask, mode: .hybrid))
        XCTAssertTrue(CropCompositing.composites(mask, mode: .composited))
    }

    func testTranslucentAndStrokedShapeMasksAreCompositedInTheHybrid() {
        XCTAssertTrue(CropCompositing.composites([.shape(shape(fill: SKColor(white: 1, alpha: 0.3)))], mode: .hybrid))
        XCTAssertTrue(CropCompositing.composites([.shape(shape(alpha: 0.5))], mode: .hybrid))
        XCTAssertTrue(CropCompositing.composites([.shape(shape(stroke: .white, lineWidth: 1))], mode: .hybrid))
        XCTAssertFalse(CropCompositing.composites([.shape(shape(fill: .clear, stroke: .white, lineWidth: 0))], mode: .hybrid))
    }

    func testAMaskHoldingACropOrEffectStaysOnTheStencil() {
        let nested: SpriteBatcher.Pass = .crop(transform: .identity, mask: [.shape(shape())], contents: [])
        XCTAssertFalse(CropCompositing.composites([.shape(shape()), nested], mode: .composited))
    }

    func testTheBoundsAreWhereTheMasksVerticesReach() throws {
        let mask = [spriteBatch(CGRect(x: 4, y: -2, width: 10, height: 6)), spriteBatch(CGRect(x: -1, y: 0, width: 2, height: 30))]
        let bounds = try XCTUnwrap(CropCompositing.bounds(of: mask))
        XCTAssertEqual(bounds, CGRect(x: -1, y: -2, width: 15, height: 32))
        XCTAssertNil(CropCompositing.bounds(of: []), "an empty mask reaches nowhere")
        XCTAssertNil(CropCompositing.bounds(of: [.shape(shape())]), "a shape not yet staged can't be measured")
    }
}
