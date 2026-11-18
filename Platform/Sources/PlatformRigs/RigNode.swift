import Foundation
import Macros
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
import UIKit
#endif

/// Plays a Spine rig (`RigData`, posed by `RigPose`) in SpriteKit: every mesh
/// draws as its own triangles (`RigMeshNode`), every region too as its quad
/// (or, with `regionsAsSprites`, as a sprite riding its bone), in slot
/// order, tinted by its slot's colour, and what a clipping attachment holds
/// draws inside a crop node masked by the clip's polygon. Its origin is the
/// skeleton's root, at `unit` points per skeleton unit. Physics trails as the
/// node moves through the scene.
///
/// While the rig stands still (paused, or nothing playing and nothing
/// swinging) it caches its parts as one texture: SpriteKit otherwise prepares
/// every mesh sprite's per-node attributes again each frame. A rig whose
/// look changes while still (a light that moves over it) passes `caching: false`.
///
/// Subclass it to add what a game draws on a rig (faces, riders): override
/// `didRender()`, which runs after every pose is drawn.
@NSCodingUnsupported
open class RigNode: SKNode {
    private enum ActionKey {
        static let tick = "rig.tick"
    }

    /// The tick's period, a frame callback (an action this long, again and again).
    public static var tickPeriod: CGFloat = 1
    /// The longest step a tick takes, so a stall doesn't fling the physics.
    public static var longestFrame: CGFloat = 0.1
    /// Below this size (points per point), moving through the scene trails
    /// nothing: a rig shrunk to a speck would move millions of its units.
    public static var leastTrailingScale: CGFloat = 0.05
    /// How many textures `texture(_:)` keeps.
    public static var textureCacheLimit = 12 {
        didSet { textures.countLimit = textureCacheLimit }
    }

    /// Textures read from files, kept while there's room.
    private static let textures: NSCache<NSString, SKTexture> = {
        let cache = NSCache<NSString, SKTexture>()
        cache.countLimit = textureCacheLimit
        return cache
    }()

    public let data: RigData
    public let pose: RigPose
    /// Points per skeleton unit.
    public let unit: CGFloat
    /// z between its slots.
    public let slotZ: CGFloat
    public let texture: SKTexture
    /// Whether trailing parts lag as the rig moves through the scene; off
    /// while something takes it somewhere it doesn't travel, so they don't fling.
    public var feelsMoves = true
    /// Whether it holds still while it or anything it stands in is hidden,
    /// picking up from where it was once shown again.
    public var holdsWhileHidden = true

    /// The listeners of `pose` (track, animation name).
    public var onStart: ((Int, String) -> Void)? {
        get { pose.onStart }
        set { pose.onStart = newValue }
    }

    public var onInterrupt: ((Int, String) -> Void)? {
        get { pose.onInterrupt }
        set { pose.onInterrupt = newValue }
    }

    public var onEnd: ((Int, String) -> Void)? {
        get { pose.onEnd }
        set { pose.onEnd = newValue }
    }

    public var onComplete: ((Int, String) -> Void)? {
        get { pose.onComplete }
        set { pose.onComplete = newValue }
    }

    /// Each slot's parts, by attachment index: `RigMeshNode`s, and sprites
    /// for regions drawn as sprites.
    public private(set) var parts: [[Int: SKNode]] = []
    /// The mesh parts, which wait for their shaders to be primed.
    public private(set) var meshes: [RigMeshNode] = []
    /// Holds every part, and whatever rides among them (`carry`).
    public let content: SKNode
    private let canvas: SKEffectNode?
    private let hiddenSlots: Set<Int>
    /// Each clipping attachment's crop node and mask, by slot.
    private var clips: [Int: (crop: SKCropNode, mask: SKShapeNode, attachment: Int)] = [:]
    private var points: [CGPoint] = []
    private var lastTick: CGFloat = 0
    /// Where the rig stood in the scene last frame.
    private var sceneAt: CGPoint?
    /// Nodes riding bones, each with its bone and that bone at rest.
    private var riders: [(node: SKNode, bone: Int, rest: RigPose.Transform)] = []

    override open var isPaused: Bool {
        didSet { updateCaching() }
    }

    /// The rig `name` (`RigData.named`) at `unit` points per skeleton unit;
    /// nil if it can't be read. `hiding` names slots that never show.
    public convenience init?(
        name: String, unit: CGFloat = 1, runtime: RigPose.Runtime = .spine42, hiding: Set<String> = [], slotZ: CGFloat = 0.0001,
        regionsAsSprites: Bool = false, caching: Bool = true, shading: RigMeshNode.Shading = .plain, mipmaps: Bool = true
    ) {
        guard let data = RigData.named(name), let texture = Self.texture(data.textureURL, mipmaps: mipmaps) else { return nil }
        self.init(
            data: data, texture: texture, unit: unit, runtime: runtime, hiding: hiding, slotZ: slotZ,
            regionsAsSprites: regionsAsSprites, caching: caching, shading: shading
        )
    }

    public init(
        data: RigData, texture: SKTexture, unit: CGFloat = 1, runtime: RigPose.Runtime = .spine42, hiding: Set<String> = [], slotZ: CGFloat = 0.0001,
        regionsAsSprites: Bool = false, caching: Bool = true, shading: RigMeshNode.Shading = .plain
    ) {
        self.data = data
        self.texture = texture
        self.unit = unit
        self.slotZ = slotZ
        pose = RigPose(data: data, runtime: runtime)
        hiddenSlots = Set(data.slots.indices.filter { hiding.contains(data.slots[$0].name) })
        if caching {
            let canvas = SKEffectNode()
            canvas.shouldEnableEffects = false
            self.canvas = canvas
            content = canvas
        } else {
            canvas = nil
            content = SKNode()
        }
        super.init()
        addChild(content)

        let size = texture.size()
        let tinted = data.tintsColor
        var holder: SKNode = content
        var clipEnd: Int?
        for index in data.slots.indices {
            var byIndex: [Int: SKNode] = [:]
            // Hidden slots get no parts.
            let attachments = hiddenSlots.contains(index) ? [] : data.skin[index].values.sorted()
            for attachmentIndex in attachments {
                let attachment = data.attachments[attachmentIndex]
                let part: SKNode
                switch attachment {
                case let .clipping(clip):
                    // What the slots after it draw, up to its end slot, draws inside it.
                    let crop = SKCropNode()
                    crop.zPosition = CGFloat(index) * slotZ
                    let mask = SKShapeNode()
                    mask.fillColor = .white
                    mask.strokeColor = .clear
                    mask.isAntialiased = false
                    crop.maskNode = mask
                    content.addChild(crop)
                    clips[index] = (crop, mask, attachmentIndex)
                    holder = crop
                    clipEnd = clip.end ?? data.slots.count - 1
                    continue
                case let .region(region) where regionsAsSprites:
                    guard let frame = region.frame else { continue }
                    part = SKSpriteNode(texture: Self.part(frame, of: texture), size: CGSize(width: region.width * unit, height: region.height * unit))
                case let .region(region):
                    guard region.frame != nil else { continue }
                    part = mesh(uvs: data.textureUVs(of: attachment, in: size), triangles: RigData.Region.triangles, tinted: tinted, shading: shading)
                case let .mesh(mesh):
                    guard mesh.frame != nil else { continue }
                    part = self.mesh(uvs: data.textureUVs(of: attachment, in: size), triangles: mesh.triangles, tinted: tinted, shading: shading)
                case .path:
                    continue
                }
                // Within a crop node, z counts from the crop node's own.
                part.zPosition = CGFloat(index) * slotZ - (holder === content ? 0 : holder.zPosition)
                part.isHidden = true
                holder.addChild(part)
                byIndex[attachmentIndex] = part
            }
            parts.append(byIndex)
            if let end = clipEnd, index >= end {
                holder = content
                clipEnd = nil
            }
        }
        pose.advance(0)
        render()
        startTicking()
    }

    private func mesh(uvs: [CGPoint], triangles: [Int], tinted: Bool, shading: RigMeshNode.Shading) -> RigMeshNode {
        let node = RigMeshNode(uvs: uvs, triangles: triangles, texture: texture, shading: shading, tinted: tinted, slotZ: slotZ)
        meshes.append(node)
        return node
    }

    // MARK: - Playing

    /// RigPose.setAnimation.
    @discardableResult
    public func setAnimation(_ track: Int, _ name: String, loop: Bool) -> RigPose.Entry? {
        pose.setAnimation(track, name, loop: loop)
    }

    /// RigPose.addAnimation.
    @discardableResult
    public func addAnimation(_ track: Int, _ name: String, loop: Bool, delay: CGFloat = 0) -> RigPose.Entry? {
        pose.addAnimation(track, name, loop: loop, delay: delay)
    }

    /// RigPose.play, with `rise` (when given) how high its `riseBone` lifts
    /// the rig at the animation's highest, in points (0 keeps it down).
    @discardableResult
    public func play(
        _ name: String, loop: Bool, rate: CGFloat = 1, from start: CGFloat = 0, until stop: CGFloat = 0,
        then next: String? = nil, rise: CGFloat? = nil, mix: CGFloat? = nil, track: Int = 0
    ) -> RigPose.Entry? {
        var scale: CGFloat = 1
        if let rise, let bone = pose.riseBone {
            let peak = data.peakLift(of: bone, in: name)
            if peak > 0 { scale = rise / (peak * unit) }
        }
        return pose.play(name, loop: loop, rate: rate, from: start, until: stop, then: next, rise: scale, mix: mix, track: track)
    }

    /// How long `name` plays at its own pace, in seconds.
    public func duration(of name: String) -> TimeInterval {
        TimeInterval(data.animations[name]?.duration ?? 0)
    }

    /// The bone `name`'s world transform, in the node's space.
    public func bone(named name: String) -> RigPose.Transform? {
        pose.boneTransform(named: name).map(scaled)
    }

    /// The bone's world transform, in the node's space.
    public func transform(of bone: Int) -> RigPose.Transform {
        scaled(pose.boneTransform(bone))
    }

    private func scaled(_ t: RigPose.Transform) -> RigPose.Transform {
        var t = t
        t.x *= unit
        t.y *= unit
        return t
    }

    /// Carries `node`, placed in the rig's space as it stands at rest, on the
    /// bone `name`: it moves, turns and scales as the bone does from its rest,
    /// over the slots on that bone, or at `depth` (in slots: a slot's own
    /// depth is the base of all it draws).
    public func carry(_ node: SKNode, on name: String, depth: CGFloat? = nil) {
        guard let bone = data.bone(named: name) else {
            content.addChild(node)
            return
        }
        let rest = RigPose(data: data, runtime: pose.runtime)
        rest.advance(0)
        let t = rest.boneTransform(bone)
        let carrier = SKNode()
        carrier.zPosition = depth.map { $0 * slotZ } ?? CGFloat(data.slots.lastIndex { $0.bone == bone } ?? data.slots.count) * slotZ + slotZ / 2
        node.position = CGPoint(x: node.position.x - t.x * unit, y: node.position.y - t.y * unit)
        carrier.addChild(node)
        content.addChild(carrier)
        riders.append((carrier, bone, t))
        render()
    }

    /// Puts `node` where the bone transform `t` is, turned and scaled as far
    /// as it is from `rest` (both in the rig's units).
    public func place(_ node: SKNode, at t: RigPose.Transform, from rest: RigPose.Transform) {
        let restX = hypot(rest.a, rest.c), restY = hypot(rest.b, rest.d)
        node.position = CGPoint(x: t.x * unit, y: t.y * unit)
        node.zRotation = atan2(t.c, t.a) - atan2(rest.c, rest.a)
        node.xScale = restX > 0 ? hypot(t.a, t.c) / restX : 1
        node.yScale = restY > 0 ? hypot(t.b, t.d) / restY : 1
    }

    /// Starts it again after `isPaused`, on a fresh tick: a resumed action
    /// times itself by real time, which an off-screen renderer's clock
    /// needn't follow, and would stand still.
    public func resume() {
        startTicking()
        isPaused = false
    }

    // MARK: - Ticking

    /// A frame callback: an action `tickPeriod` long, again and again.
    private func startTicking() {
        removeAction(forKey: ActionKey.tick)
        lastTick = 0
        run(.repeatForever(.customAction(withDuration: TimeInterval(Self.tickPeriod)) { node, elapsed in
            (node as? RigNode)?.tick(at: elapsed)
        }), withKey: ActionKey.tick)
    }

    private func tick(at elapsed: CGFloat) {
        // Its meshes show once their shaders are primed, before this frame draws them.
        if let view = scene?.view, meshes.contains(where: \.needsPriming) {
            for mesh in meshes { mesh.prepare(in: view) }
        }
        var delta = elapsed - lastTick
        if delta < 0 { delta += Self.tickPeriod }
        lastTick = elapsed
        delta = delta.isFinite ? min(max(delta, 0), Self.longestFrame) : 0
        // Actions run on hidden nodes too: a rig nothing shows holds still.
        if holdsWhileHidden, !isShown {
            sceneAt = nil
            return
        }
        // How far the rig moved through the scene, in its units at its size
        // now, so trailing parts lag as it moves (not as it shrinks or grows in place).
        if let scene {
            let at = convert(CGPoint.zero, to: scene), across = convert(CGPoint(x: 1, y: 0), to: scene)
            let size = hypot(across.x - at.x, across.y - at.y)
            let scale = size * unit
            if let sceneAt, feelsMoves, size >= Self.leastTrailingScale {
                pose.origin = CGPoint(x: pose.origin.x + (at.x - sceneAt.x) / scale, y: pose.origin.y + (at.y - sceneAt.y) / scale)
            }
            sceneAt = at
        }
        pose.advance(delta)
        render()
        updateCaching()
    }

    /// Whether neither it nor anything it stands in is hidden.
    private var isShown: Bool {
        var node: SKNode? = self
        while let current = node {
            if current.isHidden { return false }
            node = current.parent
        }
        return true
    }

    /// Caches the parts while nothing moves them; draws them live otherwise.
    /// Never while a mesh waits for its shader, which the cache would leave out.
    public func updateCaching() {
        guard let canvas else { return }
        let still = (isPaused || (!pose.isAnimating && pose.isSettled)) && !meshes.contains(where: \.needsPriming)
        guard canvas.shouldRasterize != still else { return }
        canvas.shouldRasterize = still
        canvas.shouldEnableEffects = still
    }

    // MARK: - Drawing

    /// Draws the pose: every part where its slot shows it, tinted.
    public func render() {
        for (index, byIndex) in parts.enumerated() {
            let showing = hiddenSlots.contains(index) ? nil : pose.attachmentIndex(slot: index)
            if let clip = clips[index] {
                let shown = showing == clip.attachment && pose.worldVertices(slot: index, into: &points)
                let path = CGMutablePath()
                if shown, points.count >= 3 {
                    path.addLines(between: points.map { CGPoint(x: $0.x * unit, y: $0.y * unit) })
                    path.closeSubpath()
                }
                clip.mask.path = path
            }
            guard !byIndex.isEmpty else { continue }
            let color = pose.color(slot: index)
            for (attachment, part) in byIndex {
                guard attachment == showing else {
                    part.isHidden = true
                    continue
                }
                part.isHidden = color.a <= 0
                if let mesh = part as? RigMeshNode {
                    guard pose.worldVertices(slot: index, into: &points) else {
                        part.isHidden = true
                        continue
                    }
                    mesh.setColor(color.r, color.g, color.b, color.a)
                    mesh.update(points, unit: unit)
                } else if let sprite = part as? SKSpriteNode, case let .region(region) = data.attachments[attachment] {
                    let t = pose.boneTransform(data.slots[index].bone)
                    sprite.position = CGPoint(x: (t.a * region.x + t.b * region.y + t.x) * unit, y: (t.c * region.x + t.d * region.y + t.y) * unit)
                    sprite.zRotation = atan2(t.c, t.a) + region.rotation * .pi / 180
                    sprite.xScale = hypot(t.a, t.c) * region.scaleX
                    sprite.yScale = hypot(t.b, t.d) * region.scaleY
                    sprite.alpha = color.a
                }
            }
        }
        for rider in riders { place(rider.node, at: pose.boneTransform(rider.bone), from: rider.rest) }
        didRender()
    }

    /// Runs after every pose is drawn, for what a subclass draws on the rig.
    open func didRender() {}

    // MARK: - Textures

    /// The texture at `url`, read once and kept while there's room.
    public static func texture(_ url: URL, mipmaps: Bool = true) -> SKTexture? {
        let key = "\(url.path)\(mipmaps ? "" : " flat")" as NSString
        if let texture = textures.object(forKey: key) { return texture }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        texture.usesMipmaps = mipmaps
        textures.setObject(texture, forKey: key)
        return texture
    }

    /// The part of `texture` at `frame` (in pixels, y down).
    public static func part(_ frame: CGRect, of texture: SKTexture) -> SKTexture {
        let size = texture.size()
        guard size.width > 0, size.height > 0 else { return texture }
        return SKTexture(
            rect: CGRect(x: frame.minX / size.width, y: 1 - frame.maxY / size.height, width: frame.width / size.width, height: frame.height / size.height),
            in: texture
        )
    }
}
