import Foundation
import Testing
@testable import SpriteKitShim

// SKEmitterNode: snow, motes, bubbles and ambient particles. A frame is a value, so a particle's whole life can be
// checked on the host: how many are born, how long they live, where the
// ranges put them, and whose space they live in.

@Suite("Emitter")
struct EmitterTests {
    private let frame: TimeInterval = 1.0 / 60

    /// An emitter with nothing random about it, emitting `rate` a second.
    private func emitter(rate: CGFloat, lifetime: CGFloat = 100) -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.particleSize = CGSize(width: 10, height: 10)
        emitter.particleBirthRate = rate
        emitter.particleLifetime = lifetime
        emitter.randomSeed = 7
        return emitter
    }

    /// `frames` frames of the scene's update clock.
    private func run(_ scene: SKScene, frames: Int) {
        let view = SKView(bounds: CGRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        // The frame that presents it, which counts no time (`ActionClockTests`).
        _ = view.tick(currentTime: 0, delta: 0)
        for _ in 0 ..< frames { _ = view.tick(currentTime: 0, delta: frame) }
    }

    private func sprites(_ list: DrawList) -> [DrawList.Sprite] {
        list.commands.compactMap { if case let .sprite(sprite) = $0 { return sprite } else { return nil } }
    }

    @Test("Births follow the birth rate, frame by frame")
    func birthRate() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let node = emitter(rate: 30)
        scene.addChild(node)
        run(scene, frames: 60)
        #expect(node.particleCount == 30)
        run(scene, frames: 60)
        #expect(node.particleCount == 60)
    }

    @Test("numParticlesToEmit stops it, and a reset starts it again")
    func limit() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let node = emitter(rate: 60)
        node.numParticlesToEmit = 14
        scene.addChild(node)
        run(scene, frames: 120)
        #expect(node.particleCount == 14)
        node.resetSimulation()
        #expect(node.particleCount == 0)
        run(scene, frames: 5)
        #expect(node.particleCount == 5)
    }

    @Test("A particle dies at the end of its lifetime")
    func lifetime() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let node = emitter(rate: 60, lifetime: 0.5)
        scene.addChild(node)
        run(scene, frames: 120)
        // Steady state: half a second's worth alive.
        #expect((29 ... 31).contains(node.particleCount))
        #expect(node.particles.allSatisfy { $0.age < 0.5 })
        node.particleBirthRate = 0
        run(scene, frames: 31)
        #expect(node.particleCount == 0)
    }

    @Test("Ranges spread values both ways, within value ± range / 2")
    func ranges() {
        let node = emitter(rate: 600)
        node.particleLifetime = 50
        node.particleLifetimeRange = 20
        node.particlePositionRange = CGVector(dx: 40, dy: 10)
        node.emissionAngle = .pi / 2
        node.emissionAngleRange = 0.4
        node.particleSpeed = 38
        node.particleSpeedRange = 19
        node.particleScale = 0.42
        node.particleScaleRange = 0.21
        node.particleAlpha = 0.6
        node.particleAlphaRange = 0.2
        node.particleRotationRange = 1
        node.advanceSimulationTime(1)
        let all = node.particles
        #expect(all.count == 600)

        func check(_ values: [CGFloat], _ low: CGFloat, _ high: CGFloat) {
            let lo = values.min() ?? 0, hi = values.max() ?? 0
            #expect(lo >= low && hi <= high, "\(lo)...\(hi) outside \(low)...\(high)")
            // Both halves of the range are reached, not just one side.
            let span = high - low
            #expect(lo < low + span * 0.1 && hi > high - span * 0.1, "\(lo)...\(hi) narrower than \(low)...\(high)")
        }
        check(all.map(\.lifetime), 40, 60)
        check(all.map(\.scale), 0.42 - 0.105, 0.42 + 0.105)
        check(all.map(\.alpha), 0.5, 0.7)
        check(all.map(\.rotation), -0.5, 0.5)
        let speeds = all.map { hypot($0.velocity.dx, $0.velocity.dy) }
        check(speeds, 28.5, 47.5)
        let angles = all.map { atan2($0.velocity.dy, $0.velocity.dx) }
        check(angles, .pi / 2 - 0.2, .pi / 2 + 0.2)
        // Where each was born: its position less the way it has moved.
        let births = all.map { CGPoint(x: $0.position.x - $0.velocity.dx * $0.age,
                                       y: $0.position.y - $0.velocity.dy * $0.age) }
        check(births.map(\.x), -20 - 1e-6, 20 + 1e-6)
        check(births.map(\.y), -5 - 1e-6, 5 + 1e-6)
    }

    @Test("A seed plays the same particles every time")
    func seeded() {
        func lifetimes(seed: UInt64) -> [CGFloat] {
            let node = emitter(rate: 120)
            node.particleLifetimeRange = 10
            node.randomSeed = seed
            node.advanceSimulationTime(0.5)
            return node.particles.map(\.lifetime)
        }
        #expect(lifetimes(seed: 3) == lifetimes(seed: 3))
        #expect(lifetimes(seed: 3) != lifetimes(seed: 4))
    }

    @Test("advanceSimulationTime plays out as that many frames would")
    func advance() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let ticked = emitter(rate: 45, lifetime: 0.8)
        ticked.particleSpeed = 20
        ticked.particleSpeedRange = 10
        ticked.emissionAngleRange = .pi
        scene.addChild(ticked)
        run(scene, frames: 90)

        let jumped = emitter(rate: 45, lifetime: 0.8)
        jumped.particleSpeed = 20
        jumped.particleSpeedRange = 10
        jumped.emissionAngleRange = .pi
        jumped.advanceSimulationTime(1.5)

        #expect(ticked.particleCount == jumped.particleCount)
        for (a, b) in zip(ticked.particles, jumped.particles) {
            #expect(abs(a.position.x - b.position.x) < 1e-6 && abs(a.position.y - b.position.y) < 1e-6)
            #expect(abs(a.age - b.age) < 1e-6)
        }
    }

    @Test("Paused emitters hold still; speed scales their time")
    func pauseAndSpeed() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let holder = SKNode()
        scene.addChild(holder)
        let node = emitter(rate: 30)
        holder.addChild(node)
        holder.isPaused = true
        run(scene, frames: 60)
        #expect(node.particleCount == 0)
        holder.isPaused = false
        holder.speed = 2
        run(scene, frames: 30)
        #expect(node.particleCount == 30)
    }

    @Test("Without a target, particles move with the emitter")
    func ownSpace() {
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        let node = emitter(rate: 60)
        node.position = CGPoint(x: 50, y: 50)
        scene.addChild(node)
        run(scene, frames: 1)
        node.position = CGPoint(x: 150, y: 80)
        let sprite = sprites(DrawList(scene: scene))[0]
        #expect(sprite.transform.tx == 150 && sprite.transform.ty == 80)
    }

    @Test("With a target, particles stay where they were born")
    func targetSpace() {
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        let world = SKNode()
        world.position = CGPoint(x: 10, y: 20)
        scene.addChild(world)
        let mover = SKNode()
        mover.position = CGPoint(x: 40, y: 0)
        world.addChild(mover)
        let node = emitter(rate: 60)
        node.position = CGPoint(x: 0, y: 30)
        node.targetNode = world
        mover.addChild(node)

        run(scene, frames: 1)
        // Born at the emitter, in the world's space.
        #expect(node.particles[0].position == CGPoint(x: 40, y: 30))
        var sprite = sprites(DrawList(scene: scene))[0]
        #expect(sprite.transform.tx == 50 && sprite.transform.ty == 50)

        // The emitter moves on; the particle doesn't follow it.
        mover.position = CGPoint(x: 120, y: -40)
        sprite = sprites(DrawList(scene: scene))[0]
        #expect(abs(sprite.transform.tx - 50) < 1e-9 && abs(sprite.transform.ty - 50) < 1e-9)

        // The next one is born where the emitter is now.
        run(scene, frames: 1)
        #expect(node.particles[1].position == CGPoint(x: 120, y: -10))

        // Moving the target carries them all.
        world.position = CGPoint(x: 0, y: 0)
        sprite = sprites(DrawList(scene: scene))[0]
        #expect(abs(sprite.transform.tx - 40) < 1e-9 && abs(sprite.transform.ty - 30) < 1e-9)
    }

    @Test("Particles draw as sprites at the emitter's depth, in z order with the rest")
    func depth() {
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        let back = SKSpriteNode(color: .red, size: CGSize(width: 5, height: 5))
        back.zPosition = 1
        let front = SKSpriteNode(color: .blue, size: CGSize(width: 5, height: 5))
        front.zPosition = 3
        let layer = SKNode()
        layer.zPosition = 1
        let node = emitter(rate: 120)
        node.zPosition = 0.5
        node.particleZPosition = 0.25
        node.particleColor = .green
        node.particleColorBlendFactor = 1
        node.particleBlendMode = .add
        layer.addChild(node)
        scene.addChild(front)
        scene.addChild(layer)
        scene.addChild(back)
        run(scene, frames: 2)
        let drawn = sprites(DrawList(scene: scene))
        #expect(drawn.count == 6)
        #expect(drawn.first?.color === SKColor.red)
        #expect(drawn.last?.color === SKColor.blue)
        let particles = drawn.dropFirst().dropLast()
        #expect(particles.allSatisfy { $0.color === SKColor.green && $0.blendMode == .add && $0.colorBlendFactor == 1 })
        #expect(particles.allSatisfy { $0.size == CGSize(width: 10, height: 10) })
    }

    @Test("Sequences override alpha and scale over a particle's life")
    func sequences() {
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        let node = emitter(rate: 60, lifetime: 1)
        node.numParticlesToEmit = 1
        node.particleAlphaSequence = SKKeyframeSequence(keyframeValues: [0, 1, 1, 0], times: [0, 0.1, 0.75, 1])
        node.particleScaleSequence = SKKeyframeSequence(keyframeValues: [CGFloat(0.2), 1, 2], times: [0, 0.5, 1])
        node.particleScale = 7
        scene.addChild(node)
        run(scene, frames: 4)  // born on the first, three frames old: 0.05 of its life
        var sprite = sprites(DrawList(scene: scene))[0]
        #expect(abs(sprite.alpha - 0.5) < 1e-6)
        #expect(abs(sprite.size.width - 10 * (0.2 + 0.8 * 0.1)) < 1e-6)
        run(scene, frames: 27)  // half its life
        sprite = sprites(DrawList(scene: scene))[0]
        #expect(abs(sprite.alpha - 1) < 1e-6)
        #expect(abs(sprite.size.width - 10) < 1e-6)
    }

    @Test("Speeds change alpha, scale and rotation as particles age")
    func speeds() {
        let node = emitter(rate: 60)
        node.numParticlesToEmit = 1
        node.particleAlphaSpeed = -0.5
        node.particleScaleSpeed = 0.1
        node.particleRotationSpeed = 2
        node.advanceSimulationTime(1 + frame)
        let particle = node.particles[0]
        #expect(abs(particle.alpha - 0.5) < 1e-6)
        #expect(abs(particle.scale - 1.1) < 1e-6)
        #expect(abs(particle.rotation - 2) < 1e-6)
    }

    @Test("Acceleration bends the particles' paths")
    func acceleration() {
        let node = emitter(rate: 60)
        node.numParticlesToEmit = 1
        node.yAcceleration = -10
        node.advanceSimulationTime(1 + frame)
        #expect(abs(node.particles[0].velocity.dy + 10) < 1e-6)
        #expect(node.particles[0].position.y < -4.9)
    }

    @Test("particleAction moves each particle on top of its own motion")
    func particleAction() {
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        let node = emitter(rate: 60)
        node.numParticlesToEmit = 1
        node.particleSpeed = 60
        node.emissionAngle = .pi / 2
        node.particleAction = .repeatForever(.sequence([
            .moveBy(x: 6, y: 0, duration: 0.5),
            .moveBy(x: -6, y: 0, duration: 0.5),
        ]))
        scene.addChild(node)
        run(scene, frames: 31)  // half a second old
        let sprite = sprites(DrawList(scene: scene))[0]
        #expect(abs(sprite.transform.tx - 6) < 1e-6)
        #expect(abs(sprite.transform.ty - 30) < 1e-6)
    }

    @Test("A shader and its attributes reach every particle")
    func shader() {
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        let node = emitter(rate: 60)
        let shader = SKShader(source: "void main() { gl_FragColor = vec4(1.0); }")
        node.shader = shader
        node.setValue(SKAttributeValue(float: 0.5), forAttribute: "a_glow")
        scene.addChild(node)
        run(scene, frames: 3)
        let drawn = sprites(DrawList(scene: scene))
        #expect(drawn.count == 3)
        #expect(drawn.allSatisfy { $0.shader === shader && $0.attributeValues["a_glow"] != nil })
    }

    @Test("A colour sequence and a blend factor sequence colour each particle by its age")
    func colourSequences() {
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        let node = emitter(rate: 60, lifetime: 1)
        node.numParticlesToEmit = 1
        node.particleColor = .red
        node.particleColorSequence = SKKeyframeSequence(keyframeValues: [SKColor.black, SKColor.white], times: [0, 1])
        node.particleColorBlendFactorSequence = SKKeyframeSequence(keyframeValues: [0, 1], times: [0, 1])
        scene.addChild(node)
        run(scene, frames: 16)  // a quarter of its life
        let sprite = sprites(DrawList(scene: scene))[0]
        #expect(abs(sprite.color.red - 0.25) < 1e-6 && abs(sprite.color.blue - 0.25) < 1e-6)
        #expect(abs(sprite.colorBlendFactor - 0.25) < 1e-6)
    }
}

// SKKeyframeSequence on its own, against what SpriteKit does with each mode.
@Suite("Keyframe sequence")
struct KeyframeSequenceTests {
    private func number(_ sequence: SKKeyframeSequence, _ time: CGFloat) -> CGFloat {
        sequence.sample(atTime: time) as? CGFloat ?? .nan
    }

    @Test("Numbers arrive mixed (Int, CGFloat, NSNumber) and come back as CGFloat")
    func mixedNumbers() {
        let alpha: CGFloat = 0.4
        let sequence = SKKeyframeSequence(keyframeValues: [0, alpha, alpha, 0], times: [0, 0.2, 0.8, 1])
        #expect(sequence.count() == 4)
        #expect(abs(number(sequence, 0.1) - 0.2) < 1e-9)
        #expect(number(sequence, 0.5) == alpha)
        #expect(abs(number(sequence, 0.9) - 0.2) < 1e-9)
        let boxed = SKKeyframeSequence(keyframeValues: [NSNumber(value: 2), 4.0], times: [0, 1])
        #expect(number(boxed, 0.5) == 3)
    }

    @Test("Linear runs straight between keyframes")
    func linear() {
        let sequence = SKKeyframeSequence(keyframeValues: [0, 10, 4], times: [0, 0.5, 1])
        #expect(sequence.interpolationMode == .linear)
        #expect(number(sequence, 0) == 0)
        #expect(number(sequence, 0.25) == 5)
        #expect(number(sequence, 0.5) == 10)
        #expect(abs(number(sequence, 0.75) - 7) < 1e-9)
        #expect(number(sequence, 1) == 4)
    }

    @Test("Step holds each keyframe until the next one's time")
    func step() {
        let sequence = SKKeyframeSequence(keyframeValues: [0, 10, 4], times: [0, 0.5, 1])
        sequence.interpolationMode = .step
        #expect(number(sequence, 0.49) == 0)
        #expect(number(sequence, 0.5) == 10)
        #expect(number(sequence, 0.99) == 10)
        #expect(number(sequence, 1) == 4)
    }

    @Test("Spline passes through every keyframe and curves between them")
    func spline() {
        let peak = SKKeyframeSequence(keyframeValues: [0, 1, 0], times: [0, 0.5, 1])
        peak.interpolationMode = .spline
        #expect(number(peak, 0) == 0 && number(peak, 0.5) == 1 && number(peak, 1) == 0)
        // Catmull-Rom with the ends repeated: rounder than the straight line.
        #expect(abs(number(peak, 0.25) - 0.5625) < 1e-9)
        #expect(abs(number(peak, 0.75) - 0.5625) < 1e-9)
        // Evenly spaced keyframes on a line stay on it.
        let ramp = SKKeyframeSequence(keyframeValues: [0, 1, 2, 3], times: [0, 1, 2, 3])
        ramp.interpolationMode = .spline
        for time in stride(from: CGFloat(1), through: 2, by: 0.125) {
            #expect(abs(number(ramp, time) - time) < 1e-9)
        }
        // No corner at a keyframe: the slope either side of it agrees.
        let e: CGFloat = 1e-4
        let left = (number(peak, 0.5) - number(peak, 0.5 - e)) / e
        let right = (number(peak, 0.5 + e) - number(peak, 0.5)) / e
        #expect(abs(left - right) < 1e-2)
    }

    @Test("Clamp holds the ends; loop wraps over the keyframes' span")
    func repeatModes() {
        let sequence = SKKeyframeSequence(keyframeValues: [0, 10], times: [0, 1])
        #expect(sequence.repeatMode == .clamp)
        #expect(number(sequence, -1) == 0)
        #expect(number(sequence, 2) == 10)
        sequence.repeatMode = .loop
        #expect(abs(number(sequence, 1.25) - 2.5) < 1e-9)
        #expect(abs(number(sequence, 3.5) - 5) < 1e-9)
        #expect(abs(number(sequence, -0.25) - 7.5) < 1e-9)

        let offset = SKKeyframeSequence(keyframeValues: [0, 10], times: [1, 3])
        offset.repeatMode = .loop
        #expect(abs(number(offset, 4) - 5) < 1e-9)
    }

    @Test("Colours interpolate channel by channel, and step as numbers do")
    func colours() {
        let sequence = SKKeyframeSequence(keyframeValues: [SKColor.black, SKColor(red: 1, green: 0.5, blue: 0, alpha: 0.5)], times: [0, 1])
        let mid = sequence.sample(atTime: 0.5) as? SKColor
        #expect(mid.map { $0.red == 0.5 && $0.green == 0.25 && $0.blue == 0 && $0.alpha == 0.75 } == true)
        sequence.interpolationMode = .step
        #expect((sequence.sample(atTime: 0.5) as? SKColor) === SKColor.black)
    }

    @Test("Keyframes keep time order however they're added or moved")
    func editing() {
        let sequence = SKKeyframeSequence(capacity: 3)
        #expect(sequence.sample(atTime: 0) == nil)
        sequence.addKeyframeValue(10, time: 1)
        #expect(number(sequence, 0.3) == 10)
        sequence.addKeyframeValue(0, time: 0)
        #expect(number(sequence, 0.5) == 5)
        sequence.setKeyframeTime(2, for: 0)  // the 0 moves after the 10
        #expect(sequence.getKeyframeTime(for: 0) == 1 && sequence.getKeyframeTime(for: 1) == 2)
        #expect(number(sequence, 1.5) == 5 && number(sequence, 2) == 0)
        sequence.removeLastKeyframe()
        #expect(sequence.count() == 1)
    }
}
