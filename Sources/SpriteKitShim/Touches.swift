#if SPRITEKIT_SHIM
import Foundation

// Touch delivery, shaped so the game's 13 `touchesBegan` overrides compile
// and behave as they do on iOS. The four handlers themselves live in
// SKNode's class body (SKNode.swift), because a method declared in an
// extension dispatches statically and could not be overridden.
//
// What the game relies on, and what is therefore reproduced here:
//
//   - A node with `isUserInteractionEnabled` receives touches that land on
//     it, and the topmost such node wins — by accumulated zPosition, the
//     same order the draw list uses, so what is drawn over something else
//     also takes the tap.
//   - An interactive node is hit over everything it draws, children
//     included: every one of the game's buttons is a plain `SKNode` whose
//     art hangs off it, so hit-testing the node's own quad would never find
//     one.
//   - A touch that begins on a node stays with that node until it ends or is
//     cancelled, wherever it travels. `PressableNode` depends on this: it
//     tracks whether the finger is still inside itself.
//   - `location(in:)` answers in any node's coordinates, not only the one
//     handling the touch.
//
// What is deliberately not here: UIKit's responder chain. SpriteKit's own
// delivery is not a responder chain either — an unhandled touch does not
// walk up to the parent node — so a node that takes touches and ignores a
// phase swallows it, exactly as on iOS.

public enum UITouchPhase: Int, Sendable {
    case began, moved, ended, cancelled
}

/// Stands in for UIKit's `UITouch`. The game reads `location(in:)`,
/// `previousLocation(in:)` and `timestamp` from it and nothing else.
@MainActor
public final class UITouch: Hashable {
    /// Which finger this is, for the length of one gesture.
    public let identifier: Int
    public internal(set) var phase: UITouchPhase
    /// Seconds on the same monotonic clock the frame loop runs on.
    public internal(set) var timestamp: TimeInterval

    /// Where the touch is, and was, in the scene's own coordinates.
    private var sceneLocation: CGPoint
    private var previousSceneLocation: CGPoint
    private weak var scene: SKScene?

    init(identifier: Int, phase: UITouchPhase, sceneLocation: CGPoint, timestamp: TimeInterval, scene: SKScene?) {
        self.identifier = identifier
        self.phase = phase
        self.sceneLocation = sceneLocation
        previousSceneLocation = sceneLocation
        self.timestamp = timestamp
        self.scene = scene
    }

    public func location(in node: SKNode) -> CGPoint {
        guard let scene, node !== scene else { return sceneLocation }
        return node.convert(sceneLocation, from: scene)
    }

    /// Where the touch is in `view`'s points, or the window's for nil: the
    /// view fills the window on Android, so both are the scene's view
    /// points. `TouchOriginWindow` notes each touch this way.
    public func location(in view: UIView?) -> CGPoint {
        guard let scene else { return sceneLocation }
        return scene.convertPoint(toView: sceneLocation)
    }

    public func previousLocation(in node: SKNode) -> CGPoint {
        guard let scene, node !== scene else { return previousSceneLocation }
        return node.convert(previousSceneLocation, from: scene)
    }

    func move(to location: CGPoint, phase: UITouchPhase, timestamp: TimeInterval) {
        previousSceneLocation = sceneLocation
        sceneLocation = location
        self.phase = phase
        self.timestamp = timestamp
    }

    // By identity, which needs no isolation.
    nonisolated public static func == (lhs: UITouch, rhs: UITouch) -> Bool { lhs === rhs }
    nonisolated public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Stands in for UIKit's `UIEvent`: a touch event and its touches, which
/// the window sees before the scene does (`TouchOriginWindow` notes where
/// the player touched; the scenes' handlers never read it).
@MainActor
public final class UIEvent {
    public enum EventType: Int, Sendable { case touches, motion, remoteControl, presses }

    public let type: EventType
    public let allTouches: Set<UITouch>?

    init(touches: Set<UITouch> = []) {
        type = .touches
        allTouches = touches
    }
}

// MARK: - Hit testing

public extension SKNode {
    /// Whether `point`, in **this node's parent's** coordinates, falls inside
    /// everything the node draws — SpriteKit's own meaning, which is why the
    /// point is in the parent's space and not the node's.
    func contains(_ point: CGPoint) -> Bool {
        guard !isHidden else { return false }
        return calculateAccumulatedFrame()
            .applying(localTransform)
            .contains(point)
    }

    /// Every node drawing at `point` (in this node's coordinates), this one
    /// included if it draws there, topmost first.
    func nodes(at point: CGPoint) -> [SKNode] {
        var found: [(node: SKNode, z: CGFloat, order: Int)] = []
        collectHits(at: point, z: 0, into: &found)
        return found
            .sorted { $0.z == $1.z ? $0.order > $1.order : $0.z > $1.z }
            .map(\.node)
    }

    /// The topmost node at `point` (in this node's coordinates), or this node
    /// when nothing is drawn there — SpriteKit returns the receiver, not nil.
    func atPoint(_ point: CGPoint) -> SKNode {
        nodes(at: point).first ?? self
    }

    /// Depth-first, carrying accumulated z so the result can be ordered the
    /// way the frame is drawn, and tree order so ties break as `DrawList`'s
    /// stable sort breaks them.
    private func collectHits(
        at point: CGPoint,
        z: CGFloat,
        into found: inout [(node: SKNode, z: CGFloat, order: Int)]
    ) {
        guard !isHidden, alpha > 0 else { return }
        let depth = z + zPosition
        if contentFrame != .zero, contentFrame.contains(point) {
            found.append((self, depth, found.count))
        }
        for child in children {
            child.collectHits(at: child.convert(point, from: self), z: depth, into: &found)
        }
    }

    /// The topmost node at `point` (in this node's coordinates) that takes
    /// touches, looking at everything each one draws rather than only its own
    /// quad. Nil when nothing there does.
    func interactiveNode(at point: CGPoint) -> SKNode? {
        var best: (node: SKNode, z: CGFloat, order: Int)?
        var counter = 0
        func walk(_ node: SKNode, point: CGPoint, z: CGFloat) {
            guard !node.isHidden, node.alpha > 0 else { return }
            let depth = z + node.zPosition
            counter += 1
            if node.isUserInteractionEnabled, node !== self,
               node.calculateAccumulatedFrame().contains(point) {
                if best == nil || depth > best!.z || (depth == best!.z && counter > best!.order) {
                    best = (node, depth, counter)
                }
            }
            for child in node.children {
                walk(child, point: child.convert(point, from: node), z: depth)
            }
        }
        walk(self, point: point, z: 0)
        return best?.node
    }
}

// MARK: - Delivery

public extension SKScene {
    /// Hands one touch to the scene graph. `location` is in the scene's own
    /// coordinates: the renderer owns the projection, so it is also the one
    /// that undoes it, and nothing here needs the drawable size or the scale
    /// mode.
    ///
    /// Returns the node that took it, for a caller that wants to know a tap
    /// was consumed.
    @discardableResult
    func deliverTouch(
        phase: UITouchPhase,
        at location: CGPoint,
        identifier: Int = 0,
        timestamp: TimeInterval
    ) -> SKNode? {
        switch phase {
        case .began:
            let touch = UITouch(
                identifier: identifier, phase: .began,
                sceneLocation: location, timestamp: timestamp, scene: self
            )
            let event = UIEvent(touches: [touch])
            // As UIKit does, the window sees the event before anything in it.
            view?.window?.sendEvent(event)
            let target = interactiveNode(at: location) ?? self
            activeTouches[identifier] = ActiveTouch(touch: touch, target: target)
            target.touchesBegan([touch], with: event)
            return target

        case .moved, .ended, .cancelled:
            guard let active = activeTouches[identifier] else { return nil }
            active.touch.move(to: location, phase: phase, timestamp: timestamp)
            let event = UIEvent(touches: [active.touch])
            view?.window?.sendEvent(event)
            switch phase {
            case .moved:
                active.target.touchesMoved([active.touch], with: event)
            case .ended:
                activeTouches[identifier] = nil
                active.target.touchesEnded([active.touch], with: event)
            default:
                activeTouches[identifier] = nil
                active.target.touchesCancelled([active.touch], with: event)
            }
            return active.target
        }
    }

    /// Cancels everything in flight — what the shell calls when Android takes
    /// the window away mid-gesture, so a pressed button does not stay pressed.
    func cancelTouches(timestamp: TimeInterval) {
        for identifier in activeTouches.keys {
            deliverTouch(phase: .cancelled, at: .zero, identifier: identifier, timestamp: timestamp)
        }
    }
}

/// One touch in flight and the node it was handed to.
struct ActiveTouch {
    let touch: UITouch
    let target: SKNode
}

#endif
