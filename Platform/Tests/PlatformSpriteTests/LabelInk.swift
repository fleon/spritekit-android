// Where a label's text is drawn, not where its node is: on the Mac host,
// the shim's own layout (the pen's origin on the baseline, through a text
// provider that measures with CoreText); on Mac Catalyst, Apple's
// SpriteKit rendered offscreen and its ink read back.
#if canImport(Darwin)
import CoreText
import Foundation
import SpriteKitShim
import Testing
@testable import PlatformSprite
#if !SPRITEKIT_SHIM
import Metal
#endif

/// A line's advance and the bounds of its ink, as CoreText measures it.
func measured(_ text: String, font: CTFont) -> (advance: CGFloat, ink: CGRect) {
    let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    return (CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), CTLineGetBoundsWithOptions(line, .useGlyphPathBounds))
}

#if SPRITEKIT_SHIM
private final class CoreTextProvider: TextProvider, @unchecked Sendable {
    private func font(_ key: FontKey) -> CTFont { CTFontCreateWithName(key.name as CFString, key.size, nil) }

    func fontMetrics(_ key: FontKey) -> FontMetrics? {
        let font = font(key)
        return FontMetrics(
            ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font), leading: CTFontGetLeading(font),
            capHeight: CTFontGetCapHeight(font), xHeight: CTFontGetXHeight(font)
        )
    }

    func measure(_ text: String, font key: FontKey) -> TextLine {
        let line = measured(text, font: font(key))
        return TextLine(text: text, advance: line.advance, inkBounds: line.ink)
    }

    func breakLines(_ text: String, font: FontKey, maxWidth: CGFloat) -> [String] { [text] }
    func breakOffsets(in text: String) -> [Int] { [0] }
}

enum ShimText {
    /// Installs the CoreText provider, once, so the shim's labels lay out.
    static let installed: Bool = {
        if TextMetrics.provider == nil { TextMetrics.provider = CoreTextProvider() }
        return true
    }()
}

/// Where the label's first line is drawn, in `parent`: its pen's origin on
/// the baseline (an `AlignedLabelNode`'s from its text child), and the ink
/// of that line.
func drawnLine(_ label: SKLabelNode, in parent: SKNode) -> (baseline: CGFloat, ink: CGRect)? {
    let text = (label as? AlignedLabelNode)?.textNode ?? label
    guard let placed = text.layout?.lines.first else { return nil }
    let ink = placed.line.inkBounds.offsetBy(dx: placed.origin.x, dy: placed.origin.y)
    let bottom = text.convert(pt(ink.minX, ink.minY), to: parent)
    let top = text.convert(pt(ink.maxX, ink.maxY), to: parent)
    return (text.convert(placed.origin, to: parent).y, CGRect(x: bottom.x, y: bottom.y, width: top.x - bottom.x, height: top.y - bottom.y))
}
#else
/// Apple's SpriteKit, rendered offscreen at `pixelsPerPoint` through an
/// `SKRenderer`, and the ink read back: the lowest and highest edges of
/// what's drawn at x ≥ `fromX`, in the scene's points. Two bars at x 0–4
/// calibrate points to pixels (`scene` is laid out from the origin, its
/// anchor at zero, and must leave them that corner).
@MainActor
func renderedInk(_ scene: SKScene, pixelsPerPoint: CGFloat = 3, fromX: CGFloat = 10) -> (bottom: CGFloat, top: CGFloat)? {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let commands = queue.makeCommandBuffer() else { return nil }
    let low: CGFloat = 2, high = scene.size.height - 4
    var bars: [SKNode] = []
    for y in [low, high] {
        let bar = SKSpriteNode(color: .white, size: sz(4, 2))
        bar.anchorPoint = .zero
        bar.position = pt(0, y)
        scene.addChild(bar)
        bars.append(bar)
    }
    defer { bars.forEach { $0.removeFromParent() } }
    scene.anchorPoint = .zero
    scene.scaleMode = .fill
    scene.backgroundColor = .clear

    let width = Int(scene.size.width * pixelsPerPoint), height = Int(scene.size.height * pixelsPerPoint)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    pass.colorAttachments[0].storeAction = .store
    let renderer = SKRenderer(device: device)
    renderer.scene = scene
    renderer.update(atTime: 0)
    renderer.render(withViewport: CGRect(x: 0, y: 0, width: width, height: height), commandBuffer: commands, renderPassDescriptor: pass)
    commands.commit()
    commands.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let alpha = (0 ..< height).map { row in (0 ..< width).map { bytes[(row * width + $0) * 4 + 3] } }

    guard let calibration = inkEdges(alpha, x0: 0, x1: Int(pixelsPerPoint * 2)),
          let ink = inkEdges(alpha, x0: Int(fromX * pixelsPerPoint), x1: width) else { return nil }
    // The low bar's bottom is at `low`, the high bar's top at `high + 2`.
    let scale = (calibration.top - calibration.bottom) / (high + 2 - low)
    let origin = calibration.bottom - low * scale
    return ((ink.bottom - origin) / scale, (ink.top - origin) / scale)
}

/// The lowest and highest ink edges, in pixels up from the bottom, in
/// columns `x0..<x1` of rows of alpha (row 0 the top): from the first fully
/// covered row in, less the cover of the rows beyond it, which places a
/// step edge exactly however the texture's filtering softens it.
private func inkEdges(_ alpha: [[UInt8]], x0: Int, x1: Int) -> (bottom: CGFloat, top: CGFloat)? {
    let cover = alpha.map { row in CGFloat(row[x0 ..< x1].max() ?? 0) / 255 }
    guard let full = cover.max(), full > 0.5,
          let low = cover.lastIndex(where: { $0 >= full - 0.01 }),
          let high = cover.firstIndex(where: { $0 >= full - 0.01 }) else { return nil }
    let below = cover[(low + 1)...].reduce(0, +) / full
    let above = cover[..<high].reduce(0, +) / full
    return (CGFloat(cover.count - 1 - low) - below, CGFloat(cover.count - high) + above)
}
#endif
#endif
