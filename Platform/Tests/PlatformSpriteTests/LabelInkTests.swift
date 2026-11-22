// Labels aligned by their font's metrics draw their ink where the metrics
// say, SpriteKit's baseline padding taken off: capitals centred on a point
// have their ink's middle on it. On the Mac host from the shim's layout;
// on Mac Catalyst rendered by Apple's SpriteKit and read back. There the
// Mac's text rasterizing spreads the capitals' feet a few tenths of a point
// down (an iPhone's doesn't: Tools/BaselineProbe), so the drawn baseline is
// read from their tops, less the cap height.
#if canImport(Darwin)
import CoreText
import Foundation
import SpriteKitShim
import Testing
@testable import PlatformSprite
import PlatformTestSupport

private enum Fixture {
    static let font = "Helvetica-Bold"
    /// Capitals with flat tops and feet: their ink is baseline to cap height.
    static let text = "HHH"
    static let point = pt(20, 100)

    static func capHeight(_ size: CGFloat) -> CGFloat {
        CTFontGetCapHeight(CTFontCreateWithName(font as CFString, size, nil))
    }
}

/// One way of aligning a label, and how the ink it draws should sit.
private struct Case: CustomStringConvertible {
    var name: String
    var size: CGFloat
    var labelScale: CGFloat = 1
    var parentScale: CGFloat = 1
    var mode: SKLabelVerticalAlignmentMode = .center
    var builder = false

    var description: String { "\(name) \(size)pt mode \(mode.rawValue) label×\(labelScale) parent×\(parentScale)" }

    /// The label, aligned at the point in a parent of its own, in `scene`.
    @MainActor
    func place(in scene: SKScene) -> SKLabelNode {
        let parent = SKNode()
        parent.setScale(parentScale)
        scene.addChild(parent)
        let local = pt(Fixture.point.x / parentScale, Fixture.point.y / parentScale)
        let label: SKLabelNode
        if builder {
            label = PlatformSprite.label(
                .fontNamed(Fixture.font, size), .text(Fixture.text), .hAlign(.left), .vAlign(mode), .band(.capitals), .parent(parent)
            )
            label.setScale(labelScale)
            label.position = local
        } else {
            label = SKLabelNode(fontNamed: Fixture.font)
            label.fontSize = size
            label.text = Fixture.text
            label.horizontalAlignmentMode = .left
            label.setScale(labelScale)
            parent.addChild(label)
            label.align(mode, at: local, band: .capitals)
        }
        label.fontColor = .white
        return label
    }

    /// Where the capitals' ink should be, in the scene.
    var expectedInk: (bottom: CGFloat, top: CGFloat) {
        let cap = Fixture.capHeight(size) * labelScale * parentScale
        let y = Fixture.point.y
        return switch mode {
        case .top: (y - cap, y)
        case .bottom: (y, y + cap)
        default: (y - cap / 2, y + cap / 2)
        }
    }
}

private let cases: [Case] = [13, 19, 20, 23, 40].flatMap { size in
    [Case(name: "align", size: size), Case(name: "builder", size: size, builder: true)]
} + [
    Case(name: "align", size: 20, labelScale: 2),
    Case(name: "align", size: 20, parentScale: 2.68),
    Case(name: "builder", size: 20, labelScale: 1.5, parentScale: 3, builder: true),
    Case(name: "align", size: 23, mode: .top),
    Case(name: "builder", size: 23, mode: .bottom, builder: true),
]

struct LabelInkTests {
    /// The capitals' ink `label` draws in `scene`, `cap` tall there, in the
    /// scene's points: on Apple's SpriteKit, from their top down.
    @MainActor
    private func ink(of label: SKLabelNode, in scene: SKScene, cap: CGFloat) throws -> (bottom: CGFloat, top: CGFloat) {
        #if SPRITEKIT_SHIM
        let ink = try #require(drawnLine(label, in: scene)).ink
        #expect(near(ink.height, cap))
        return (ink.minY, ink.maxY)
        #else
        let top = try #require(renderedInk(scene)).top
        return (top - cap, top)
        #endif
    }

    /// Rendered, the edges are read to a few hundredths of a point; the
    /// shim's layout is exact.
    #if SPRITEKIT_SHIM
    private let tolerance: CGFloat = 1e-6
    #else
    private let tolerance: CGFloat = 0.05
    #endif

    @Test @MainActor func capitalsAlignedByTheirBandDrawTheirInkThere() throws {
        #if SPRITEKIT_SHIM
        try #require(ShimText.installed)
        #endif
        for test in cases {
            let scene = SKScene(size: sz(200, 200))
            let label = test.place(in: scene)
            let expected = test.expectedInk
            let drawn = try ink(of: label, in: scene, cap: expected.top - expected.bottom)
            #expect(near(drawn.bottom, expected.bottom, tolerance), "\(test): bottom \(drawn.bottom), expected \(expected.bottom)")
            #expect(near(drawn.top, expected.top, tolerance), "\(test): top \(drawn.top), expected \(expected.top)")
            if test.mode == .center {
                #expect(near((drawn.bottom + drawn.top) / 2, Fixture.point.y, tolerance), "\(test)")
            }
        }
    }

    @Test @MainActor func spriteKitDrawsABaselineLabelsBaselineAPointAboveItsPosition() throws {
        #if SPRITEKIT_SHIM
        try #require(ShimText.installed)
        #endif
        for (size, scale) in [(CGFloat(13), CGFloat(1)), (20, 1), (40, 1), (20, 2), (20, 0.5)] {
            let scene = SKScene(size: sz(200, 200))
            let label = SKLabelNode(fontNamed: Fixture.font)
            label.fontSize = size
            label.text = Fixture.text
            label.fontColor = .white
            label.horizontalAlignmentMode = .left
            label.setScale(scale)
            label.position = pt(20, 50.3)
            scene.addChild(label)
            let drawn = try ink(of: label, in: scene, cap: Fixture.capHeight(size) * scale)
            // In the label's own points, whatever its size or scale.
            #expect(near((drawn.bottom - 50.3) / scale, SKLabelNode.baselinePadding, tolerance / scale), "\(size)pt ×\(scale): \(drawn)")
        }
    }

    #if canImport(UIKit)
    @Test @MainActor func textBlocksDrawTheirLinesOnTheirBaselines() throws {
        let font = try #require(UIFont(name: Fixture.font, size: 20))
        for anchor in [TextBlockNode.Anchor.firstBaseline, .top] {
            let scene = SKScene(size: sz(200, 200))
            let block = TextBlockNode(
                Fixture.text, maxWidth: 180, font: font, color: .white, alignment: .left, lineSpacing: 4, anchor: anchor, band: .capitals
            )
            block.position = Fixture.point
            scene.addChild(block)
            let cap = font.capHeight
            let top = try #require(renderedInk(scene)).top
            let drawn = (bottom: top - cap, top: top)
            switch anchor {
            case .firstBaseline:
                #expect(near(drawn.bottom, Fixture.point.y, tolerance), "\(drawn)")
            case .top:
                // The capitals centred in the line's height below the top.
                let middle = Fixture.point.y - (block.lineAdvance - 4) / 2
                #expect(near((drawn.bottom + drawn.top) / 2, middle, tolerance), "\(drawn)")
            }
            #expect(near(Fixture.point.y + block.lastBaselineY, drawn.bottom, tolerance))
        }
    }
    #endif
}
#endif
