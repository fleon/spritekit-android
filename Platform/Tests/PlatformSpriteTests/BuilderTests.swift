import Foundation
import Testing
import SpriteKitShim
@testable import PlatformSprite

private func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 1e-3 && abs(a.minY - b.minY) < 1e-3 && abs(a.width - b.width) < 1e-3 && abs(a.height - b.height) < 1e-3
}

struct NodeHelperTests {
    private enum ActionKey: String {
        case spin = "owner.spin"
        case fade = "other.fade"
    }

    @Test func addsAtZAndPositionAndReturnsTheChild() {
        let parent = SKNode()
        let child = SKSpriteNode()
        let added = parent.addChild(child, z: 3, at: pt(4, 5))
        #expect(added === child)
        #expect(child.parent === parent)
        #expect(child.zPosition == 3)
        #expect(child.position == pt(4, 5))

        let unplaced = SKNode()
        unplaced.position = pt(1, 2)
        parent.addChild(unplaced, z: -1)
        #expect(unplaced.position == pt(1, 2))
        #expect(unplaced.zPosition == -1)
    }

    @Test func keyedActionsRunUnderTheirRawValues() {
        let node = SKNode()
        node.run(.wait(forDuration: 1), withKey: ActionKey.spin)
        #expect(node.action(forKey: "owner.spin") != nil)
        #expect(node.action(forKey: ActionKey.spin) != nil)
        #expect(node.hasAction(forKey: ActionKey.spin))
        #expect(node.hasAction(forKey: "owner.spin"))
        #expect(!node.hasAction(forKey: ActionKey.fade))

        node.run(.wait(forDuration: 1), withKey: ActionKey.fade)
        node.removeAction(forKey: ActionKey.spin)
        #expect(!node.hasAction(forKey: ActionKey.spin))
        #expect(node.hasAction(forKey: "other.fade"))
    }

    @Test func rectInSceneHoldsThroughRotation() {
        let scene = SKNode()
        let holder = SKNode()
        holder.position = pt(100, 0)
        holder.zRotation = .pi / 2
        scene.addChild(holder)
        let box = SKSpriteNode(color: .white, size: sz(10, 20))
        holder.addChild(box)
        #expect(close(rectInScene(for: box, scene: scene), rect(90, -5, 20, 10)))
        #expect(close(rectInScene(rect(0, 0, 10, 20), for: holder, scene: scene), rect(80, 0, 20, 10)))
        let loose = SKSpriteNode(color: .white, size: sz(4, 6))
        #expect(close(rectInScene(for: loose, scene: scene), rect(-2, -3, 4, 6)))
    }
}

struct PathBuilderTests {
    @Test func arcsTurnAsUIKitNamesThem() {
        // `.clockwise` rises from 0 to a quarter turn: the short way.
        let short = path(.arc((0, 0), 10, 0, .pi / 2, .clockwise))
        #expect(close(short.boundingBoxOfPath, rect(0, 0, 10, 10)))
        let long = path(.arc((0, 0), 10, 0, .pi / 2, .counterClockwise))
        #expect(close(long.boundingBoxOfPath, rect(-10, -10, 20, 20)))
    }

    @Test func shapesAreTheirOwnSubpaths() {
        #expect(close(path(.circle((5, 5), 5)).boundingBoxOfPath, rect(0, 0, 10, 10)))
        #expect(close(path(.ellipse(rect(0, 0, 4, 2))).boundingBoxOfPath, rect(0, 0, 4, 2)))
        let both = path([.rect(rect(0, 0, 2, 2)), .roundedRect(rect(10, 10, 10, 20), 4)])
        #expect(close(both.boundingBoxOfPath, rect(0, 0, 20, 30)))
    }

    @Test func roundedRectKeepsItsRadiusWithinTheSides() {
        // CoreGraphics would trap on a radius past half the shorter side.
        #expect(close(path(.roundedRect(rect(0, 0, 10, 20), 100)).boundingBoxOfPath, rect(0, 0, 10, 20)))
        #expect(close(path(.roundedRect(rect(0, 0, 10, 20), 0)).boundingBoxOfPath, rect(0, 0, 10, 20)))
    }

    @Test func linesAndCurvesContinueTheSubpath() {
        let line = path(.moveTo(0, 0), .lineTo(10, 0), .curveTo((10, 10), (15, 0), (15, 10)), .close)
        #expect(line.boundingBoxOfPath.minX == 0)
        #expect(line.boundingBoxOfPath.maxY == 10)
        #expect(line.boundingBoxOfPath.maxX > 10)
    }
}

struct LabelBuilderTests {
    @Test func appliesItsCommandsInOrder() {
        let parent = SKNode()
        let made = label(
            .fontNamed("Face-Bold", 18),
            .text("Hello"),
            .color(.red),
            .hAlign(.left),
            .vAlign(.center),
            .position(3, 4),
            .z(2),
            .alpha(0.5),
            .name("greeting"),
            .parent(parent)
        )
        #expect(made.fontName == "Face-Bold")
        #expect(made.fontSize == 18)
        #expect(made.text == "Hello")
        #expect(made.horizontalAlignmentMode == .left)
        #expect(made.verticalAlignmentMode == .center)
        #expect(made.position == pt(3, 4))
        #expect(made.zPosition == 2)
        #expect(made.alpha == 0.5)
        #expect(made.name == "greeting")
        #expect(made.parent === parent)
    }

    @Test func leavesSpriteKitsDefaults() {
        let made = label(.text("Plain"))
        #expect(made.horizontalAlignmentMode == .center)
        #expect(made.verticalAlignmentMode == .baseline)
        #expect(made.parent == nil)
    }
}
