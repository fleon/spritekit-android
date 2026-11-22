import CoreGraphics
import Foundation
import RuntimeTestSupport
import Testing
@testable import SpriteKitShim

// A shape node's frame as Apple's SpriteKit reports it, measured on a Mac
// (macOS 27.2): the path's bounds, grown by a visible stroke's half width,
// its glow and, antialiased, 1.2 points of soft edge.

@Suite("A shape node's frame")
@MainActor
struct ShapeFrameTests {
    private func shape(lineWidth: CGFloat = 4, stroke: SKColor = .blue) -> SKShapeNode {
        let node = SKShapeNode()
        node.path = CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 20), transform: nil)
        node.fillColor = .red
        node.strokeColor = stroke
        node.lineWidth = lineWidth
        return node
    }

    private func expectFrame(_ frame: CGRect, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        #expect(near(frame.minX, x, 1e-4) && near(frame.minY, y, 1e-4), "\(frame)")
        #expect(near(frame.width, width, 1e-4) && near(frame.height, height, 1e-4), "\(frame)")
    }

    @Test("A visible stroke adds half its width and the soft edge")
    func strokedReach() {
        expectFrame(shape().frame, -3.2, -3.2, 16.4, 26.4)
        expectFrame(shape(lineWidth: 20).frame, -11.2, -11.2, 32.4, 42.4)
        expectFrame(shape(lineWidth: 0.01).frame, -1.205, -1.205, 12.41, 22.41)
        expectFrame(shape(stroke: SKColor(white: 1, alpha: 0.01)).frame, -3.2, -3.2, 16.4, 26.4)
    }

    @Test("A clear or widthless stroke adds nothing")
    func noStroke() {
        expectFrame(shape(stroke: .clear).frame, 0, 0, 10, 20)
        expectFrame(shape(stroke: SKColor(white: 1, alpha: 0)).frame, 0, 0, 10, 20)
        expectFrame(shape(lineWidth: 0).frame, 0, 0, 10, 20)
        expectFrame(shape(lineWidth: -2).frame, 0, 0, 10, 20)
        #expect(SKShapeNode().frame == .zero)
    }

    @Test("Glow adds its width, and a hard edge drops the soft one")
    func glowAndAntialiasing() {
        let glowing = shape()
        glowing.glowWidth = 3
        expectFrame(glowing.frame, -6.2, -6.2, 22.4, 32.4)
        let hard = shape()
        hard.isAntialiased = false
        expectFrame(hard.frame, -2, -2, 14, 24)
    }

    @Test("The frame scales with the node, and accumulates into its parent's")
    func scaledAndAccumulated() {
        let scaled = shape()
        scaled.xScale = 2
        scaled.yScale = 3
        expectFrame(scaled.frame, -6.4, -9.6, 32.8, 79.2)
        let parent = SKNode()
        let upper = shape(lineWidth: 0.01)
        upper.position = CGPoint(x: 0, y: 60)
        let lower = shape(lineWidth: 0.01)
        lower.position = CGPoint(x: 0, y: -60)
        parent.addChild(upper)
        parent.addChild(lower)
        expectFrame(parent.calculateAccumulatedFrame(), -1.205, -61.205, 12.41, 142.41)
    }
}
