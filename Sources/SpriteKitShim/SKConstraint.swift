#if SPRITEKIT_SHIM
import Foundation

/// SpriteKit's constraints: limits on a node's position, its distance from a
/// point or node, and its rotation, applied once a frame after the actions
/// (`SKScene.applyConstraints`).
///
/// Measured with `SKRenderer` on a Mac (macOS 27.2), and pinned in
/// `ConstraintTests`:
/// - Setting them changes nothing until the frame's constraint pass, which
///   comes after the actions and before `didApplyConstraints()`.
/// - Each node's run in array order, each over what the one before left.
/// - Nodes take their turn in the order they were given constraints, or
///   entered the scene with them (in tree order, for a subtree added at
///   once). Setting them again after a pass gives the node another turn at
///   the end and keeps the ones it had, so it runs once for each; setting
///   them again before a pass changes nothing. Setting none, or an empty
///   list, takes no turn away (the node's turns run nothing until it has
///   some again); leaving the scene takes them all. SpriteKit's list grows
///   with every set, and so does each pass's work: a game that sets
///   constraints every frame slows on both.
/// - A node not in a scene, or in a paused scene, is left alone; a paused
///   node is not.
/// - Ranges clamp as `max(lower, min(upper, value))`, so an inverted range
///   holds its lower limit.
/// - Positions and distances are in the parent's space, or the
///   `referenceNode`'s; a distance of zero has no direction and is left.
/// - `zRotation` clamps the angle as it is, unwrapped. With a
///   `referenceNode`, SpriteKit's doesn't measure the angle from the
///   reference in any way that reduces to a rule (even inside the range it
///   takes a quarter turn off); the shim clamps in the node's own terms and
///   ignores the reference.
/// - `orient` points the node's x axis at the target, in the parent's
///   space: the direction `atan2(dy, dx)`, a turn added if it's below
///   −π/2 (so in [−π/2, 3π/2)), and the angle clamped between that plus
///   the offset's limits. Nothing is unwrapped: an angle several turns
///   round comes back within one.
public final class SKConstraint: @unchecked Sendable {
    enum Kind {
        case position(x: SKRange?, y: SKRange?)
        case distanceToNode(SKRange, SKNode)
        case distanceToPoint(SKRange, CGPoint, SKNode?)
        case zRotation(SKRange)
        case orientToNode(SKNode, SKRange)
        case orientToPoint(CGPoint, SKNode?, SKRange)
    }

    let kind: Kind

    public var enabled = true
    /// The space the constraint's positions are in; the node's parent if nil.
    public var referenceNode: SKNode?

    init(_ kind: Kind) { self.kind = kind }

    public class func positionX(_ range: SKRange) -> SKConstraint { SKConstraint(.position(x: range, y: nil)) }
    public class func positionY(_ range: SKRange) -> SKConstraint { SKConstraint(.position(x: nil, y: range)) }
    public class func positionX(_ xRange: SKRange, y yRange: SKRange) -> SKConstraint {
        SKConstraint(.position(x: xRange, y: yRange))
    }

    public class func distance(_ range: SKRange, to node: SKNode) -> SKConstraint {
        SKConstraint(.distanceToNode(range, node))
    }

    public class func distance(_ range: SKRange, to point: CGPoint) -> SKConstraint {
        SKConstraint(.distanceToPoint(range, point, nil))
    }

    public class func distance(_ range: SKRange, to point: CGPoint, in node: SKNode) -> SKConstraint {
        SKConstraint(.distanceToPoint(range, point, node))
    }

    public class func zRotation(_ zRange: SKRange) -> SKConstraint { SKConstraint(.zRotation(zRange)) }

    public class func orient(to node: SKNode, offset radians: SKRange) -> SKConstraint {
        SKConstraint(.orientToNode(node, radians))
    }

    public class func orient(to point: CGPoint, offset radians: SKRange) -> SKConstraint {
        SKConstraint(.orientToPoint(point, nil, radians))
    }

    public class func orient(to point: CGPoint, in node: SKNode, offset radians: SKRange) -> SKConstraint {
        SKConstraint(.orientToPoint(point, node, radians))
    }

    /// Brings `node` within this constraint.
    @MainActor func apply(to node: SKNode) {
        guard let parent = node.parent else { return }
        switch kind {
        case let .position(xRange, yRange):
            let space = referenceNode ?? parent
            var at = space === parent ? node.position : space.convert(node.position, from: parent)
            if let xRange { at.x = xRange.clamp(at.x) }
            if let yRange { at.y = yRange.clamp(at.y) }
            node.position = space === parent ? at : parent.convert(at, from: space)

        case let .distanceToNode(range, target):
            let space = referenceNode ?? parent
            let from = target.parent.map { space.convert(target.position, from: $0) } ?? space.convert(.zero, from: target)
            keep(node, parent: parent, space: space, from: from, within: range)

        case let .distanceToPoint(range, point, pointSpace):
            let space = referenceNode ?? parent
            let from = pointSpace.map { space.convert(point, from: $0) } ?? point
            keep(node, parent: parent, space: space, from: from, within: range)

        case let .zRotation(range):
            node.zRotation = range.clamp(node.zRotation)

        case let .orientToNode(target, offset):
            let toward = target.parent.map { parent.convert(target.position, from: $0) } ?? parent.convert(.zero, from: target)
            orient(node, toward: toward, offset: offset)

        case let .orientToPoint(point, pointSpace, offset):
            orient(node, toward: pointSpace.map { parent.convert(point, from: $0) } ?? point, offset: offset)
        }
    }

    /// Moves `node` along the line from `from`, in `space`, until its
    /// distance from it is in `range`.
    @MainActor private func keep(_ node: SKNode, parent: SKNode, space: SKNode, from: CGPoint, within range: SKRange) {
        let at = space === parent ? node.position : space.convert(node.position, from: parent)
        let dx = at.x - from.x, dy = at.y - from.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0 else { return }
        let kept = range.clamp(distance)
        guard kept != distance else { return }
        let moved = CGPoint(x: from.x + dx / distance * kept, y: from.y + dy / distance * kept)
        node.position = space === parent ? moved : parent.convert(moved, from: space)
    }

    @MainActor private func orient(_ node: SKNode, toward target: CGPoint, offset: SKRange) {
        var direction = atan2(target.y - node.position.y, target.x - node.position.x)
        if direction < -.pi / 2 { direction += 2 * .pi }
        node.zRotation = max(direction + offset.lowerLimit, min(direction + offset.upperLimit, node.zRotation))
    }
}

/// SpriteKit's numeric range: emitter and constraint limits. Here rather
/// than beside the paths, which build only off Apple, so constraints
/// host-test.
public final class SKRange: @unchecked Sendable {
    public var lowerLimit: CGFloat
    public var upperLimit: CGFloat

    public init(lowerLimit: CGFloat, upperLimit: CGFloat) {
        self.lowerLimit = lowerLimit
        self.upperLimit = upperLimit
    }

    public convenience init(constantValue: CGFloat) {
        self.init(lowerLimit: constantValue, upperLimit: constantValue)
    }

    public convenience init(value: CGFloat, variance: CGFloat) {
        self.init(lowerLimit: value - variance, upperLimit: value + variance)
    }

    /// No upper limit: SpriteKit's is the greatest finite `CGFloat`.
    public convenience init(lowerLimit: CGFloat) {
        self.init(lowerLimit: lowerLimit, upperLimit: .greatestFiniteMagnitude)
    }

    public convenience init(upperLimit: CGFloat) {
        self.init(lowerLimit: -.greatestFiniteMagnitude, upperLimit: upperLimit)
    }

    public class func withNoLimits() -> SKRange {
        SKRange(lowerLimit: -.greatestFiniteMagnitude, upperLimit: .greatestFiniteMagnitude)
    }
}

extension SKRange {
    func clamp(_ value: CGFloat) -> CGFloat { max(lowerLimit, min(upperLimit, value)) }
}

// MARK: The scene's turn order

extension SKScene {
    /// The frame's constraint pass: every node in the scene with
    /// constraints, in the order they were given them (see `SKConstraint`).
    /// The view calls it after the actions, then `didApplyConstraints()`.
    func applyConstraints() {
        guard !isPaused else { return }
        if !pendingConstrained.isEmpty {
            for entry in pendingConstrained {
                guard let node = entry.node, node.constraintScene === self else { continue }
                node.constraintPending = false
                constrained.append(entry)
            }
            pendingConstrained.removeAll()
        }
        guard !constrained.isEmpty else { return }
        constrained.removeAll { $0.node?.constraintScene !== self }
        for entry in constrained {
            guard let node = entry.node, node.constraintScene === self,
                  let constraints = node.constraints else { continue }
            for constraint in constraints where constraint.enabled {
                constraint.apply(to: node)
            }
        }
    }
}

struct ConstrainedNode {
    weak var node: SKNode?
}

extension SKNode {
    /// Whether any node has ever been given constraints: until one has,
    /// adding and removing nodes looks for none.
    nonisolated(unsafe) static var constraintsInUse = false

    /// Gives this node a turn at the end of its scene's order, keeping any it
    /// has there, unless it is already waiting for the next pass.
    func enterConstraintOrder(_ scene: SKScene) {
        if constraintScene === scene {
            guard !constraintPending else { return }
            constraintPending = true
            scene.pendingConstrained.append(ConstrainedNode(node: self))
            return
        }
        leaveConstraintOrder()
        constraintScene = scene
        constraintPending = true
        scene.pendingConstrained.append(ConstrainedNode(node: self))
    }

    /// Takes every turn this node has.
    func leaveConstraintOrder() {
        guard let scene = constraintScene else { return }
        scene.pendingConstrained.removeAll { $0.node === self }
        scene.constrained.removeAll { $0.node === self }
        constraintScene = nil
        constraintPending = false
    }

    /// A subtree entering `scene`: its constrained nodes take their turns
    /// in tree order.
    func constraintsEnter(_ scene: SKScene) {
        if constraints?.isEmpty == false { enterConstraintOrder(scene) }
        for child in children { child.constraintsEnter(scene) }
    }

    /// A subtree leaving its scene.
    func constraintsLeave() {
        if constraintScene != nil { leaveConstraintOrder() }
        for child in children { child.constraintsLeave() }
    }
}

#endif
