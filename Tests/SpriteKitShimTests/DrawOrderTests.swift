import Foundation
import Testing
@testable import SpriteKitShim

// The order SpriteKit draws nodes at the same z, pinned to its own: two
// overlapping nodes of each kind, red then blue, were rendered with
// `SKRenderer` on a Mac (macOS 27.2) and the middle pixel read back to see
// which came out on top, with `ignoresSiblingOrder` false and true.

@Suite("Draw order at the same z")
@MainActor
struct DrawOrderTests {
    enum Kind: CaseIterable, CustomStringConvertible {
        case colour, textured, label, shape, filledWithTexture, shader, crop, effect
        var description: String { "\(self)" }
    }

    private static let texture = SKTexture(cgImage: RasterImage(width: 4, height: 4, pixels: [UInt8](repeating: 255, count: 64)))

    private func make(_ kind: Kind) -> SKNode {
        let size = CGSize(width: 64, height: 64)
        switch kind {
        case .colour: return SKSpriteNode(color: .red, size: size)
        case .textured: return SKSpriteNode(texture: Self.texture, size: size)
        case .label: return SKLabelNode(text: "88")
        case .shape:
            let shape = SKShapeNode(rect: CGRect(x: -32, y: -32, width: 64, height: 64))
            shape.fillColor = .red
            return shape
        case .filledWithTexture:
            let shape = SKShapeNode(rect: CGRect(x: -32, y: -32, width: 64, height: 64))
            shape.fillColor = .white
            shape.fillTexture = Self.texture
            return shape
        case .shader:
            let sprite = SKSpriteNode(color: .white, size: size)
            sprite.shader = SKShader(source: "void main() { gl_FragColor = vec4(1.0); }")
            return sprite
        case .crop:
            let crop = SKCropNode()
            crop.addChild(SKSpriteNode(color: .red, size: size))
            return crop
        case .effect:
            let effect = SKEffectNode()
            effect.addChild(SKSpriteNode(color: .red, size: size))
            return effect
        }
    }

    private func x(_ command: DrawList.Command) -> CGFloat {
        switch command {
        case let .sprite(sprite): return sprite.transform.tx
        case let .shape(shape): return shape.transform.tx
        case let .label(label): return label.transform.tx
        case let .effect(effect): return effect.transform.tx
        case let .crop(crop): return crop.transform.tx
        default: return .nan
        }
    }

    /// Whether the second of two nodes at the same z draws over the first.
    private func secondOnTop(_ first: Kind, _ second: Kind, ignoresSiblingOrder: Bool) -> Bool {
        let scene = SKScene(size: CGSize(width: 64, height: 64))
        let a = make(first), b = make(second)
        a.position.x = 1
        b.position.x = 2
        scene.addChild(a)
        scene.addChild(b)
        let commands = DrawList(scene: scene, ignoresSiblingOrder: ignoresSiblingOrder).commands
        return commands.map(x) == [1, 2]
    }

    @Test("Keeping sibling order, SpriteKit's default: tree order, whatever the kinds")
    func keepingSiblingOrder() {
        for first in Kind.allCases {
            for second in Kind.allCases {
                #expect(secondOnTop(first, second, ignoresSiblingOrder: false), "\(first) then \(second)")
            }
        }
    }

    /// SpriteKit's readback, the first of each pair red, the second blue,
    /// 30 runs each where the answer could vary: colour sprites, shapes and
    /// groups under textured sprites and labels, those under shader sprites,
    /// and tree order within each. Between two textures, or two labels,
    /// SpriteKit's answer varied from run to run (11 to 19 of 30 each way);
    /// two sprites cut from one texture kept tree order in all 30.
    @Test("Ignoring sibling order: three classes, each in tree order")
    func ignoringSiblingOrder() {
        func tier(_ kind: Kind) -> Int {
            switch kind {
            case .colour, .shape, .filledWithTexture, .crop, .effect: return 0
            case .textured, .label: return 1
            case .shader: return 2
            }
        }
        for first in Kind.allCases {
            for second in Kind.allCases {
                let expected = tier(second) >= tier(first)
                #expect(secondOnTop(first, second, ignoresSiblingOrder: true) == expected, "\(first) then \(second)")
            }
        }
    }

    /// SpriteKit's readback for three nodes at one z, ignoring sibling
    /// order: A1, B, A2 (A1 and A2 one texture) drew A1, A2, B in 28 of 30
    /// runs; a label, a textured sprite and a label drew the sprite over
    /// both labels in 19 of 30.
    @Test("Ignoring sibling order, one texture's sprites draw together, and the labels together")
    func textureGroups() {
        func order(_ nodes: [SKNode]) -> [CGFloat] {
            let scene = SKScene(size: CGSize(width: 64, height: 64))
            for (index, node) in nodes.enumerated() {
                node.position.x = CGFloat(index + 1)
                scene.addChild(node)
            }
            return DrawList(scene: scene, ignoresSiblingOrder: true).commands.map(x)
        }
        let atlas = SKTexture(cgImage: RasterImage(width: 4, height: 4, pixels: [UInt8](repeating: 255, count: 64)))
        let other = SKTexture(cgImage: RasterImage(width: 4, height: 4, pixels: [UInt8](repeating: 128, count: 64)))
        let size = CGSize(width: 64, height: 64)
        let a1 = SKSpriteNode(texture: SKTexture(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), in: atlas), size: size)
        let a2 = SKSpriteNode(texture: SKTexture(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), in: atlas), size: size)
        #expect(order([a1, SKSpriteNode(texture: other, size: size), a2]) == [1, 3, 2])
        #expect(order([SKLabelNode(text: "1"), SKSpriteNode(texture: other, size: size), SKLabelNode(text: "2")]) == [1, 3, 2])
        // Kept sibling order: tree order still.
        let kept = SKScene(size: CGSize(width: 64, height: 64))
        for (index, node) in [SKSpriteNode(texture: atlas, size: size), SKSpriteNode(texture: other, size: size), SKSpriteNode(texture: atlas, size: size)].enumerated() {
            node.position.x = CGFloat(index + 1)
            kept.addChild(node)
        }
        #expect(DrawList(scene: kept).commands.map(x) == [1, 2, 3])
    }

    @Test("A label over a shape or colour sprite, nested or not; a higher z still wins")
    func labelsAndZ() {
        let nested = SKScene(size: CGSize(width: 40, height: 40))
        let a = SKNode(), b = SKNode()
        nested.addChild(a)
        a.addChild(b)
        let label = SKLabelNode(text: "88")
        b.addChild(label)
        let sprite = SKSpriteNode(color: .green, size: CGSize(width: 40, height: 40))
        nested.addChild(sprite)
        guard case .label = DrawList(scene: nested, ignoresSiblingOrder: true).commands.last else {
            Issue.record("the label should draw last")
            return
        }
        sprite.zPosition = 0.5
        guard case .sprite = DrawList(scene: nested, ignoresSiblingOrder: true).commands.last else {
            Issue.record("the sprite above should draw last")
            return
        }
    }

    @Test("Inside a crop or effect group, the same rule; the group is one of the first class")
    func groups() {
        let scene = SKScene(size: CGSize(width: 40, height: 40))
        let crop = SKCropNode()
        let label = SKLabelNode(text: "88")
        crop.addChild(label)
        crop.addChild(SKSpriteNode(color: .green, size: CGSize(width: 40, height: 40)))
        scene.addChild(crop)
        let commands = DrawList(scene: scene, ignoresSiblingOrder: true).commands
        guard case let .crop(group)? = commands.first else {
            Issue.record("expected one crop group")
            return
        }
        guard case .label = group.contents.commands.last else {
            Issue.record("the label should draw last inside the crop")
            return
        }
        let kept = DrawList(scene: scene, ignoresSiblingOrder: false).commands
        guard case let .crop(inTreeOrder)? = kept.first, case .sprite = inTreeOrder.contents.commands.last else {
            Issue.record("keeping sibling order, the later sprite should draw last inside the crop")
            return
        }
    }

    @Test("A view keeps sibling order unless told not to, as SpriteKit's does")
    func viewDefault() {
        #expect(SKView(bounds: CGRect(x: 0, y: 0, width: 10, height: 10)).ignoresSiblingOrder == false)
        #expect(SKRenderer(device: MTLDevice()).ignoresSiblingOrder == false)
    }
}
