#if SPRITEKIT_SHIM
import Foundation

/// SpriteKit's custom timing curve: progress through an action, 0 to 1, in;
/// the progress to show, out.
public typealias SKActionTimingFunction = (Float) -> Float

public enum SKActionTimingMode: Int, Sendable {
    case linear, easeIn, easeOut, easeInEaseOut

    /// SpriteKit's curves, measured off its own renderer (`SKRenderer` on
    /// the Mac, a `moveBy` read back at tenths of its duration): cubics, not
    /// the quadratics they are often taken for — ease in `2t² − t³`, ease
    /// out its mirror `t + t² − t³`, both `3t² − 2t³` (smoothstep).
    func apply(_ t: CGFloat) -> CGFloat {
        switch self {
        case .linear: return t
        case .easeIn: return t * t * (2 - t)
        case .easeOut: return t * (1 + t - t * t)
        case .easeInEaseOut: return t * t * (3 - 2 * t)
        }
    }
}

/// A SpriteKit action.
///
/// The game builds everything it animates out of four of these — customAction,
/// run, sequence and repeatForever (see `SKAction+` in EasingFunctions.swift) —
/// so those are exact; the rest cover the remaining call sites.
public final class SKAction {
    indirect enum Kind {
        case wait
        case run(() -> Void)
        case custom((SKNode, CGFloat) -> Void)
        case moveTo(CGPoint?, CGFloat?, CGFloat?)   // point, x only, y only
        case moveBy(CGVector)
        case fadeTo(CGFloat)
        case fadeBy(CGFloat)
        case scaleTo(CGFloat?, CGFloat?, CGFloat?)  // uniform, x only, y only
        case scaleBy(CGFloat)
        case rotateTo(CGFloat)
        case rotateToShortest(CGFloat)              // the shortest way round
        case follow([CGPoint], Bool, Bool)          // flattened path, as offset, orient
        case rotateBy(CGFloat)
        case animate([SKTexture], TimeInterval, Bool)
        case sequence([SKAction])
        case group([SKAction])
        case repeating(SKAction, Int?)              // nil count == forever
        case removeFromParent
        case hide(Bool)
        case setTexture(SKTexture, resize: Bool)
        case warpTo(SKWarpGeometry)                 // SKWarpGeometry.swift
        case warps([SKWarpGeometry], [TimeInterval], Bool)
    }

    let kind: Kind
    public var duration: TimeInterval
    public var timingMode: SKActionTimingMode = .linear
    /// SpriteKit's `timingFunction`, nil until set (calling SpriteKit's
    /// unset one crashes, as forcing this would). Measured with `SKRenderer`
    /// on a Mac (`ActionTimingFunctionTests`): it runs on what the timing
    /// mode gives, `f(mode(t))`, whichever was set first; what it returns
    /// is clamped to 0...1, so an overshooting curve holds at the end
    /// rather than passing it; the action is done once that reaches 1 (a
    /// back ease ends early, a curve that never gets there runs on at its
    /// last value); a custom action's block is handed the curved time;
    /// a sequence or group runs its children on curved time; a repeat
    /// ignores it.
    public var timingFunction: SKActionTimingFunction!
    public var speed: CGFloat = 1

    init(kind: Kind, duration: TimeInterval) {
        self.kind = kind
        self.duration = duration
    }

    /// `NSCopying`'s copy, as games write it (`fade.copy() as! SKAction`) to
    /// run one action on several nodes and change each copy apart: the same
    /// action, with its own duration, timing mode and speed.
    public func copy() -> Any {
        let copy = SKAction(kind: kind, duration: duration)
        copy.timingMode = timingMode
        copy.speed = speed
        return copy
    }

    // MARK: The four the game builds on

    public static func customAction(
        withDuration duration: TimeInterval,
        actionBlock: @escaping (SKNode, CGFloat) -> Void
    ) -> SKAction {
        SKAction(kind: .custom(actionBlock), duration: duration)
    }

    public static func run(_ block: @escaping () -> Void) -> SKAction {
        SKAction(kind: .run(block), duration: 0)
    }

    public static func sequence(_ actions: [SKAction]) -> SKAction {
        SKAction(kind: .sequence(actions), duration: actions.reduce(0) { $0 + $1.totalDuration })
    }

    public static func repeatForever(_ action: SKAction) -> SKAction {
        SKAction(kind: .repeating(action, nil), duration: .infinity)
    }

    // MARK: The rest

    public static func group(_ actions: [SKAction]) -> SKAction {
        SKAction(kind: .group(actions), duration: actions.map(\.totalDuration).max() ?? 0)
    }

    public static func `repeat`(_ action: SKAction, count: Int) -> SKAction {
        SKAction(kind: .repeating(action, count), duration: action.totalDuration * Double(count))
    }

    public static func wait(forDuration duration: TimeInterval) -> SKAction {
        SKAction(kind: .wait, duration: duration)
    }

    public static func wait(forDuration duration: TimeInterval, withRange range: TimeInterval) -> SKAction {
        let jitter = TimeInterval.random(in: -range / 2 ... range / 2)
        return SKAction(kind: .wait, duration: max(0, duration + jitter))
    }

    public static func move(to point: CGPoint, duration: TimeInterval) -> SKAction {
        SKAction(kind: .moveTo(point, nil, nil), duration: duration)
    }

    public static func move(by delta: CGVector, duration: TimeInterval) -> SKAction {
        SKAction(kind: .moveBy(delta), duration: duration)
    }

    public static func moveBy(x: CGFloat, y: CGFloat, duration: TimeInterval) -> SKAction {
        SKAction(kind: .moveBy(CGVector(dx: x, dy: y)), duration: duration)
    }

    public static func moveTo(x: CGFloat, duration: TimeInterval) -> SKAction {
        SKAction(kind: .moveTo(nil, x, nil), duration: duration)
    }

    public static func moveTo(y: CGFloat, duration: TimeInterval) -> SKAction {
        SKAction(kind: .moveTo(nil, nil, y), duration: duration)
    }

    public static func fadeAlpha(to alpha: CGFloat, duration: TimeInterval) -> SKAction {
        SKAction(kind: .fadeTo(alpha), duration: duration)
    }

    public static func fadeAlpha(by delta: CGFloat, duration: TimeInterval) -> SKAction {
        SKAction(kind: .fadeBy(delta), duration: duration)
    }

    public static func fadeIn(withDuration duration: TimeInterval) -> SKAction {
        SKAction(kind: .fadeTo(1), duration: duration)
    }

    public static func fadeOut(withDuration duration: TimeInterval) -> SKAction {
        SKAction(kind: .fadeTo(0), duration: duration)
    }

    public static func scale(to scale: CGFloat, duration: TimeInterval) -> SKAction {
        SKAction(kind: .scaleTo(scale, nil, nil), duration: duration)
    }

    public static func scale(by factor: CGFloat, duration: TimeInterval) -> SKAction {
        SKAction(kind: .scaleBy(factor), duration: duration)
    }

    public static func scaleX(to x: CGFloat, duration: TimeInterval) -> SKAction {
        SKAction(kind: .scaleTo(nil, x, nil), duration: duration)
    }

    public static func scaleY(to y: CGFloat, duration: TimeInterval) -> SKAction {
        SKAction(kind: .scaleTo(nil, nil, y), duration: duration)
    }

    public static func rotate(toAngle angle: CGFloat, duration: TimeInterval) -> SKAction {
        SKAction(kind: .rotateTo(angle), duration: duration)
    }

    /// SpriteKit's `follow(_:asOffset:orientToPath:duration:)`: along the
    /// path at an even speed, from its start (or from where the node
    /// stands, `asOffset`), turned along it with `orientToPath` (SpriteKit
    /// turns the node's x axis along the path).
    public static func follow(_ path: CGPath, asOffset: Bool, orientToPath: Bool, duration: TimeInterval) -> SKAction {
        let points = PathRasteriser.flatten(path, scale: 1).flatMap(\.points)
        return SKAction(kind: .follow(points, asOffset, orientToPath), duration: duration)
    }

    /// With `shortestUnitArc`, it turns whichever way round is shorter.
    public static func rotate(toAngle angle: CGFloat, duration: TimeInterval, shortestUnitArc: Bool) -> SKAction {
        SKAction(kind: shortestUnitArc ? .rotateToShortest(angle) : .rotateTo(angle), duration: duration)
    }

    /// SpriteKit's `colorize(with:colorBlendFactor:duration:)`: a sprite's
    /// colour and blend factor, from where they stand when it starts.
    public static func colorize(with color: SKColor, colorBlendFactor: CGFloat, duration: TimeInterval) -> SKAction {
        final class Start { var color: SKColor?; var factor: CGFloat = 0 }
        let start = Start()
        return customAction(withDuration: duration) { node, elapsed in
            guard let sprite = node as? SKSpriteNode else { return }
            if start.color == nil {
                start.color = sprite.color
                start.factor = sprite.colorBlendFactor
            }
            guard let from = start.color else { return }
            let t = duration > 0 ? min(max(elapsed / CGFloat(duration), 0), 1) : 1
            sprite.color = SKColor(
                red: from.red + (color.red - from.red) * t,
                green: from.green + (color.green - from.green) * t,
                blue: from.blue + (color.blue - from.blue) * t,
                alpha: from.alpha + (color.alpha - from.alpha) * t
            )
            sprite.colorBlendFactor = start.factor + (colorBlendFactor - start.factor) * t
        }
    }

    public static func rotate(byAngle angle: CGFloat, duration: TimeInterval) -> SKAction {
        SKAction(kind: .rotateBy(angle), duration: duration)
    }

    public static func animate(
        with textures: [SKTexture],
        timePerFrame: TimeInterval,
        resize: Bool = false,
        restore: Bool = false
    ) -> SKAction {
        SKAction(
            kind: .animate(textures, timePerFrame, restore),
            duration: timePerFrame * Double(textures.count)
        )
    }

    public static func removeFromParent() -> SKAction {
        SKAction(kind: .removeFromParent, duration: 0)
    }

    public static func hide() -> SKAction { SKAction(kind: .hide(true), duration: 0) }
    /// A sprite's texture, at once; `resize` takes the texture's size too.
    public static func setTexture(_ texture: SKTexture) -> SKAction { SKAction(kind: .setTexture(texture, resize: false), duration: 0) }
    public static func setTexture(_ texture: SKTexture, resize: Bool) -> SKAction { SKAction(kind: .setTexture(texture, resize: resize), duration: 0) }
    public static func unhide() -> SKAction { SKAction(kind: .hide(false), duration: 0) }

    /// SpriteKit's reverse: relative actions undo themselves, sequences run
    /// backwards, and actions with nothing to reverse (an absolute move, a
    /// block) come back as they are, as SpriteKit's do. The timing mode and
    /// function are kept as they are, not mirrored: a reversed ease-in still
    /// eases in (measured with `SKRenderer` on a Mac, macOS 27).
    public func reversed() -> SKAction {
        let kind: Kind
        switch self.kind {
        case let .moveBy(delta): kind = .moveBy(CGVector(dx: -delta.dx, dy: -delta.dy))
        case let .fadeBy(delta): kind = .fadeBy(-delta)
        case let .scaleBy(factor): kind = .scaleBy(factor == 0 ? 0 : 1 / factor)
        case let .rotateBy(angle): kind = .rotateBy(-angle)
        case let .sequence(actions): kind = .sequence(actions.reversed().map { $0.reversed() })
        case let .group(actions): kind = .group(actions.map { $0.reversed() })
        case let .repeating(action, count): kind = .repeating(action.reversed(), count)
        default: kind = self.kind
        }
        let reversed = SKAction(kind: kind, duration: duration)
        reversed.speed = speed
        reversed.timingMode = timingMode
        reversed.timingFunction = timingFunction
        return reversed
    }

    /// Whether the action's time runs on a curve rather than straight.
    var curvesTime: Bool { timingMode != .linear || timingFunction != nil }

    /// What `t` of the way through shows: the mode's curve, then the
    /// function's, clamped to 0...1 as SpriteKit clamps it.
    func curved(_ t: CGFloat) -> CGFloat {
        let moded = timingMode.apply(t)
        guard let timingFunction else { return moded }
        return CGFloat(min(max(timingFunction(Float(moded)), 0), 1))
    }

    var totalDuration: TimeInterval {
        speed > 0 ? duration / TimeInterval(speed) : duration
    }

    // MARK: Playback

    @MainActor func makeState() -> State { State(action: self) }

    /// One running instance. Actions are shared and re-runnable, so all
    /// mutable playback state lives here rather than on the action.
    @MainActor
    struct State {
        let action: SKAction
        private var elapsed: TimeInterval = 0
        /// A sequence's or group's own time on its curve: what its children
        /// have been handed so far.
        private var curvedElapsed: TimeInterval = 0
        private var started = false
        private var from: Snapshot?
        private var children: [State] = []
        private var index = 0
        private var repeated = 0
        /// A group's children that have finished, which it no longer runs.
        private var finishedChildren: Set<Int> = []

        /// What a relative action (moveBy, fadeBy, scaleBy) measures from.
        struct Snapshot {
            var position: CGPoint
            var alpha: CGFloat
            var xScale: CGFloat
            var yScale: CGFloat
            var zRotation: CGFloat
            var warp: SKWarpGeometry?
        }

        init(action: SKAction) {
            self.action = action
            switch action.kind {
            case let .sequence(actions), let .group(actions):
                children = actions.map { $0.makeState() }
            case let .repeating(inner, _):
                children = [inner.makeState()]
            default:
                break
            }
        }

        /// Advances by `delta` seconds. Returns true once finished.
        mutating func advance(by delta: TimeInterval, on node: SKNode) -> Bool {
            step(by: delta, on: node) != nil
        }

        /// Advances by `delta` seconds. Once it finishes, returns how much of
        /// `delta` it didn't need, which a sequence hands its next step and a
        /// repeat its next round, as SpriteKit does (measured with
        /// `SKRenderer` on the Mac): a 0.15 s frame through two 0.1 s moves
        /// ends half way through the second, a group hands on what its
        /// longest child left, and a `repeatForever` runs on across each
        /// wrap. A step finishes as its time is reached exactly, but what
        /// follows it starts only on time left over, so a `.run` after a step
        /// that ends right on a frame runs on the next one. Nil until then.
        mutating func step(by delta: TimeInterval, on node: SKNode) -> TimeInterval? {
            if !started {
                started = true
                from = Snapshot(
                    position: node.position,
                    alpha: node.alpha,
                    xScale: node.xScale,
                    yScale: node.yScale,
                    zRotation: node.zRotation,
                    warp: (node as? SKWarpable)?.warpGeometry
                )
            }

            var delta = delta
            switch action.kind {
            case .sequence, .group:
                if action.curvesTime { delta = curvedDelta(delta) }
            default:
                break
            }

            switch action.kind {
            case .sequence:
                var remaining = delta
                while index < children.count {
                    guard let left = children[index].step(by: remaining, on: node) else { return nil }
                    remaining = left
                    index += 1
                    if remaining <= 0 && index < children.count { return nil }
                }
                return remaining

            case .group:
                // What the child that finishes last leaves: each child that
                // finishes now reports its own, and the least is the group's.
                var allDone = true
                var left = delta
                for i in children.indices where !finishedChildren.contains(i) {
                    if let childLeft = children[i].step(by: delta, on: node) {
                        finishedChildren.insert(i)
                        left = min(left, childLeft)
                    } else {
                        allDone = false
                    }
                }
                return allDone ? left : nil

            case let .repeating(inner, count):
                var remaining = delta
                var rounds = 0
                while let left = children[0].step(by: remaining, on: node) {
                    repeated += 1
                    if let count, repeated >= count { return left }
                    children[0] = inner.makeState()
                    rounds += 1
                    // An instant round, or one that ends right on the frame,
                    // runs again on the next frame (SpriteKit spins forever
                    // on a `repeatForever` of an instant action; this doesn't).
                    guard left > 0, inner.totalDuration > 0, rounds < 64 else { return nil }
                    remaining = left
                }
                return nil

            case let .run(block):
                block()
                return delta

            case .removeFromParent:
                node.removeFromParent()
                return delta

            case let .hide(hidden):
                node.isHidden = hidden
                return delta

            case let .setTexture(texture, resize):
                if let sprite = node as? SKSpriteNode {
                    sprite.texture = texture
                    if resize { sprite.size = texture.size() }
                }
                return delta

            default:
                let speed = TimeInterval(max(0, action.speed))
                elapsed += delta * speed
                let total = action.duration
                let raw = total > 0 ? CGFloat(min(1, elapsed / total)) : 1
                let progress = action.curved(raw)
                // A custom block is handed seconds: straight, as they ran;
                // curved, the curve's share of the duration.
                let shown = action.curvesTime ? TimeInterval(progress) * total : elapsed
                apply(progress: progress, elapsed: shown, on: node)
                guard total <= 0 || progress >= 1 else { return nil }
                // Back in the parent's time: what this action's own speed
                // ran past its end (none, if a curve got there early).
                return total <= 0 ? delta : speed > 0 ? max(0, elapsed - total) / speed : 0
            }
        }

        /// A curved sequence's or group's frame: the children are handed the
        /// step along the curve, and, once its time is up, what the frame
        /// ran past the end, so they finish and hand that on.
        private mutating func curvedDelta(_ delta: TimeInterval) -> TimeInterval {
            let total = action.duration
            let before = elapsed
            elapsed += delta
            guard total > 0, total.isFinite else { return delta }
            let target = TimeInterval(action.curved(CGFloat(min(1, elapsed / total)))) * total
            let along = max(0, target - curvedElapsed)
            curvedElapsed = max(curvedElapsed, target)
            let past = max(0, elapsed - max(total, before))
            return along + past
        }

        private func apply(progress t: CGFloat, elapsed: TimeInterval, on node: SKNode) {
            guard let from else { return }
            switch action.kind {
            case .wait:
                break

            case let .custom(block):
                // SpriteKit hands the block seconds, not progress: on the
                // timing mode's and function's curve, if it has one.
                block(node, CGFloat(min(elapsed, action.duration)))

            case let .moveTo(point, onlyX, onlyY):
                if let point {
                    node.position = CGPoint(
                        x: from.position.x + (point.x - from.position.x) * t,
                        y: from.position.y + (point.y - from.position.y) * t
                    )
                } else if let onlyX {
                    node.position.x = from.position.x + (onlyX - from.position.x) * t
                } else if let onlyY {
                    node.position.y = from.position.y + (onlyY - from.position.y) * t
                }

            case let .moveBy(delta):
                node.position = CGPoint(
                    x: from.position.x + delta.dx * t,
                    y: from.position.y + delta.dy * t
                )

            case let .fadeTo(alpha):
                node.alpha = from.alpha + (alpha - from.alpha) * t

            case let .fadeBy(delta):
                node.alpha = from.alpha + delta * t

            case let .scaleTo(uniform, onlyX, onlyY):
                if let uniform {
                    node.xScale = from.xScale + (uniform - from.xScale) * t
                    node.yScale = from.yScale + (uniform - from.yScale) * t
                } else if let onlyX {
                    node.xScale = from.xScale + (onlyX - from.xScale) * t
                } else if let onlyY {
                    node.yScale = from.yScale + (onlyY - from.yScale) * t
                }

            case let .scaleBy(factor):
                node.xScale = from.xScale * (1 + (factor - 1) * t)
                node.yScale = from.yScale * (1 + (factor - 1) * t)

            case let .rotateTo(angle):
                node.zRotation = from.zRotation + (angle - from.zRotation) * t

            case let .follow(points, asOffset, orient):
                guard let first = points.first else { break }
                var lengths: [CGFloat] = [0]
                for i in 1..<max(points.count, 1) {
                    lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
                }
                let target = (lengths.last ?? 0) * min(max(t, 0), 1)
                var at = first, angle: CGFloat?
                if points.count > 1 {
                    var i = 1
                    while i < points.count - 1, lengths[i] < target { i += 1 }
                    let span = lengths[i] - lengths[i - 1]
                    let f = span > 0 ? (target - lengths[i - 1]) / span : 0
                    let a = points[i - 1], b = points[i]
                    at = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                    angle = atan2(b.y - a.y, b.x - a.x)
                }
                node.position = asOffset ? CGPoint(x: from.position.x + at.x - first.x, y: from.position.y + at.y - first.y) : at
                if orient, let angle { node.zRotation = angle }

            case let .rotateToShortest(angle):
                var turn = (angle - from.zRotation).truncatingRemainder(dividingBy: 2 * .pi)
                if turn > .pi { turn -= 2 * .pi } else if turn < -.pi { turn += 2 * .pi }
                node.zRotation = from.zRotation + turn * t

            case let .rotateBy(angle):
                node.zRotation = from.zRotation + angle * t

            case let .animate(textures, timePerFrame, restore):
                guard let sprite = node as? SKSpriteNode, !textures.isEmpty else { break }
                let step = Int(elapsed / timePerFrame)
                if step >= textures.count {
                    if restore { sprite.texture = textures.first }
                } else {
                    sprite.texture = textures[step]
                }

            case let .warpTo(target):
                SKAction.warp(node, from: from.warp, to: target, progress: t)

            case let .warps(warps, times, restore):
                SKAction.warp(node, from: from.warp, through: warps, times: times,
                              at: TimeInterval(t) * action.duration, restore: restore)

            default:
                break
            }
        }
    }
}

#endif
