import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim

// A 400 × 800 pt screen at one pixel a point, the effect node overscanning
// it by 8 pt, as a band blur sets its uniforms there.
private let visible = CGRect(x: 0, y: 0, width: 400, height: 800)
private let bounds = CGRect(x: -8, y: -8, width: 416, height: 816)
private let nowhere: Float = 100_000

private func uniforms(top: SIMD4<Float>, bottom: SIMD4<Float>, crop: SIMD4<Float>? = nil) -> BandBlurPlan.Uniforms {
    BandBlurPlan.Uniforms(
        screen: SIMD4(0, 800, 1, 0),
        top: top, bottom: bottom,
        span: SIMD2(1 / 416, 1 / 816),
        crop: crop ?? SIMD4(-nowhere, -nowhere, nowhere, nowhere),
        fade: 70, blur: 6
    )
}

private func plan(_ u: BandBlurPlan.Uniforms) -> BandBlurPlan? {
    BandBlurPlan(
        uniforms: u, width: 400, height: 800, visible: visible,
        fragSpace: .target(heightInPixels: 800), bounds: bounds, offset: .zero
    )
}

@Test("Upright, the bands run along the top and bottom and the rest draws in place")
func uprightBands() throws {
    // Top: full to 90 pt down, gone 70 pt further. Bottom: 50 pt, then 70.
    let result = try #require(plan(uniforms(top: SIMD4(0, -1, 800, 90), bottom: SIMD4(0, 1, 0, 50))))
    #expect(result.direct == .init(x0: 0, y0: 120, x1: 400, y1: 640))
    #expect(result.strips.map(\.band) == [
        .init(x0: 0, y0: 0, x1: 400, y1: 120),
        .init(x0: 0, y0: 640, x1: 400, y1: 800),
    ])
    // Six points of taps, two texels more, as far as the overscan goes.
    let top = result.strips[1]
    #expect(top.strip == .init(x0: -8, y0: 632, x1: 408, y1: 808))
    // The strip's texture spans 416 × 176 pixels where the effect node's spanned
    // 416 × 816: its coordinates run that much faster per point.
    #expect(abs(top.span.x - 1 / 416) < 1e-6)
    #expect(abs(top.span.y - 1 / 176) < 1e-6)
}

@Test("In landscape the bands run down the sides")
func landscapeBands() throws {
    var u = uniforms(top: SIMD4(1, 0, 0, 60), bottom: SIMD4(-1, 0, 800, 60))
    u.screen = SIMD4(0, 400, 1, 0)
    u.span = SIMD2(1 / 816, 1 / 416)
    let result = try #require(BandBlurPlan(
        uniforms: u, width: 800, height: 400, visible: CGRect(x: 0, y: 0, width: 800, height: 400),
        fragSpace: .target(heightInPixels: 400), bounds: CGRect(x: -8, y: -8, width: 816, height: 416), offset: .zero
    ))
    #expect(result.direct == .init(x0: 130, y0: 0, x1: 670, y1: 400))
    #expect(result.strips.map(\.band) == [
        .init(x0: 0, y0: 0, x1: 130, y1: 400),
        .init(x0: 670, y0: 0, x1: 800, y1: 400),
    ])
}

@Test("Without bands the contents draw in place, cropped as the shader crops it")
func noBandsCropped() throws {
    let none = SIMD4<Float>(0, 0, 0, -nowhere)
    let result = try #require(plan(uniforms(top: none, bottom: none, crop: SIMD4(100, -nowhere, 250.4, nowhere))))
    #expect(result.strips.isEmpty)
    // Pixel centres 100.5 … 249.5 lie in 100 … 250.4.
    #expect(result.direct == .init(x0: 100, y0: 0, x1: 250, y1: 800))
}

@Test("A band over everything (-BlurBackdrop) keeps the full-screen pass")
func blurEverywhereFallsBack() {
    let everywhere = SIMD4<Float>(0, 0, 0, nowhere)
    #expect(plan(uniforms(top: everywhere, bottom: everywhere)) == nil)
}

@Test("Bands meeting in the middle keep the full-screen pass")
func overlappingBandsFallBack() {
    #expect(plan(uniforms(top: SIMD4(0, -1, 800, 400), bottom: SIMD4(0, 1, 0, 400))) == nil)
}

@Test("At half the pixels the bands land on the scaled target's own pixels")
func scaledTarget() throws {
    // A 200 × 400 target whose shaders still count the screen's 400 × 800.
    let space = FragCoordSpace(offsetX: 0, offsetY: 800, scaleX: 2, scaleY: -2)
    let result = try #require(BandBlurPlan(
        uniforms: uniforms(top: SIMD4(0, -1, 800, 90), bottom: SIMD4(0, 1, 0, 50)),
        width: 200, height: 400, visible: visible, fragSpace: space, bounds: bounds, offset: .zero
    ))
    #expect(result.direct == .init(x0: 0, y0: 60, x1: 200, y1: 320))
    // Three pixels of taps at half the density, two more.
    #expect(result.strips[1].strip == .init(x0: -4, y0: 315, x1: 204, y1: 404))
}

@Test("Contents drawn in place report the effect texture's pixels")
func contentsSpaceMatchesTheTexture() {
    let texture = EffectTexture(bounds: bounds, density: 1, maximumSide: 4096)
    // The screen's bottom-left pixel is 8 texels in from the texture's
    // bottom-left corner, which Metal counts from the top.
    let space = BandBlurPlan.contentsSpace(
        origin: .zero, dx: 1, dy: 1, bounds: bounds,
        textureWidth: texture.widthInPixels, textureHeight: texture.heightInPixels
    )
    let corner = space.apply(0.5, 0.5)
    #expect(abs(corner.x - 8.5) < 1e-4)
    #expect(abs(corner.y - Float(816 - 8.5)) < 1e-4)
}
