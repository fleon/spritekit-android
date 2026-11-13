#if SPRITEKIT_SHIM
import Foundation

public enum SKActionTimingMode: Int, Sendable {
    case linear, easeIn, easeOut, easeInEaseOut

    func apply(_ t: CGFloat) -> CGFloat {
        switch self {
        case .linear: return t
        case .easeIn: return t * t
        case .easeOut: return t * (2 - t)
        case .easeInEaseOut: return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t
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
        case rotateBy(CGFloat)
        case animate([SKTexture], TimeInterval, Bool)
        case sequence([SKAction])
        case group([SKAction])
        case repeating(SKAction, Int?)              // nil count == forever
        case removeFromParent
        case hide(Bool)
        case warpTo(SKWarpGeometry)                 // SKWarpGeometry.swift
        case warps([SKWarpGeometry], [TimeInterval], Bool)
    }

    let kind: Kind
    public var duration: TimeInterval
    public var timingMode: SKActionTimingMode = .linear
    public var speed: CGFloat = 1

    init(kind: Kind, duration: TimeInterval) {
        self.kind = kind
        self.duration = duration
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
    public static func unhide() -> SKAction { SKAction(kind: .hide(false), duration: 0) }

    var totalDuration: TimeInterval {
        speed > 0 ? duration / TimeInterval(speed) : duration
    }

    // MARK: Playback

    func makeState() -> State { State(action: self) }

    /// One running instance. Actions are shared and re-runnable, so all
    /// mutable playback state lives here rather than on the action.
    struct State {
        let action: SKAction
        private var elapsed: TimeInterval = 0
        private var started = false
        private var from: Snapshot?
        private var children: [State] = []
        private var index = 0
        private var repeated = 0

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

            switch action.kind {
            case let .sequence(actions):
                var remaining = delta
                while index < children.count {
                    let done = children[index].advance(by: remaining, on: node)
                    if !done { return false }
                    // Carry the overflow into the next step so a long frame
                    // does not stall a sequence one action per frame.
                    remaining = max(0, remaining - children[index].action.totalDuration)
                    index += 1
                    if remaining <= 0 && index < children.count { return false }
                }
                return true

            case .group:
                var allDone = true
                for i in children.indices where !children[i].advance(by: delta, on: node) {
                    allDone = false
                }
                return allDone

            case let .repeating(_, count):
                if children[0].advance(by: delta, on: node) {
                    repeated += 1
                    if let count, repeated >= count { return true }
                    children[0] = children[0].action.makeState()
                }
                return false

            case let .run(block):
                block()
                return true

            case .removeFromParent:
                node.removeFromParent()
                return true

            case let .hide(hidden):
                node.isHidden = hidden
                return true

            default:
                elapsed += delta * TimeInterval(max(0, action.speed))
                let total = action.duration
                let raw = total > 0 ? CGFloat(min(1, elapsed / total)) : 1
                apply(progress: action.timingMode.apply(raw), rawElapsed: elapsed, on: node)
                return total <= 0 || elapsed >= total
            }
        }

        private func apply(progress t: CGFloat, rawElapsed: TimeInterval, on node: SKNode) {
            guard let from else { return }
            switch action.kind {
            case .wait:
                break

            case let .custom(block):
                // SpriteKit hands the block elapsed seconds, not progress, and
                // does not apply timingMode to it.
                block(node, CGFloat(min(rawElapsed, action.duration)))

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

            case let .rotateBy(angle):
                node.zRotation = from.zRotation + angle * t

            case let .animate(textures, timePerFrame, restore):
                guard let sprite = node as? SKSpriteNode, !textures.isEmpty else { break }
                let step = Int(rawElapsed / timePerFrame)
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
