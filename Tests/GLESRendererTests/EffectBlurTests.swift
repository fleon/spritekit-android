// An `SKEffectNode`'s `CIGaussianBlur`, as SpriteKit draws it. Measured on a
// Mac (macOS 27.2, a 2x SKView, `texture(from:)`) and in an iPhone 17 Pro
// simulator (iOS 27, 3x, a screenshot), a black square blurred at radius
// 3, 6 and 12:
//
// - the blur's sigma is half the radius in points at every scale: 3, 6 and
//   12 px at 2x, 4.5, 8.9 and 18 px at 3x; still a Gaussian at radius 50
//   and 100, at 2x and 3x (`wideBlursAt2x`, `wideBlursAt3x`);
// - it spreads past the node's contents unclipped, as far as three sigmas
//   reach, centred on them;
// - `calculateAccumulatedFrame()` stays the contents' frame;
// - premultiplied colour is mixed as stored: red beside green blurs to
//   (140, 115, 0) and (115, 140, 0) either side of the seam, not the
//   lighter mix linear light would give;
// - the same picture whether `shouldRasterize` is on or off, and whether
//   the children are labels, labels drawing in a child, or sprites.
import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim
import RuntimeTestSupport

private func blurred(_ radius: CGFloat) -> SKEffectNode {
    let effect = SKEffectNode()
    effect.filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
    return effect
}

private func square(at point: CGPoint = .zero, side: CGFloat = 40) -> SKSpriteNode {
    let sprite = SKSpriteNode(color: .black, size: CGSize(width: side, height: side))
    sprite.position = point
    return sprite
}

private func effectCommand(_ node: SKNode) -> DrawList.Effect? {
    let root = node.parent ?? SKNode()
    if node.parent == nil { root.addChild(node) }
    for command in DrawList(scene: root).commands { if case let .effect(effect) = command { return effect } }
    return nil
}

@Test("A Gaussian blur's sigma is half its radius, in points")
func sigmaIsHalfTheRadius() {
    #expect(blurred(6).blurSigma == 3)
    #expect(blurred(20).blurSigma == 10)
    // Core Image's default radius, 10.
    let byDefault = SKEffectNode()
    byDefault.filter = CIFilter(name: "CIGaussianBlur")
    #expect(byDefault.blurSigma == 5)
    // No filter, another filter, or effects turned off: no blur.
    #expect(SKEffectNode().blurSigma == 0)
    let gradient = SKEffectNode()
    gradient.filter = CIFilter(name: "CILinearGradient")
    #expect(gradient.blurSigma == 0)
    let off = blurred(6)
    off.shouldEnableEffects = false
    #expect(off.blurSigma == 0)
}

@Test("The texture reaches three sigmas past the contents; the accumulated frame doesn't")
func boundsReachAsFarAsTheBlur() {
    let effect = blurred(8)
    effect.addChild(square(at: CGPoint(x: 10, y: 5)))
    // Contents (-10, -15, 40, 40); sigma 4, so 12 past each side.
    #expect(effect.effectBounds == CGRect(x: -22, y: -27, width: 64, height: 64))
    #expect(effect.calculateAccumulatedFrame() == CGRect(x: -10, y: -15, width: 40, height: 40))

    let plain = SKEffectNode()
    plain.addChild(square())
    #expect(plain.effectBounds == CGRect(x: -20, y: -20, width: 40, height: 40))
    // An empty blurred node has nothing to draw, so no texture.
    #expect(blurred(8).effectBounds == .zero)
}

@Test("A blurred node is drawn through a texture of its own, whether it rasterizes or not")
func aBlurNeverPassesThrough() throws {
    let live = blurred(8)
    live.addChild(square())
    let command = try #require(effectCommand(live))
    #expect(command.blurSigma == 4)
    #expect(command.bounds == CGRect(x: -32, y: -32, width: 64, height: 64))
    #expect(!SpriteBatcher.passesThrough(command))

    var list = DrawList()
    list.commands = [.effect(command)]
    guard case let .effect(bounds, _, _, _, _, _, _, _, _, contents, blur)? = SpriteBatcher().passes(for: list).first else {
        Issue.record("the blurred node passed through")
        return
    }
    #expect(blur == 4 && bounds == command.bounds && !contents.isEmpty)

    // Without the filter, the same node draws its children in place.
    live.filter = nil
    #expect(SpriteBatcher.passesThrough(try #require(effectCommand(live))))
}

@Test("A rasterized node redraws when its blur changes")
func blurChangeRedraws() throws {
    let effect = blurred(8)
    effect.shouldRasterize = true
    effect.addChild(square())
    let before = try #require(effectCommand(effect)).contentsDigest
    effect.filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 12])
    #expect(try #require(effectCommand(effect)).contentsDigest != before)
}

@Test("The kernel sums to one and reaches three sigmas, in pairs")
func kernelShape() throws {
    let kernel = try #require(EffectBlur(sigma: 4))
    let total = kernel.centre + 2 * kernel.pairs.reduce(0) { $0 + $1.y }
    #expect(abs(total - 1) < 1e-5)
    // 12 texels each side, two to a fetch.
    #expect(kernel.pairs.count == 6)
    #expect(kernel.pairs.allSatisfy { $0.x > 0 && $0.y > 0 })
    #expect(kernel.packedPairs.count == EffectBlur.maximumPairs * 2)
    // A blur too small to move a pixel is none.
    #expect(EffectBlur(sigma: 0) == nil)
    // A wider one runs over a halved copy rather than past the most pairs
    // a pass takes: 3 × 150 texels is past 128 three times over, so a
    // quarter-size copy, its kernel still reaching three sigmas.
    let wide = try #require(EffectBlur(sigma: 150))
    #expect(wide.downsample == 4)
    #expect(wide.pairs.count <= EffectBlur.maximumPairs)
    #expect(wide.halvings(width: 901, height: 300).map { [$0.width, $0.height] } == [[451, 150], [226, 75]])
    #expect(try #require(EffectBlur(sigma: 42)).downsample == 1)
}

/// The blur's alpha across a black half-plane whose edge is at texel
/// `edge` of a row `width` texels wide, at `sigma` texels.
private func edgeProfile(sigma: Double, width: Int, edge: Int) throws -> [Float] {
    let kernel = try #require(EffectBlur(sigma: sigma))
    let height = 3
    var pixels = [Float](repeating: 0, count: width * height * 4)
    for y in 0..<height { for x in 0..<edge { pixels[(y * width + x) * 4 + 3] = 255 } }
    let out = kernel.blurred(pixels, width: width, height: height)
    return (0..<width).map { out[(width + $0) * 4 + 3] }
}

@Test("Wide blurs stay SpriteKit's Gaussian on a 2x Mac", arguments: [
    // Alpha every 5 pt from x = 120 to 360 pt across a black half-plane
    // whose edge is at 200 pt, blurred at radius 20, 50 and 100 in a 2x
    // SKView (`texture(from:)`).
    (20.0, [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 253, 249, 236, 213, 173, 125, 77, 38, 17, 5, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    (50.0, [255, 255, 254, 254, 253, 251, 249, 245, 240, 234, 225, 214, 200, 184, 166, 147, 126, 106, 87, 69, 53, 40, 29, 20, 13, 9, 6, 3, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    (100.0, [241, 238, 234, 230, 225, 220, 214, 208, 200, 193, 184, 176, 167, 157, 147, 137, 127, 117, 107, 97, 87, 78, 69, 61, 54, 47, 40, 34, 29, 24, 21, 17, 14, 11, 9, 7, 6, 5, 4, 3, 2, 2, 1, 1, 1, 0, 0, 0, 0]),
] as [(Double, [Float])])
func wideBlursAt2x(radius: Double, apple: [Float]) throws {
    // Sigma is half the radius in points: `radius` pixels at 2x.
    let edge = 700
    let profile = try edgeProfile(sigma: radius, width: 1400, edge: edge)
    for (index, expected) in apple.enumerated() {
        let x = edge + (120 + index * 5 - 200) * 2
        #expect(abs(profile[x] - expected) <= 2, "radius \(radius), \(120 + index * 5) pt: \(profile[x]) against \(expected)")
    }
}

@Test("Wide blurs stay SpriteKit's Gaussian on a 3x iPhone", arguments: [
    // The same at 3x, read off an iPhone 17 Pro simulator's screen: black
    // bands 120 pt tall on white, so each row is the across profile times
    // the blur of the band's height at its middle, divided out here.
    (20.0, [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 253, 248, 236, 211, 172, 123, 74, 38, 15, 5, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    (50.0, [251, 251, 250, 250, 249, 247, 245, 241, 236, 230, 221, 209, 196, 180, 162, 143, 123, 103, 85, 67, 52, 39, 28, 20, 13, 9, 5, 3, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    (100.0, [186, 184, 181, 178, 174, 170, 165, 160, 154, 148, 142, 135, 128, 121, 114, 106, 98, 90, 82, 75, 67, 60, 53, 47, 41, 36, 31, 26, 22, 19, 15, 13, 10, 8, 7, 5, 4, 3, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0]),
] as [(Double, [Float])])
func wideBlursAt3x(radius: Double, apple: [Float]) throws {
    let sigmaPoints = radius / 2
    let band = Float(erf(60 / (sigmaPoints * 2.0.squareRoot())))
    let edge = 1000
    let profile = try edgeProfile(sigma: radius * 1.5, width: 2000, edge: edge)
    for (index, expected) in apple.enumerated() {
        let x = edge + (120 + index * 5 - 200) * 3 + 1
        #expect(abs(profile[x] * band - expected) <= 2, "radius \(radius), \(120 + index * 5) pt: \(profile[x] * band) against \(expected)")
    }
}

@Test("The texture reaches as far as the blur spreads: nothing clipped, no empty band", arguments: [8.0, 40.0, 75.0, 150.0])
func textureAndBlurAgree(sigma: Double) throws {
    // The contents end at the texture's reach short of its edge, as
    // `effectBounds` lays it out: three sigmas.
    let reach = Int((3 * sigma).rounded(.up))
    let profile = try edgeProfile(sigma: sigma, width: 2 * reach + 40, edge: reach + 40)
    // Next to nothing reaches the texture's last texel, so the texture
    // clips nothing that shows...
    #expect(profile[profile.count - 1] <= 1.5)
    // ...and the blur still reaches most of the way there.
    #expect(profile[reach + 40 + Int(2.5 * sigma)] >= 1)
}

@Test("A blurred edge falls off as SpriteKit's does")
func edgeMatchesSpriteKit() throws {
    // A black square's right edge at x = 300 px of a 2x SKView, blurred at
    // radius 4 (sigma 4 px): alpha from x = 290 on, as SpriteKit drew it.
    let apple: [Float] = [253, 250, 247, 241, 233, 221, 206, 187, 164, 140, 115, 90, 68, 48,
                          33, 21, 13, 8, 4, 2, 1, 0, 0, 0, 0, 0]
    let kernel = try #require(EffectBlur(sigma: 4))
    let width = 60, edge = 30
    var row = [Float](repeating: 0, count: width * 4)
    for x in 0..<edge { row[x * 4 + 3] = 255 }
    let out = kernel.blurred(row, width: width, height: 1, horizontal: true)
    for (index, expected) in apple.enumerated() {
        let x = edge - 10 + index
        #expect(abs(out[x * 4 + 3] - expected) <= 3, "x \(x - edge): \(out[x * 4 + 3]) against \(expected)")
    }
}

@Test("Red beside green blurs as stored, not in linear light")
func coloursMixAsStored() throws {
    // SpriteKit: (140, 115, 0) and (115, 140, 0) half a texel either side of
    // the seam, at sigma 4 px.
    let kernel = try #require(EffectBlur(sigma: 4))
    let width = 80, seam = 40
    var row = [Float](repeating: 0, count: width * 4)
    for x in 0..<width {
        row[x * 4 + (x < seam ? 0 : 1)] = 255
        row[x * 4 + 3] = 255
    }
    let out = kernel.blurred(row, width: width, height: 1, horizontal: true)
    #expect(abs(out[(seam - 1) * 4] - 140) <= 3 && abs(out[(seam - 1) * 4 + 1] - 115) <= 3)
    #expect(abs(out[seam * 4] - 115) <= 3 && abs(out[seam * 4 + 1] - 140) <= 3)
}

@Test("Both passes together blur a point into a round Gaussian")
func passesMakeARoundBlur() throws {
    let kernel = try #require(EffectBlur(sigma: 3))
    let side = 41, centre = 20
    var pixels = [Float](repeating: 0, count: side * side * 4)
    pixels[(centre * side + centre) * 4 + 3] = 1
    let across = kernel.blurred(pixels, width: side, height: side, horizontal: true)
    let both = kernel.blurred(across, width: side, height: side, horizontal: false)
    func alpha(_ x: Int, _ y: Int) -> Float { both[(y * side + x) * 4 + 3] }
    #expect(abs(both.enumerated().filter { $0.offset % 4 == 3 }.reduce(0) { $0 + $1.element } - 1) < 1e-4)
    // As far along a row as up a column, and centred.
    #expect(abs(alpha(centre + 4, centre) - alpha(centre, centre + 4)) < 1e-6)
    #expect(abs(alpha(centre - 4, centre) - alpha(centre + 4, centre)) < 1e-6)
}
