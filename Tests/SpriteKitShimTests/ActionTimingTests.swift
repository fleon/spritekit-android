import Foundation
import Testing
@testable import SpriteKitShim
import RuntimeTestSupport

// How actions spend a frame's time, pinned to SpriteKit's own: each case was
// run through `SKRenderer` on a Mac at exactly these frame times, and the
// numbers expected here are what it reported.

@MainActor
private func ticks(_ node: SKNode, _ deltas: [TimeInterval]) {
    for delta in deltas { node.tickActions(delta) }
}

@Suite("Actions: SpriteKit's timing")
@MainActor
struct ActionTimingTests {
    @Test("A wait's run fires on the frame that crosses it")
    func waitThenRun() {
        let node = SKNode()
        var firedOn = 0
        var frame = 0
        node.run(.sequence([.wait(forDuration: 0.2), .run { firedOn = frame }]))
        for f in 1 ... 16 {
            frame = f
            node.tickActions(1.0 / 60)
        }
        // Twelve sixtieths add up to a hair under 0.2.
        #expect(firedOn == 13)
    }

    @Test("A step ending right on a frame finishes there, but what follows starts on the next")
    func exactEnd() {
        let node = SKNode()
        var fired = false
        node.run(.sequence([.wait(forDuration: 0.25), .run { fired = true }]))
        ticks(node, [0.125, 0.125])
        #expect(!fired)
        node.tickActions(0.125)
        #expect(fired)

        // Its own completion comes on time, though.
        let mover = SKNode()
        var done = false
        mover.run(.moveBy(x: 100, y: 0, duration: 0.25)) { done = true }
        mover.tickActions(0.25)
        #expect(done)
        #expect(near(mover.position.x, 100))

        // And a timed step after it starts from the next frame: 0.0625 into
        // a 0.25 s move is a quarter of it.
        let pair = SKNode()
        pair.run(.sequence([.moveBy(x: 100, y: 0, duration: 0.25), .moveBy(x: 0, y: 100, duration: 0.25)]))
        pair.tickActions(0.25)
        #expect(near(pair.position.y, 0))
        pair.tickActions(0.0625)
        #expect(near(pair.position.y, 25))
    }

    @Test("Time left over carries into a sequence's next step")
    func sequenceCarries() {
        let node = SKNode()
        node.run(.sequence([.moveBy(x: 100, y: 0, duration: 0.1), .moveBy(x: 0, y: 100, duration: 0.1)]))
        node.tickActions(0.15)
        #expect(near(node.position.x, 100) && near(node.position.y, 50))
        node.tickActions(0.05)
        #expect(near(node.position.y, 100))

        var seen: [CGFloat] = []
        let custom = SKNode()
        custom.run(.sequence([.wait(forDuration: 0.1), .customAction(withDuration: 0.2) { _, elapsed in seen.append(elapsed) }]))
        ticks(custom, [0.15, 0.05])
        #expect(seen.count == 2 && near(seen[0], 0.05) && near(seen[1], 0.1))
    }

    @Test("A group hands on what its longest child left, and runs a finished child no more")
    func groups() {
        let node = SKNode()
        node.run(.sequence([
            .group([.moveBy(x: 100, y: 0, duration: 0.1), .wait(forDuration: 0.2)]),
            .moveBy(x: 0, y: 100, duration: 0.1),
        ]))
        node.tickActions(0.25)
        #expect(near(node.position.x, 100) && near(node.position.y, 50))

        var runs = 0
        let once = SKNode()
        once.run(.group([.run { runs += 1 }, .wait(forDuration: 0.2)]))
        ticks(once, [0, 0.1, 0.1, 0.1])
        #expect(runs == 1)
    }

    @Test("repeatForever runs on across each wrap")
    func repeatForeverCarries() {
        let swing = SKNode()
        swing.run(.repeatForever(.sequence([.moveBy(x: 100, y: 0, duration: 0.1), .moveBy(x: -100, y: 0, duration: 0.1)])))
        var seen: [CGFloat] = []
        for delta in [0.15, 0.1, 0.08, 0.14] {
            swing.tickActions(delta)
            seen.append(swing.position.x)
        }
        #expect(zip(seen, [50, 50, 70, 70] as [CGFloat]).allSatisfy { near($0, $1) })

        let slide = SKNode()
        slide.run(.repeatForever(.moveBy(x: 100, y: 0, duration: 0.1)))
        seen = []
        for delta in [0.15, 0.12, 0.14] {
            slide.tickActions(delta)
            seen.append(slide.position.x)
        }
        #expect(zip(seen, [150, 270, 410] as [CGFloat]).allSatisfy { near($0, $1, 1e-4) })

        // A long frame runs several rounds.
        var fires = 0
        let pulse = SKNode()
        pulse.run(.repeatForever(.sequence([.wait(forDuration: 0.1), .run { fires += 1 }])))
        pulse.tickActions(0.35)
        #expect(fires == 3)
    }

    @Test("A counted repeat hands on what it left")
    func countedRepeat() {
        let node = SKNode()
        node.run(.sequence([.repeat(.moveBy(x: 100, y: 0, duration: 0.1), count: 2), .moveBy(x: 0, y: 100, duration: 0.1)]))
        node.tickActions(0.25)
        #expect(near(node.position.x, 200) && near(node.position.y, 50))
    }

    @Test("The ease curves are SpriteKit's, tenth by tenth")
    func curves() {
        let measured: [(SKActionTimingMode, [CGFloat])] = [
            (.easeIn, [19, 72, 153, 256, 375, 504, 637, 768, 891, 1000]),
            (.easeOut, [109, 232, 363, 496, 625, 744, 847, 928, 981, 1000]),
            (.easeInEaseOut, [28, 104, 216, 352, 500, 648, 784, 896, 972, 1000]),
        ]
        for (mode, positions) in measured {
            let node = SKNode()
            let move = SKAction.moveBy(x: 1000, y: 0, duration: 1)
            move.timingMode = mode
            node.run(move)
            for expected in positions {
                node.tickActions(0.1)
                #expect(near(node.position.x, expected, 0.05), "\(mode) at \(expected)")
            }
        }
    }
}
