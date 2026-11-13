import Foundation
import SpriteKitShim

/// `debug.switchlings.scene particles`: the reef's particles on their own, to show
/// `SKEmitterNode` working on a device before the seabed backdrop exists.
///
/// Every emitter here is set up exactly as `SeabedNode` sets up its own,
/// with the game's own `DesignSystem` values and textures: marine snow and
/// motes across the screen (`layMotes`), bubbling vents puffing on and off
/// (`placeVents`, with `particleAction`'s wobble) and a burst wherever a tap
/// lands (`burst`). Copied, not shared, because `SeabedNode` needs the whole
/// backdrop stage; nothing in `Source/` changes.
public final class EmitterPreviewScene: SKScene {
    private enum ActionKey {
        static let puff = "puff"
    }

    private let motesNode = SKNode()
    /// The water's colour as a sprite: the renderer clears to black, not to
    /// `backgroundColor`.
    private let water = SKSpriteNode(color: .black, size: .zero)
    /// What the view shows of the scene, which is wider than any phone.
    private var visible: CGRect = .zero
    private var look: SeabedLook? { WorldTheme.reef.palette.seabed }

    /// `AmbientParticlesNode.bubble`, drawn the same way.
    private static let bubble: SKTexture = SurfaceTexture.texture(
        size: sz(DesignSystem.ambientBubbleTextureSize),
        scale: DesignSystem.ambientBubbleTextureScale,
        key: "ambient-bubble"
    ) { context, bounds in
        let rim = DesignSystem.ambientBubbleRim
        let ring = bounds.insetBy(dx: rim, dy: rim)
        context.setFillColor(Theme.ambientBubble.withOpacity(DesignSystem.ambientBubbleFilm).cgColor)
        context.fillEllipse(in: ring)
        context.setStrokeColor(Theme.ambientBubble.withOpacity(DesignSystem.ambientBubbleRimAlpha).cgColor)
        context.setLineWidth(rim)
        context.strokeEllipse(in: ring)
        let shine = bounds.width * DesignSystem.ambientBubbleShine
        context.setFillColor(Theme.ambientBubble.cgColor)
        context.fillEllipse(in: rect(bounds.minX + bounds.width * 0.24, bounds.minY + bounds.height * 0.2, shine, shine * 0.75))
        context.setFillColor(Theme.ambientBubble.withOpacity(DesignSystem.ambientBubbleRimAlpha).cgColor)
        context.fillEllipse(in: rect(bounds.maxX - bounds.width * 0.32, bounds.maxY - bounds.height * 0.3, shine * 0.45, shine * 0.45))
    }

    public override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .aspectFill
    }

    public override func didMove(to view: SKView) {
        backgroundColor = look?.deep ?? WorldTheme.reef.palette.backgroundBottom
        water.color = backgroundColor
        water.zPosition = -1
        addChild(water)
        motesNode.zPosition = DesignSystem.seabedMotesZ
        addChild(motesNode)
        build()
    }

    public override func didChangeSize(_ oldSize: CGSize) {
        guard motesNode.parent != nil else { return }
        build()
    }

    private func build() {
        // Aspect fill: the scene's middle, as tall or as wide as the view.
        let screen = view?.bounds.size ?? size
        let scale = max(screen.width / size.width, screen.height / size.height)
        let shown = sz(screen.width / scale, screen.height / scale)
        visible = rect((size.width - shown.width) / 2, (size.height - shown.height) / 2, shown.width, shown.height)
        water.size = size
        water.position = pt(size.width / 2, size.height / 2)
        motesNode.removeAllChildren()
        layMotes()
        placeVents()
    }

    /// The vents: staggered across the lower part of the screen.
    private var vents: [CGPoint] {
        (1 ... 4).map {
            pt(visible.minX + visible.width * CGFloat($0) / 5,
               visible.minY + visible.height * ($0.isMultiple(of: 2) ? 0.12 : 0.24))
        }
    }

    private func layMotes() {
        let region = visible.insetBy(dx: -DesignSystem.seabedSnowMargin, dy: -DesignSystem.seabedSnowMargin)
        let areaUnits = region.width * region.height / DesignSystem.ambientAreaUnit
        let density: CGFloat = 1
        for (texture, scale, alpha, speed, rate) in [
            (SurfaceTexture.dot, DesignSystem.seabedSnowScale, DesignSystem.seabedSnowAlpha, DesignSystem.seabedSnowSpeed, DesignSystem.seabedSnowRate),
            (SurfaceTexture.glow(.white), DesignSystem.seabedMoteScale, DesignSystem.seabedMoteAlpha, DesignSystem.seabedMoteSpeed, DesignSystem.seabedMoteRate),
        ] {
            let emitter = SKEmitterNode()
            emitter.particleTexture = texture
            emitter.particleColor = look?.snow ?? .white
            emitter.particleColorBlendFactor = 1
            emitter.particleBlendMode = .alpha
            emitter.particlePositionRange = CGVector(dx: region.width, dy: region.height)
            emitter.position = region.center
            emitter.particleScale = scale
            emitter.particleScaleRange = scale * 0.6
            emitter.particleSpeed = speed
            emitter.particleSpeedRange = speed
            emitter.emissionAngle = DesignSystem.seabedSnowHeading
            emitter.emissionAngleRange = DesignSystem.seabedSnowSpread
            emitter.particleLifetime = DesignSystem.seabedSnowLifetime
            emitter.particleLifetimeRange = DesignSystem.seabedSnowLifetime / 2
            emitter.particleAlphaSequence = SKKeyframeSequence(keyframeValues: [0, alpha, alpha, 0], times: [0, 0.2, 0.8, 1])
            emitter.particleBirthRate = areaUnits * rate * density / emitter.particleLifetime
            emitter.advanceSimulationTime(TimeInterval(emitter.particleLifetime))
            motesNode.addChild(emitter)
        }
    }

    private func placeVents() {
        let rise = DesignSystem.seabedBubbleRise
        let rate = DesignSystem.seabedBubbleRate
        for vent in vents {
            let emitter = SKEmitterNode()
            emitter.name = "vent"
            emitter.particleTexture = Self.bubble
            emitter.particleColorBlendFactor = 0
            emitter.position = vent
            emitter.particlePositionRange = CGVector(dx: DesignSystem.seabedBubbleSpread, dy: 0)
            emitter.emissionAngle = .pi / 2
            emitter.emissionAngleRange = DesignSystem.seabedBubbleFan
            emitter.particleSpeed = DesignSystem.seabedBubbleSpeed
            emitter.particleSpeedRange = DesignSystem.seabedBubbleSpeed / 2
            emitter.particleLifetime = rise / DesignSystem.seabedBubbleSpeed
            emitter.particleLifetimeRange = emitter.particleLifetime / 3
            emitter.particleScale = DesignSystem.seabedBubbleScale
            emitter.particleScaleRange = DesignSystem.seabedBubbleScale / 2
            emitter.particleScaleSpeed = DesignSystem.seabedBubbleGrowth
            emitter.particleAlphaSequence = SKKeyframeSequence(keyframeValues: [0, 1, 1, 0], times: [0, 0.1, 0.75, 1])
            let sway = DesignSystem.seabedBubbleWobble
            let wobble = SKAction.sequence([.moveBy(x: sway, y: 0, duration: 0.35), .moveBy(x: -sway, y: 0, duration: 0.35)])
            wobble.timingMode = .easeInEaseOut
            emitter.particleAction = .repeatForever(wobble)
            emitter.particleBirthRate = 0
            emitter.run(.repeatForever(.sequence([
                .wait(forDuration: DesignSystem.seabedPuffRest, withRange: DesignSystem.seabedPuffRest),
                .run { [weak emitter] in emitter?.particleBirthRate = rate },
                .wait(forDuration: DesignSystem.seabedPuffLength, withRange: DesignSystem.seabedPuffLength),
                .run { [weak emitter] in emitter?.particleBirthRate = 0 },
            ])), withKey: ActionKey.puff)
            motesNode.addChild(emitter)
        }
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        burst(at: touch.location(in: self), bubbles: DesignSystem.touchBubbles)
    }

    private func burst(at point: CGPoint, bubbles: Int) {
        let rise = DesignSystem.seabedBubbleRise
        let emitter = SKEmitterNode()
        emitter.particleTexture = Self.bubble
        emitter.particleColorBlendFactor = 0
        emitter.position = point
        emitter.particlePositionRange = CGVector(dx: DesignSystem.seabedBubbleSpread * 1.5, dy: 0)
        emitter.emissionAngle = .pi / 2
        emitter.emissionAngleRange = DesignSystem.seabedBubbleFan * 1.5
        emitter.particleSpeed = DesignSystem.seabedBubbleSpeed * 1.4
        emitter.particleSpeedRange = DesignSystem.seabedBubbleSpeed / 2
        emitter.particleLifetime = rise / DesignSystem.seabedBubbleSpeed
        emitter.particleLifetimeRange = emitter.particleLifetime / 3
        emitter.particleScale = DesignSystem.seabedBubbleScale
        emitter.particleScaleRange = DesignSystem.seabedBubbleScale / 2
        emitter.particleScaleSpeed = DesignSystem.seabedBubbleGrowth
        emitter.particleAlphaSequence = SKKeyframeSequence(keyframeValues: [0, 1, 1, 0], times: [0, 0.1, 0.75, 1])
        emitter.particleBirthRate = CGFloat(bubbles) / DesignSystem.touchBubbleTime
        emitter.numParticlesToEmit = bubbles
        motesNode.addChild(emitter)
        emitter.run(.sequence([.wait(forDuration: TimeInterval(emitter.particleLifetime * 1.4) + DesignSystem.touchBubbleTime), .removeFromParent()]))
    }
}
