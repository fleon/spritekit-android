// An `SKEffectNode`'s `CIGaussianBlur`, as SpriteKit draws it. Measured on a
// Mac (macOS 27.2, a 2x SKView, `texture(from:)`) and in an iPhone 17 Pro
// simulator (iOS 27, 3x, a screenshot), a black square blurred at radius
// 3, 6 and 12:
//
// - the blur's sigma is half the radius in points at every scale: 3, 6 and
//   12 px at 2x, 4.5, 8.9 and 18 px at 3x;
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
    // A very wide one is cut at the most pairs a pass takes.
    #expect(try #require(EffectBlur(sigma: 200)).pairs.count == EffectBlur.maximumPairs)
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
