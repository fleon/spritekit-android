// A label aligned by its font's band keeps the band at its `position`
// through whatever is done to it after it's built. These run on the Mac
// host against the shim, and on Mac Catalyst against Apple's SpriteKit,
// whose actions set a node's position without going through its setter.
import Foundation
import Testing
import SpriteKitShim
@testable import PlatformSprite
import PlatformTestSupport
#if !SPRITEKIT_SHIM
import Metal
#endif

private enum Fixture {
    static let font = "Helvetica-Bold"
    static let size: CGFloat = 30
    static let point = pt(40, 120)

    static func metrics(size: CGFloat = size) -> FontBandMetrics { FontBandMetrics(fontNamed: font, size: size) }

    /// Where the text's baseline should be, in the parent, for a band
    /// centred at `y`.
    static func baseline(centredAt y: CGFloat, size: CGFloat = size, scale: CGFloat = 1) -> CGFloat {
        y + metrics(size: size).baseline(.center, at: 0, band: .capitals) * scale
    }
}

/// Where the label's text is drawn on its baseline, in its parent: the
/// shim's pen origin; on Apple's SpriteKit, which doesn't say, SpriteKit's
/// padding above the text child (as `LabelInkTests` reads it rendered).
private func drawnBaseline(_ label: SKLabelNode, in parent: SKNode) throws -> CGFloat {
    let aligned = try #require(label as? AlignedLabelNode)
    #if SPRITEKIT_SHIM
    try #require(ShimText.installed)
    return try #require(drawnLine(aligned, in: parent)).baseline
    #else
    return aligned.textNode.convert(pt(0, SKLabelNode.baselinePadding), to: parent).y
    #endif
}

/// Runs the scene's actions for `seconds`, as a view would.
private func runActions(_ scene: SKScene, for seconds: TimeInterval) {
    #if SPRITEKIT_SHIM
    let step = 1.0 / 60
    var elapsed = 0.0
    while elapsed < seconds + step {
        scene.tickActions(step)
        elapsed += step
    }
    #else
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let renderer = SKRenderer(device: device)
    renderer.scene = scene
    var time = 100.0
    renderer.update(atTime: time)
    while time < 100 + seconds + 0.1 {
        time += 1.0 / 60
        renderer.update(atTime: time)
    }
    #endif
}

private func centred() -> SKLabelNode {
    label(.fontNamed(Fixture.font, Fixture.size), .vAlign(.center), .band(.capitals), .text("Quiz"))
}

struct AlignedLabelTests {
    @Test func positionAfterTheBuilderIsTheAlignmentPoint() throws {
        let scene = SKScene(size: sz(200, 200))
        let before = label(
            .fontNamed(Fixture.font, Fixture.size), .vAlign(.center), .band(.capitals), .text("Quiz"),
            .position(Fixture.point.x, Fixture.point.y), .parent(scene)
        )
        let after = label(.fontNamed(Fixture.font, Fixture.size), .vAlign(.center), .band(.capitals), .text("Quiz"), .parent(scene))
        after.position = Fixture.point
        #expect(before.position == Fixture.point && after.position == Fixture.point)
        let expected = Fixture.baseline(centredAt: Fixture.point.y)
        #expect(near(try drawnBaseline(before, in: scene), expected))
        #expect(near(try drawnBaseline(after, in: scene), expected))
        #expect(before.verticalAlignmentMode == .center)
        // Moved by its own position, as game code does.
        after.position.y += 10
        #expect(near(try drawnBaseline(after, in: scene), expected + 10))
    }

    @Test func topAndBottomStayAligned() throws {
        let scene = SKScene(size: sz(200, 200))
        for mode in [SKLabelVerticalAlignmentMode.top, .bottom, .baseline] {
            let made = AlignedLabelNode(mode, band: .line)
            made.fontName = Fixture.font
            made.fontSize = Fixture.size
            made.text = "Quiz"
            scene.addChild(made)
            made.position = Fixture.point
            let expected = Fixture.metrics().baseline(mode, at: Fixture.point.y, band: .line)
            #expect(near(try drawnBaseline(made, in: scene), expected), "\(mode.rawValue)")
        }
    }

    @Test func actionsKeepTheAlignment() throws {
        let scene = SKScene(size: sz(200, 200))
        let moved = centred()
        let scaled = centred()
        let resized = centred()
        [moved, scaled, resized].forEach(scene.addChild)
        scaled.position = Fixture.point
        resized.position = Fixture.point
        moved.run(.move(to: Fixture.point, duration: 0.1))
        scaled.run(.scale(to: 2, duration: 0.1))
        resized.run(.customAction(withDuration: 0.1) { node, elapsed in
            (node as? SKLabelNode)?.fontSize = Fixture.size + 20 * elapsed / 0.1
        })
        runActions(scene, for: 0.2)
        #expect(moved.position == Fixture.point)
        #expect(near(try drawnBaseline(moved, in: scene), Fixture.baseline(centredAt: Fixture.point.y)))
        // Scaled about the band's middle, which stays at the point.
        #expect(scaled.yScale == 2)
        #expect(near(try drawnBaseline(scaled, in: scene), Fixture.baseline(centredAt: Fixture.point.y, scale: 2)))
        #expect(near(resized.fontSize, Fixture.size + 20))
        #expect(near(try drawnBaseline(resized, in: scene), Fixture.baseline(centredAt: Fixture.point.y, size: Fixture.size + 20)))
    }

    @Test func scaleAndFontChangesFollowTheBandAndTextChangesDont() throws {
        let scene = SKScene(size: sz(200, 200))
        let made = centred()
        scene.addChild(made)
        made.position = Fixture.point
        made.setScale(1.5)
        #expect(near(try drawnBaseline(made, in: scene), Fixture.baseline(centredAt: Fixture.point.y, scale: 1.5)))
        made.setScale(1)
        made.fontSize = 50
        #expect(near(try drawnBaseline(made, in: scene), Fixture.baseline(centredAt: Fixture.point.y, size: 50)))
        let settled = try drawnBaseline(made, in: scene)
        let child = try #require(made as? AlignedLabelNode).textNode.position
        for text in ["MAP", "pqyg", "ภาษาไทย", ""] {
            made.text = text
            if !text.isEmpty { #expect(try drawnBaseline(made, in: scene) == settled, "\(text)") }
            #expect(try #require(made as? AlignedLabelNode).textNode.position == child, "\(text)")
        }
        #expect(made.position == Fixture.point)
    }

    @Test func alignMovesAnAlignedLabelAndKeepsItAligned() throws {
        let scene = SKScene(size: sz(200, 200))
        let made = centred()
        scene.addChild(made)
        made.align(.top, at: Fixture.point, band: .line)
        #expect(made.position == Fixture.point && made.verticalAlignmentMode == .top)
        made.position = pt(0, 0)
        #expect(near(try drawnBaseline(made, in: scene), Fixture.metrics().baseline(.top, at: 0, band: .line)))
    }

    @Test func theTextIsTheChilds() throws {
        let made = label(.fontNamed(Fixture.font, Fixture.size), .vAlign(.center), .text("Hi"), .color(.red), .hAlign(.left))
        let aligned = try #require(made as? AlignedLabelNode)
        #expect(aligned.textNode.text == "Hi" && made.text == "Hi")
        #expect(aligned.textNode.fontColor == .red && aligned.textNode.horizontalAlignmentMode == .left)
        #expect(aligned.textNode.verticalAlignmentMode == .baseline)
        made.text = "Bye"
        #expect(aligned.textNode.text == "Bye")
    }

    #if SPRITEKIT_SHIM
    @Test func theShimDrawsTheTextOnceOnItsBaseline() throws {
        try #require(ShimText.installed)
        let scene = SKScene(size: sz(200, 200))
        let made = centred()
        scene.addChild(made)
        made.position = Fixture.point
        let drawn = DrawList(scene: scene).commands.compactMap { command -> DrawList.Label? in
            if case .label(let label) = command { return label }
            return nil
        }
        #expect(drawn.count == 1)
        // The node SpriteKit's padding below the baseline, the pen on it.
        let baseline = Fixture.baseline(centredAt: Fixture.point.y)
        #expect(drawn.first.map { near($0.transform.ty, baseline - SKLabelNode.baselinePadding) } == true)
        let origin = try #require(drawn.first?.layout?.lines.first?.origin)
        #expect(near(try #require(drawn.first).transform.ty + origin.y, baseline))
    }
    #endif
}
