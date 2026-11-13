import Foundation
import Testing
@testable import SpriteKitShim

#if canImport(CoreGraphics)
import CoreGraphics

/// Every blend mode the software context has, against CoreGraphics'.
@Suite("Bitmap blend modes")
struct BlendModeTests {
    /// Translucent and opaque pairs, unpremultiplied (r, g, b, a).
    static let pairs: [((CGFloat, CGFloat, CGFloat, CGFloat), (CGFloat, CGFloat, CGFloat, CGFloat))] = [
        ((0.9, 0.2, 0.1, 1), (0.1, 0.5, 0.8, 1)),
        ((0.3, 0.8, 0.4, 0.6), (0.7, 0.3, 0.2, 1)),
        ((0.2, 0.2, 0.9, 0.8), (0.9, 0.9, 0.1, 0.5)),
    ]

    @Test("Each mode composites as CoreGraphics does", arguments: [
        BitmapContext.BlendMode.hue, .saturation, .color, .luminosity, .plusLighter, .plusDarker,
        .multiply, .screen, .overlay, .softLight,
    ])
    func matchesCoreGraphics(_ mode: BitmapContext.BlendMode) throws {
        for (source, backdrop) in Self.pairs {
            let ours = BitmapContext.blend(mode, src: premultiplied(source), dst: premultiplied(backdrop))
            let theirs = try coreGraphics(mode, source: source, backdrop: backdrop)
            for (a, b) in [(ours.r, theirs[0]), (ours.g, theirs[1]), (ours.b, theirs[2]), (ours.a, theirs[3])] {
                #expect(abs(a * 255 - b) <= 3, "\(mode) \(source) over \(backdrop): \(a * 255) vs \(b)")
            }
        }
    }

    private func premultiplied(_ c: (CGFloat, CGFloat, CGFloat, CGFloat)) -> BitmapContext.Premultiplied {
        BitmapContext.Premultiplied(r: c.0 * c.3, g: c.1 * c.3, b: c.2 * c.3, a: c.3)
    }

    /// One pixel, filled with the backdrop and then the source in `mode`;
    /// premultiplied bytes back.
    private func coreGraphics(_ mode: BitmapContext.BlendMode, source: (CGFloat, CGFloat, CGFloat, CGFloat), backdrop: (CGFloat, CGFloat, CGFloat, CGFloat)) throws -> [CGFloat] {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: backdrop.0, green: backdrop.1, blue: backdrop.2, alpha: backdrop.3)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setBlendMode(try #require(CGBlendMode(rawValue: Int32(mode.rawValue))))
        context.setFillColor(red: source.0, green: source.1, blue: source.2, alpha: source.3)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0 ..< 4).map { CGFloat(bytes[$0]) }
    }
}
#endif
