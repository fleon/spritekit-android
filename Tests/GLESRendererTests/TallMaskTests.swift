import XCTest
@testable import SpriteKitShim

#if canImport(Darwin)
import CoreGraphics
#endif

/// A shape taller than a texture can be still gets a mask: the renderer
/// rasterises it at the largest scale whose mask fits the texture and the
/// rasteriser, margin and rounding included (`PathRasteriser.scale`).
final class TallMaskTests: XCTestCase {
    /// A strip down a scrolling list, `height` points tall.
    private func strip(height: CGFloat) -> CGPath {
        CGPath(rect: CGRect(x: -57, y: -height / 2, width: 114, height: height), transform: nil)
    }

    func testAMaskThatFitsKeepsItsScale() {
        XCTAssertEqual(PathRasteriser.scale(3, fitting: 800, textureSide: 4096), 3)
    }

    func testTallStripsFitEveryTextureSide() {
        for height: CGFloat in [6_016, 19_176, 37_976, 75_576] {
            for side in [2048, 4096, 8192, 16384] {
                let scale = PathRasteriser.scale(3, fitting: height, textureSide: side)
                guard let mask = PathRasteriser.fill(strip(height: height), scale: scale) else {
                    return XCTFail("no mask for a \(height) pt strip at a \(side) px texture side")
                }
                let limit = min(side, PathRasteriser.maximumSide)
                XCTAssertLessThanOrEqual(mask.height, limit, "\(height) pt at \(side) px")
                XCTAssertLessThanOrEqual(mask.width, limit)
                // Not needlessly small: within a few pixels of the limit.
                XCTAssertGreaterThan(mask.height, limit - 8, "\(height) pt at \(side) px")
            }
        }
    }

    func testAMaskPastTheRasterisersLimitIsRefused() {
        XCTAssertNil(PathRasteriser.fill(strip(height: 10_000), scale: 1))
    }
}
