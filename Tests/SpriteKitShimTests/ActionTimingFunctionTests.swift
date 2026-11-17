import Foundation
import Testing
@testable import SpriteKitShim

// `SKAction.timingFunction`, and how a timing mode and a timing function
// shape an action's time, pinned to SpriteKit's own: each case was run
// through `SKRenderer` on a Mac (macOS 27.2) at a tenth of a second a frame,
// and the numbers expected here are what it reported.

@MainActor
private func positions(_ action: SKAction, frames: Int, every delta: TimeInterval = 0.1,
                       read: (SKNode) -> CGFloat = { $0.position.x }) -> [CGFloat] {
    let node = SKNode()
    node.run(action)
    return (0..<frames).map { _ in
        node.tickActions(delta)
        return read(node)
    }
}

private func matches(_ seen: [CGFloat], _ expected: [CGFloat], _ tolerance: CGFloat = 0.005) -> Bool {
    seen.count == expected.count && zip(seen, expected).allSatisfy { abs($0 - $1) < tolerance }
}

private let squared: SKActionTimingFunction = { $0 * $0 }

/// Penner's back ease out, which overshoots 1 from 0.4 on.
private let backOut: SKActionTimingFunction = { t in
    let s: Float = 1.70158
    let u = t - 1
    return u * u * ((s + 1) * u + s) + 1
}

private func move() -> SKAction { .moveBy(x: 100, y: 0, duration: 1) }

@Suite("Actions: SpriteKit's timing functions")
@MainActor
struct ActionTimingFunctionTests {
    @Test("Unset, an action runs straight")
    func unset() {
        #expect(move().timingFunction == nil)
        #expect(matches(positions(move(), frames: 10), [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]))
    }

    @Test("A function shapes a move's progress")
    func shapesAMove() {
        let action = move()
        action.timingFunction = squared
        #expect(matches(positions(action, frames: 10), [1, 4, 9, 16, 25, 36, 49, 64, 81, 100]))
    }

    @Test("What it returns is clamped: an overshooting curve holds at the end and finishes there")
    func clampsAndFinishesEarly() {
        let action = move()
        action.timingFunction = backOut
        #expect(matches(positions(action, frames: 6), [40.8828, 70.5802, 90.7132, 100, 100, 100]))

        let fade = SKAction.fadeAlpha(to: 0, duration: 1)
        fade.timingFunction = backOut
        #expect(matches(positions(fade, frames: 4, read: { $0.alpha }), [0.5912, 0.2942, 0.0929, 0], 0.0001))

        let scale = SKAction.scale(to: 2, duration: 1)
        scale.timingFunction = backOut
        #expect(matches(positions(scale, frames: 4, read: { $0.xScale }), [1.4088, 1.7058, 1.9071, 2], 0.0001))

        // Clamped below too: a curve that starts negative waits at 0.
        let late = move()
        late.timingFunction = { $0 - 0.5 }
        #expect(matches(positions(late, frames: 10), [0, 0, 0, 0, 0, 10, 20, 30, 40, 50]))

        // Done once the curve reaches 1: what follows starts there, with
        // nothing left over (the frame that got there was all used).
        let back = move()
        back.timingFunction = backOut
        let then = positions(.sequence([back, .moveBy(x: 0, y: 100, duration: 1)]), frames: 6, read: { $0.position.y })
        #expect(matches(then, [0, 0, 0, 0, 10, 20]))
    }

    @Test("A curve that never reaches 1 never finishes")
    func neverFinishes() {
        let node = SKNode()
        let action = move()
        action.timingFunction = { $0 * 0.5 }
        var done = false
        node.run(action) { done = true }
        for _ in 0..<40 { node.tickActions(0.1) }
        #expect(!done)
        #expect(abs(node.position.x - 50) < 0.001)
        #expect(node.hasActions)
    }

    @Test("The function runs on what the timing mode gives, whichever was set first")
    func composesWithTheMode() {
        let expected: [CGFloat] = [0.0361, 0.5184, 2.3409, 6.5536, 14.0625, 25.4016, 40.5769, 58.9824, 79.3881, 100]
        let functionFirst = move()
        functionFirst.timingFunction = squared
        functionFirst.timingMode = .easeIn
        #expect(matches(positions(functionFirst, frames: 10), expected))

        let modeFirst = move()
        modeFirst.timingMode = .easeIn
        modeFirst.timingFunction = squared
        #expect(modeFirst.timingMode == .easeIn)
        #expect(matches(positions(modeFirst, frames: 10), expected))
    }

    @Test("A custom action's block is handed curved seconds, by the mode and by the function")
    func customActions() {
        func custom() -> SKAction { .customAction(withDuration: 1) { node, elapsed in node.position.x = elapsed * 100 } }

        let byFunction = custom()
        byFunction.timingFunction = squared
        #expect(matches(positions(byFunction, frames: 10), [1, 4, 9, 16, 25, 36, 49, 64, 81, 100]))

        let byMode = custom()
        byMode.timingMode = .easeIn
        #expect(matches(positions(byMode, frames: 10), [1.9, 7.2, 15.3, 25.6, 37.5, 50.4, 63.7, 76.8, 89.1, 100]))

        // At 0.15 s a frame, squared.
        var seen: [CGFloat] = []
        let recorded = SKAction.customAction(withDuration: 1) { _, elapsed in seen.append(elapsed) }
        recorded.timingFunction = squared
        let node = SKNode()
        node.run(recorded)
        for _ in 0..<8 { node.tickActions(0.15) }
        #expect(matches(seen, [0.0225, 0.09, 0.2025, 0.36, 0.5625, 0.81, 1], 0.001))
    }

    @Test("A sequence or group runs its children on its curve")
    func containers() {
        let sequence = SKAction.sequence([.moveBy(x: 50, y: 0, duration: 0.5), .moveBy(x: 50, y: 0, duration: 0.5)])
        sequence.timingFunction = squared
        #expect(matches(positions(sequence, frames: 10), [1, 4, 9, 16, 25, 36, 49, 64, 81, 100]))

        let group = SKAction.group([move()])
        group.timingFunction = squared
        #expect(matches(positions(group, frames: 10), [1, 4, 9, 16, 25, 36, 49, 64, 81, 100]))

        let eased = SKAction.sequence([.moveBy(x: 50, y: 0, duration: 0.5), .moveBy(x: 50, y: 0, duration: 0.5)])
        eased.timingMode = .easeIn
        #expect(matches(positions(eased, frames: 10), [1.9, 7.2, 15.3, 25.6, 37.5, 50.4, 63.7, 76.8, 89.1, 100]))

        let easedGroup = SKAction.group([move()])
        easedGroup.timingMode = .easeIn
        #expect(matches(positions(easedGroup, frames: 10), [1.9, 7.2, 15.3, 25.6, 37.5, 50.4, 63.7, 76.8, 89.1, 100]))

        // A curve on the child as well as the sequence: one after the other.
        let inner = move()
        inner.timingFunction = squared
        let nested = SKAction.sequence([inner])
        nested.timingFunction = squared
        #expect(matches(positions(nested, frames: 10), [0.01, 0.16, 0.81, 2.56, 6.25, 12.96, 24.01, 40.96, 65.61, 100]))

        // An overshooting curve finishes the sequence early, as it does a move.
        let back = SKAction.sequence([.moveBy(x: 50, y: 0, duration: 0.5), .moveBy(x: 50, y: 0, duration: 0.5)])
        back.timingFunction = backOut
        #expect(matches(positions(back, frames: 5), [40.8828, 70.5802, 90.7132, 100, 100]))

        // A wait, then a block: the wait ends right on the fifth frame, so the
        // block runs on the sixth.
        var firedOn = 0
        var frame = 0
        let waitThenRun = SKAction.sequence([.wait(forDuration: 0.5), .run { firedOn = frame }])
        waitThenRun.timingFunction = squared
        let node = SKNode()
        node.run(waitThenRun)
        for f in 1 ... 10 {
            frame = f
            node.tickActions(0.1)
        }
        #expect(firedOn == 6)
    }

    @Test("A repeat ignores its own mode and function")
    func repeatsIgnoreIt() {
        let straight: [CGFloat] = [20, 40, 60, 80, 100, 120, 140, 160, 180, 200]
        let counted = SKAction.repeat(.moveBy(x: 100, y: 0, duration: 0.5), count: 2)
        counted.timingFunction = squared
        #expect(matches(positions(counted, frames: 10), straight))

        let moded = SKAction.repeat(.moveBy(x: 100, y: 0, duration: 0.5), count: 2)
        moded.timingMode = .easeIn
        #expect(matches(positions(moded, frames: 10), straight))

        let forever = SKAction.repeatForever(.moveBy(x: 100, y: 0, duration: 0.5))
        forever.timingFunction = squared
        #expect(matches(positions(forever, frames: 10), straight))
    }

    @Test("Speed runs the curve faster")
    func speed() {
        let action = move()
        action.speed = 2
        action.timingFunction = squared
        #expect(matches(positions(action, frames: 6), [4, 16, 36, 64, 100, 100]))
    }

    @Test("Reversing keeps the mode and the function as they are")
    func reversing() {
        let squaredMove = move()
        squaredMove.timingFunction = squared
        #expect(matches(positions(squaredMove.reversed(), frames: 10), [-1, -4, -9, -16, -25, -36, -49, -64, -81, -100]))

        let easeIn = move()
        easeIn.timingMode = .easeIn
        #expect(easeIn.reversed().timingMode == .easeIn)
        #expect(matches(positions(easeIn.reversed(), frames: 10), [-1.9, -7.2, -15.3, -25.6, -37.5, -50.4, -63.7, -76.8, -89.1, -100]))

        let both = move()
        both.timingMode = .easeOut
        both.timingFunction = squared
        #expect(matches(positions(both.reversed(), frames: 10),
                        [-1.1881, -5.3824, -13.1769, -24.6016, -39.0625, -55.3536, -71.7409, -86.1184, -96.2361, -100]))
    }

    @Test("Time a frame runs past an eased end carries on")
    func carriesOver() {
        let eased = move()
        eased.timingMode = .easeIn
        let modeThen = positions(.sequence([eased, .moveBy(x: 0, y: 100, duration: 1)]), frames: 8, every: 0.15, read: { $0.position.y })
        #expect(matches(modeThen, [0, 0, 0, 0, 0, 0, 5, 20]))

        let curved = move()
        curved.timingFunction = squared
        let functionThen = positions(.sequence([curved, .moveBy(x: 0, y: 100, duration: 1)]), frames: 8, every: 0.15)
        #expect(matches(functionThen, [2.25, 9, 20.25, 36, 56.25, 81, 100, 100]))
    }
}

@Suite("Shaders: subclassing")
@MainActor
struct ShaderSubclassTests {
    /// A shader wrapped in a type of its own.
    final class Pattern: SKShader {
        var progress: CGFloat { didSet { uniformNamed("u_progress")?.floatValue = Float(progress) } }

        init(progress: CGFloat) {
            self.progress = progress
            super.init(source: "void main() { gl_FragColor = vec4(u_progress); }",
                       uniforms: [SKUniform(name: "u_progress", float: Float(progress))])
        }

        required init?(coder aDecoder: NSCoder) { fatalError() }
    }

    @Test("A subclass sets its uniforms through SKShader's own API")
    func subclass() {
        let pattern = Pattern(progress: 0.25)
        let sprite = SKSpriteNode(color: .white, size: CGSize(width: 4, height: 4))
        sprite.shader = pattern
        pattern.progress = 0.75
        #expect(pattern.uniformNamed("u_progress")?.floatValue == 0.75)
        #expect(sprite.shader === pattern)
    }
}
