import Foundation
import Testing
@testable import SpriteKitShim

/// A glyph's coverage filled into a bitmap (`TextBlock` draws with it).
@Suite("Mask fills")
@MainActor
struct FillMaskTests {
    private static func alpha(_ context: BitmapContext, width: Int, height: Int) -> [UInt8] {
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        return (0 ..< width * height).map { data[$0 * 4 + 3] }
    }

    // A 2 × 3 mask: rows 255, 128, 0 (top first).
    private static let mask: [UInt8] = [255, 255, 128, 128, 0, 0]

    @Test("Rows run down the canvas from the first")
    func rowsDown() {
        let context = BitmapContext(width: 4, height: 4)
        context.fillMask(Self.mask, width: 2, height: 3, atDeviceX: 1, y: 0, rowsDown: true, colour: .white)
        #expect(Self.alpha(context, width: 4, height: 4) == [
            0, 255, 255, 0,
            0, 128, 128, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
        ])
    }

    @Test("Rows run up the canvas, as text drawn upside down does")
    func rowsUp() {
        let context = BitmapContext(width: 4, height: 4)
        context.fillMask(Self.mask, width: 2, height: 3, atDeviceX: 0, y: 3, rowsDown: false, colour: .white)
        #expect(Self.alpha(context, width: 4, height: 4) == [
            0, 0, 0, 0,
            0, 0, 0, 0,
            128, 128, 0, 0,
            255, 255, 0, 0,
        ])
    }

    @Test("Off the canvas and outside the clip, nothing")
    func clipped() {
        let context = BitmapContext(width: 4, height: 4)
        context.clip(to: CGRect(x: 0, y: 0, width: 4, height: 1))
        context.fillMask(Self.mask, width: 2, height: 3, atDeviceX: 3, y: 0, rowsDown: true, colour: .white)
        #expect(Self.alpha(context, width: 4, height: 4) == [0, 0, 0, 255] + [UInt8](repeating: 0, count: 12))
    }

    @Test("A bounded transparency layer clips what's drawn in it")
    func boundedLayer() {
        let context = BitmapContext(width: 4, height: 4)
        context.beginTransparencyLayer(in: CGRect(x: 0, y: 0, width: 1, height: 4))
        context.fillMask(Self.mask, width: 2, height: 3, atDeviceX: 0, y: 0, rowsDown: true, colour: .white)
        context.endTransparencyLayer()
        let alpha = Self.alpha(context, width: 4, height: 4)
        #expect(alpha[0] == 255 && alpha[1] == 0 && alpha[4] == 128 && alpha[5] == 0)
    }
}
