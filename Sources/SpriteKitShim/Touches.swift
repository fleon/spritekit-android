#if SPRITEKIT_SHIM
import Foundation

// Touch delivery, shaped so the game's 13 `touchesBegan` overrides compile
// and behave as they do on iOS. The four handlers themselves live in
// SKNode's class body (SKNode.swift), because a method declared in an
// extension dispatches statically and could not be overridden.
//
// Which node a touch goes to is SpriteKit's own rule, read from its view on
// a Mac (iOS's `touchesBegan` and the Mac's `mouseDown` share it) and pinned
// in `TouchRoutingTests`:
//
//   - The view asks the scene for the node at the touch (`atPoint(_:)`,
//     whose order is `nodes(at:)`'s), then walks up from it to the first
//     node with `isUserInteractionEnabled`, the scene included (a scene
//     takes touches by default). If none does, the touch goes nowhere.
//   - So a node that doesn't take touches still stops them: drawn over a
//     control, it hands the touch to its own ancestors, not to the control.
//     And a control is hit over everything it draws, children included, as
//     each child walks up to it.
//   - A touch that begins on a node stays with that node until it ends or is
//     cancelled, wherever it travels.
//   - `location(in:)` answers in any node's coordinates, not only the one
//     handling the touch.
//
// What is deliberately not here: UIKit's responder chain. SpriteKit's own
// delivery is not a responder chain either: once a node has the touch, a
// phase it ignores is swallowed, exactly as on iOS.

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
    /// points. A window subclass noting each touch reads it this way.
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
/// the window sees before the scene does (a window subclass may note where
/// the player touched).
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
    /// Every descendant whose accumulated frame holds `point` (in this
    /// node's coordinates), topmost first; never this node itself. As
    /// SpriteKit measures it on a Mac: the frame counts hidden descendants
    /// and its edges are closed (a zero-size node is found at its own
    /// position), while a hidden or transparent node and everything under
    /// it is skipped. Nodes whose own content holds the point (a sprite's
    /// quad, transparent texels included; a plain node's position) come
    /// first, then those only their descendants' frames hold; each group by
    /// accumulated z, the later in tree order first on a tie, whether or not
    /// the view ignores sibling order.
    func nodes(at point: CGPoint) -> [SKNode] {
        var found: [Hit] = []
        if !isHidden, alpha > 0 {
            for child in children {
                child.collectHits(at: point, z: 0, into: &found)
            }
        }
        return found.sorted(by: Hit.isAbove).map(\.node)
    }

    /// The topmost node at `point` (in this node's coordinates), or this node
    /// when nothing is drawn there — SpriteKit returns the receiver, not nil.
    func atPoint(_ point: CGPoint) -> SKNode {
        nodes(at: point).first ?? self
    }

    /// Depth-first in tree order, as SpriteKit walks it: `point` is in the
    /// parent's coordinates, and a node whose accumulated frame misses it is
    /// skipped with everything under it.
    private func collectHits(at point: CGPoint, z: CGFloat, into found: inout [Hit]) {
        guard !isHidden, alpha > 0, calculateAccumulatedFrame().holds(point) else { return }
        let local = point.applying(localTransform.inverted())
        let depth = z + zPosition
        found.append(Hit(node: self, z: depth, order: found.count, drawn: contentFrame.holds(local)))
        for child in children {
            child.collectHits(at: local, z: depth, into: &found)
        }
    }

    /// The node a touch at `point` (in this node's coordinates) goes to, as
    /// SpriteKit's view picks it: the node there, or its nearest ancestor
    /// that takes touches. Nil when none of them does.
    internal func touchTarget(at point: CGPoint) -> SKNode? {
        var node: SKNode? = atPoint(point)
        while let current = node, !current.isUserInteractionEnabled {
            node = current.parent
        }
        return node
    }
}

/// One node under a point, with what SpriteKit orders it by.
private struct Hit {
    let node: SKNode
    /// Its accumulated zPosition.
    let z: CGFloat
    /// Its place in tree order.
    let order: Int
    /// Whether its own content, not only a descendant's, holds the point.
    let drawn: Bool

    static func isAbove(_ a: Hit, _ b: Hit) -> Bool {
        if a.drawn != b.drawn { return a.drawn }
        if a.z != b.z { return a.z > b.z }
        return a.order > b.order
    }
}

private extension CGRect {
    /// Containment with every edge closed, as SpriteKit hit-tests.
    func holds(_ point: CGPoint) -> Bool {
        minX <= point.x && point.x <= maxX && minY <= point.y && point.y <= maxY
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
    /// was consumed: nil when nothing there takes touches, the scene
    /// included, and the touch goes nowhere.
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
            guard let target = touchTarget(at: location) else { return nil }
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
