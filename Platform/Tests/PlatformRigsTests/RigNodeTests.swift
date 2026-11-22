import Foundation
import Testing
import SpriteKitShim
@testable import PlatformRigs

@Suite("Drawing a rig")
struct RigNodeTests {
    private let texture = SKTexture(color: .white, size: CGSize(width: 128, height: 128))

    private func node(caching: Bool = true, regionsAsSprites: Bool = false, hiding: Set<String> = []) throws -> RigNode {
        RigNode(data: try #require(RigFixture.data), texture: texture, unit: 2, hiding: hiding, regionsAsSprites: regionsAsSprites, caching: caching)
    }

    @Test("Each attachment gets a part, and only what each slot shows is drawn")
    func parts() throws {
        let rig = try node()
        let data = rig.data
        let head = try #require(data.slot(named: "head")), clip = try #require(data.slot(named: "clip"))
        #expect(rig.parts.count == data.slots.count)
        #expect(rig.parts[head].count == 2)
        #expect(rig.parts[clip].isEmpty)
        // Two meshes and four regions, each drawn as its triangles.
        #expect(rig.meshes.count == 6)
        let shown = try #require(data.skin[head]["head"]), other = try #require(data.skin[head]["head2"])
        #expect(rig.parts[head][shown]?.isHidden == false)
        #expect(rig.parts[head][other]?.isHidden == true)

        rig.play("walk", loop: true)
        rig.pose.advance(0.45)
        rig.render()
        // Walk hides the head from 0.4 on.
        #expect(rig.parts[head].values.allSatisfy { $0.isHidden })
    }

    @Test("What a clip holds draws inside a crop node")
    func clipping() throws {
        let rig = try node()
        let flag = try #require(rig.data.slot(named: "flag")), body = try #require(rig.data.slot(named: "body"))
        let flagPart = try #require(rig.parts[flag].values.first), bodyPart = try #require(rig.parts[body].values.first)
        #expect(flagPart.parent is SKCropNode)
        #expect(bodyPart.parent === rig.content)
    }

    @Test("Hidden slots get no parts")
    func hiding() throws {
        let rig = try node(hiding: ["tip"])
        let tip = try #require(rig.data.slot(named: "tip"))
        #expect(rig.parts[tip].isEmpty)
    }

    @Test("A region drawn as a sprite rides its bone, at the node's unit")
    func sprites() throws {
        let rig = try node(regionsAsSprites: true)
        let tip = try #require(rig.data.slot(named: "tip"))
        let sprite = try #require(rig.parts[tip].values.first as? SKSpriteNode)
        let bone = try #require(rig.bone(named: "tail2"))
        // The region sits 4 along its bone.
        #expect(abs(sprite.position.x - (bone.x + bone.a * 4 * 2)) < 1e-6)
        #expect(abs(sprite.position.y - (bone.y + bone.c * 4 * 2)) < 1e-6)
        #expect(abs(sprite.zRotation - atan2(bone.c, bone.a)) < 1e-6)
    }

    @Test("A carried node follows its bone from where it stood at rest")
    func carry() throws {
        let rig = try node()
        let rider = SKNode()
        rig.carry(rider, on: "move")
        let rest = rider.parent?.position ?? .zero
        rig.play("jump", loop: true)
        rig.pose.advance(0.3)
        rig.render()
        let lifted = try #require(rider.parent?.position)
        #expect(abs(lifted.y - rest.y - 40 * 2) < 1e-6)
    }

    @Test("Only a move at a steady size is travel, in the rig's units at its size")
    func travel() {
        let unit: CGFloat = 0.5
        let from = (at: CGPoint(x: 10, y: 20), size: CGFloat(2))
        let moved = RigNode.travel(from: from, to: (at: CGPoint(x: 30, y: 10), size: 2), unit: unit)
        #expect(moved == CGPoint(x: 20, y: -10))
        #expect(RigNode.travel(from: nil, to: from, unit: unit) == nil, "nothing to move from")
        #expect(RigNode.travel(from: from, to: (at: CGPoint(x: 30, y: 10), size: 2.1), unit: unit) == nil, "zooming isn't travel")
        #expect(RigNode.travel(from: from, to: (at: CGPoint(x: 30, y: 10), size: 2.0015), unit: unit) != nil, "a hair's change still is")
        let speck = (at: CGPoint.zero, size: RigNode.leastTrailingScale / 2)
        #expect(RigNode.travel(from: speck, to: (at: CGPoint(x: 1, y: 0), size: speck.size), unit: unit) == nil, "a speck trails nothing")
    }

    @Test("A still rig caches its parts; a moving or swinging one draws them live")
    func caching() throws {
        let json: [String: Any] = [
            "bones": [["name": "root"], ["name": "b", "parent": "root", "length": 10]],
            "slots": [["name": "s", "bone": "b", "attachment": "r"]],
            "skins": [["name": "default", "attachments": ["s": ["r": ["width": 8, "height": 8]]]]],
            "animations": ["turn": ["bones": ["b": ["rotate": [["value": 0], ["time": 1, "value": 90]]]]]],
            "atlas": ["r": [0, 0, 8, 8]],
        ]
        let data = try #require(RigData(json: json, textureURL: URL(fileURLWithPath: "/dev/null")))
        #expect(!data.tintsColor)
        let rig = RigNode(data: data, texture: texture)
        let canvas = try #require(rig.content as? SKEffectNode)
        rig.updateCaching()
        #expect(canvas.shouldRasterize)
        rig.play("turn", loop: true)
        rig.updateCaching()
        #expect(!canvas.shouldRasterize)
        rig.isPaused = true
        #expect(canvas.shouldRasterize)
        rig.isPaused = false
        #expect(!canvas.shouldRasterize)

        let live = RigNode(data: data, texture: texture, caching: false)
        #expect(!(live.content is SKEffectNode))

        let lit = LitRig(data: data, texture: texture)
        lit.updateCaching()
        #expect((lit.content as? SKEffectNode)?.shouldRasterize == false)
    }
}

/// A rig whose look changes while it stands still.
private final class LitRig: RigNode {
    override var mayCache: Bool { false }
}
