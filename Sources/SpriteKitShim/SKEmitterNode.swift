#if SPRITEKIT_SHIM
import Foundation

/// A particle emitter, simulated here in Swift and drawn as sprites.
///
/// The game builds every emitter in code (no .sks files): the reef's marine
/// snow and motes, its bubbling vents and the bursts a tap lets go
/// (`SeabedNode`), and every other world's pollen, dust, bubbles, fireflies
/// and twinkles (`AmbientParticlesNode` in `BackdropNode`). `ShaderPrimer`
/// reads `shader`. This is that surface and the properties SpriteKit puts
/// beside it.
///
/// **Ranges** are SpriteKit's: a value's whole spread, so a particle takes
/// `value ± range / 2`, uniformly. A position range is a box that wide and
/// that tall round the emitter.
///
/// **Sequences** run over a particle's life, 0 to 1, and override the value
/// they stand for, its range and its speed.
///
/// **Time** is the scene's: the simulation steps in `tickActions`, after the
/// emitter's own actions (so a `run` block that changes the birth rate takes
/// effect that frame), scaled by the node's speed and stopped while it or an
/// ancestor is paused, as actions are. Long steps are cut into steps no
/// longer than `maximumStep`, so a stalled frame and `advanceSimulationTime`
/// both play out as a run of ordinary frames would.
///
/// **Randomness** comes from a seeded generator, one per emitter, seeded in
/// the order emitters are made: the same scene built the same way plays the
/// same particles. `randomSeed` is the shim's own, for tests.
///
/// **Space.** Particles live in the emitter's space and move with it, unless
/// `targetNode` is set: then each is born where the emitter is at that
/// moment, in the target's space, and stays there as the emitter moves on.
/// Either way they draw at the emitter's depth (plus `particleZPosition`),
/// oldest first.
open class SKEmitterNode: SKNode {
    // MARK: Birth

    open var particleBirthRate: CGFloat = 0
    /// How many to emit before stopping; 0 emits for ever.
    open var numParticlesToEmit: Int = 0
    open var particleLifetime: CGFloat = 0
    open var particleLifetimeRange: CGFloat = 0

    // MARK: Position and motion

    open var particlePosition: CGPoint = .zero
    open var particlePositionRange: CGVector = .zero
    open var particleZPosition: CGFloat = 0
    open var emissionAngle: CGFloat = 0
    open var emissionAngleRange: CGFloat = 0
    open var particleSpeed: CGFloat = 0
    open var particleSpeedRange: CGFloat = 0
    open var xAcceleration: CGFloat = 0
    open var yAcceleration: CGFloat = 0

    // MARK: Look

    open var particleTexture: SKTexture?
    /// Zero draws each particle at its texture's size.
    open var particleSize: CGSize = .zero
    open var particleBlendMode: SKBlendMode = .alpha
    open var shader: SKShader?
    open var attributeValues: [String: SKAttributeValue] = [:]

    open var particleColor: SKColor = .white
    open var particleColorSequence: SKKeyframeSequence?
    open var particleColorBlendFactor: CGFloat = 0
    open var particleColorBlendFactorRange: CGFloat = 0
    open var particleColorBlendFactorSpeed: CGFloat = 0
    open var particleColorBlendFactorSequence: SKKeyframeSequence?

    open var particleAlpha: CGFloat = 1
    open var particleAlphaRange: CGFloat = 0
    open var particleAlphaSpeed: CGFloat = 0
    open var particleAlphaSequence: SKKeyframeSequence?

    open var particleScale: CGFloat = 1
    open var particleScaleRange: CGFloat = 0
    open var particleScaleSpeed: CGFloat = 0
    open var particleScaleSequence: SKKeyframeSequence?

    open var particleRotation: CGFloat = 0
    open var particleRotationRange: CGFloat = 0
    open var particleRotationSpeed: CGFloat = 0

    /// Run on every particle as it is born (the vents' wobble). It moves,
    /// fades, scales and turns the particle on top of its own motion.
    open var particleAction: SKAction?

    /// The node whose space particles live in. Nil: the emitter's own.
    open weak var targetNode: SKNode?

    // MARK: Simulation

    /// The longest step simulated at once.
    public static let maximumStep: TimeInterval = 1.0 / 60

    /// Seeds this emitter's generator; setting it restarts the sequence.
    public var randomSeed: UInt64 {
        didSet { random = ParticleRandom(seed: randomSeed) }
    }

    private static let seeds = SeedCounter()
    private var random: ParticleRandom
    private(set) var particles: [Particle] = []
    /// Births owed but not yet due: a fraction of a particle.
    private var owed: CGFloat = 0
    private var emitted = 0

    public override init() {
        randomSeed = SKEmitterNode.seeds.next()
        random = ParticleRandom(seed: randomSeed)
        super.init()
    }

    /// Particles alive now.
    public var particleCount: Int { particles.count }

    open func setValue(_ value: SKAttributeValue, forAttribute key: String) {
        attributeValues[key] = value
    }

    open func value(forAttributeNamed key: String) -> SKAttributeValue? {
        attributeValues[key]
    }

    /// Plays `sec` seconds at once, as though they had passed, so an
    /// ambient emitter starts full rather than empty.
    open func advanceSimulationTime(_ sec: TimeInterval) {
        simulate(sec)
    }

    /// Every particle gone, and counting starts again.
    open func resetSimulation() {
        particles.removeAll()
        owed = 0
        emitted = 0
    }

    public override func tickActions(_ delta: TimeInterval) {
        super.tickActions(delta)
        guard !isEffectivelyPaused else { return }
        simulate(delta * TimeInterval(max(0, worldSpeed)))
    }

    private func simulate(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        // Equal steps, so a second is sixty frames, not sixty and a sliver.
        let steps = max(1, Int((seconds / SKEmitterNode.maximumStep - 1e-9).rounded(.up)))
        let dt = CGFloat(seconds / TimeInterval(steps))
        for _ in 0 ..< steps { step(by: dt) }
    }

    /// One step: the living age and move, then whoever is due is born.
    private func step(by dt: CGFloat) {
        for i in particles.indices {
            particles[i].advance(by: dt)
        }
        particles.removeAll { $0.age >= $0.lifetime }

        guard particleBirthRate > 0 else {
            owed = 0
            return
        }
        owed += particleBirthRate * dt
        guard owed >= 1 else { return }
        let space = birthSpace()
        while owed >= 1 {
            owed -= 1
            if numParticlesToEmit > 0, emitted >= numParticlesToEmit {
                owed = 0
                break
            }
            emitted += 1
            if let particle = makeParticle(in: space) { particles.append(particle) }
        }
    }

    /// Where the emitter stands in the particles' space, at this moment.
    private func birthSpace() -> CGAffineTransform {
        guard let targetNode, targetNode !== self else { return .identity }
        return worldTransform.concatenating(targetNode.worldTransform.inverted())
    }

    private func makeParticle(in space: CGAffineTransform) -> Particle? {
        let lifetime = spread(particleLifetime, particleLifetimeRange)
        guard lifetime > 0 else { return nil }
        let local = CGPoint(
            x: spread(particlePosition.x, particlePositionRange.dx),
            y: spread(particlePosition.y, particlePositionRange.dy)
        )
        // The emission angle is the emitter's; in a target's space it turns
        // with the emitter, though the emitter's scale stays its own.
        let angle = spread(emissionAngle, emissionAngleRange) + atan2(space.b, space.a)
        let speed = spread(particleSpeed, particleSpeedRange)
        var proxy: SKNode?
        var action: SKAction.State?
        if let particleAction {
            proxy = SKNode()
            action = particleAction.makeState()
        }
        return Particle(
            position: local.applying(space),
            velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
            acceleration: CGVector(dx: xAcceleration, dy: yAcceleration),
            age: 0,
            lifetime: lifetime,
            alpha: spread(particleAlpha, particleAlphaRange),
            alphaSpeed: particleAlphaSpeed,
            scale: spread(particleScale, particleScaleRange),
            scaleSpeed: particleScaleSpeed,
            rotation: spread(particleRotation, particleRotationRange),
            rotationSpeed: particleRotationSpeed,
            blend: spread(particleColorBlendFactor, particleColorBlendFactorRange),
            blendSpeed: particleColorBlendFactorSpeed,
            proxy: proxy,
            action: action
        )
    }

    private func spread(_ value: CGFloat, _ range: CGFloat) -> CGFloat {
        guard range != 0 else { return value }
        return value + (random.unit() - 0.5) * range
    }

    // MARK: Drawing

    /// The particles as sprite commands, for `DrawList`: `transform`, `alpha`
    /// and `z` are the emitter's own, accumulated.
    func particleCommands(
        transform: CGAffineTransform, alpha: CGFloat, z: CGFloat
    ) -> [(CGFloat, DrawList.Command)] {
        guard !particles.isEmpty else { return [] }
        let base = particleSize != .zero ? particleSize : (particleTexture?.size() ?? .zero)
        guard base.width > 0, base.height > 0 else { return [] }
        let space: CGAffineTransform
        if let targetNode, targetNode !== self {
            space = targetNode.worldTransform
                .concatenating(worldTransform.inverted())
                .concatenating(transform)
        } else {
            space = transform
        }
        let textureRect = particleTexture?.textureRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let depth = z + particleZPosition
        var commands: [(CGFloat, DrawList.Command)] = []
        commands.reserveCapacity(particles.count)
        for particle in particles {
            let life = particle.lifetime > 0 ? particle.age / particle.lifetime : 1
            let proxy = particle.proxy
            var shown = particleAlphaSequence?.sampleNumber(at: life) ?? particle.alpha
            shown = min(1, max(0, shown)) * (proxy?.alpha ?? 1) * alpha
            let scale = particleScaleSequence?.sampleNumber(at: life) ?? particle.scale
            let blend = particleColorBlendFactorSequence?.sampleNumber(at: life) ?? particle.blend
            let colour = particleColorSequence.flatMap { $0.sample(atTime: life) as? SKColor } ?? particleColor
            let width = base.width * scale * (proxy?.xScale ?? 1)
            let height = base.height * scale * (proxy?.yScale ?? 1)
            guard shown > 0, width > 0, height > 0 else { continue }
            let offset = proxy?.position ?? .zero
            let placed = CGAffineTransform(rotationAngle: particle.rotation + (proxy?.zRotation ?? 0))
                .concatenating(CGAffineTransform(
                    translationX: particle.position.x + offset.x,
                    y: particle.position.y + offset.y
                ))
                .concatenating(space)
            commands.append((depth, .sprite(DrawList.Sprite(
                transform: placed,
                size: CGSize(width: width, height: height),
                anchorPoint: CGPoint(x: 0.5, y: 0.5),
                texture: particleTexture,
                textureRect: textureRect,
                color: colour,
                colorBlendFactor: min(1, max(0, blend)),
                alpha: shown,
                blendMode: particleBlendMode,
                shader: shader,
                attributeValues: attributeValues
            ))))
        }
        return commands
    }
}

/// One particle, in its emitter's (or target's) space.
@MainActor
struct Particle {
    var position: CGPoint
    var velocity: CGVector
    let acceleration: CGVector
    var age: CGFloat
    let lifetime: CGFloat
    var alpha: CGFloat
    let alphaSpeed: CGFloat
    var scale: CGFloat
    let scaleSpeed: CGFloat
    var rotation: CGFloat
    let rotationSpeed: CGFloat
    var blend: CGFloat
    let blendSpeed: CGFloat
    /// What `particleAction` moves, kept apart from the particle's own
    /// motion: a `moveBy` measures from where it started, so run on the
    /// particle itself it would pull it back against its velocity.
    let proxy: SKNode?
    var action: SKAction.State?

    mutating func advance(by dt: CGFloat) {
        age += dt
        velocity.dx += acceleration.dx * dt
        velocity.dy += acceleration.dy * dt
        position.x += velocity.dx * dt
        position.y += velocity.dy * dt
        alpha += alphaSpeed * dt
        scale += scaleSpeed * dt
        rotation += rotationSpeed * dt
        blend += blendSpeed * dt
        if let proxy, action != nil, action?.advance(by: TimeInterval(dt), on: proxy) == true {
            action = nil
        }
    }
}

/// SplitMix64: small, fast and the same on every platform, which
/// `SystemRandomNumberGenerator` is not.
struct ParticleRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53)
    }
}

/// Hands each new emitter the next seed.
private final class SeedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count &* 0x2545_F491_4F6C_DD1D
    }
}

#endif
