#if SPRITEKIT_SHIM
import Foundation

/// The scene graph node.
///
/// Open rather than final, so the game's 104 SpriteKit subclasses compile
/// against it unchanged — the reason this layer is Swift-native rather than a
/// wrapper over a C++ engine, which Swift cannot subclass.
@preconcurrency @MainActor
open class SKNode {
    /// UIKit's accessibility label, which every `NSObject` carries. Kept,
    /// not read: the game supports no screen reader (AGENTS.md), and only
    /// the Help button's badge sets one.
    open var accessibilityLabel: String?

    // MARK: Tree

    public private(set) weak var parent: SKNode?
    public private(set) var children: [SKNode] = []

    open var name: String?
    public var userData: NSMutableDictionary?

    public init() {}

    open func addChild(_ node: SKNode) {
        precondition(node.parent == nil, "node already has a parent")
        precondition(node !== self, "a node cannot be its own child")
        node.parent = self
        children.append(node)
        if SKNode.constraintsInUse, let scene { node.constraintsEnter(scene) }
    }

    open func insertChild(_ node: SKNode, at index: Int) {
        precondition(node.parent == nil, "node already has a parent")
        node.parent = self
        children.insert(node, at: index)
        if SKNode.constraintsInUse, let scene { node.constraintsEnter(scene) }
    }

    open func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        self.parent = nil
        if SKNode.constraintsInUse { constraintsLeave() }
    }

    open func removeAllChildren() {
        for child in children {
            child.parent = nil
            if SKNode.constraintsInUse { child.constraintsLeave() }
        }
        children.removeAll()
    }

    // MARK: Constraints (SKConstraint.swift)

    /// SpriteKit's constraints, applied by the scene once a frame after the
    /// actions, in the order nodes were given them.
    open var constraints: [SKConstraint]? {
        didSet {
            if constraints?.isEmpty == false {
                SKNode.constraintsInUse = true
                if let scene { enterConstraintOrder(scene) } else { leaveConstraintOrder() }
            } else {
                leaveConstraintOrder()
            }
        }
    }

    /// The scene whose turn order this node is in, and whether it is still
    /// waiting to join it at the next pass.
    weak var constraintScene: SKScene?
    var constraintPending = false

    open func removeChildren(in nodes: [SKNode]) {
        for node in nodes where node.parent === self { node.removeFromParent() }
    }

    /// Only the simple "//name" and "name" forms the game uses.
    open func childNode(withName name: String) -> SKNode? {
        let wanted = name.hasPrefix("//") ? String(name.dropFirst(2)) : name
        for child in children {
            if child.name == wanted { return child }
            if let found = child.childNode(withName: wanted) { return found }
        }
        return nil
    }

    open func enumerateChildNodes(withName name: String, using block: (SKNode, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop = ObjCBool(false)
        for child in children {
            if child.name == name {
                withUnsafeMutablePointer(to: &stop) { block(child, $0) }
                if stop.boolValue { return }
            }
            child.enumerateChildNodes(withName: name, using: block)
        }
    }

    /// The scene this node is in, if any.
    open var scene: SKScene? { self as? SKScene ?? parent?.scene }

    public func inParentHierarchy(_ node: SKNode) -> Bool {
        var cursor = parent
        while let current = cursor {
            if current === node { return true }
            cursor = current.parent
        }
        return false
    }

    // MARK: Placement

    open var position: CGPoint = .zero
    open var zPosition: CGFloat = 0
    open var zRotation: CGFloat = 0
    open var xScale: CGFloat = 1
    open var yScale: CGFloat = 1
    open var alpha: CGFloat = 1
    open var isHidden: Bool = false
    open var isUserInteractionEnabled: Bool = false

    /// Whether `point`, in **this node's parent's** coordinates, falls inside
    /// the accumulated frame — SpriteKit's own meaning, which is why the
    /// point is in the parent's space and not the node's. As measured on a
    /// Mac, hidden nodes answer too and the far edges are open (unlike
    /// `nodes(at:)`'s). `open`, as in SpriteKit: games narrow a button's hit
    /// area by overriding it. As there, `nodes(at:)` and `atPoint(_:)` don't
    /// consult an override.
    open func contains(_ point: CGPoint) -> Bool {
        calculateAccumulatedFrame().contains(point)
    }

    /// Action playback rate, inherited multiplicatively as SpriteKit does.
    open var speed: CGFloat = 1
    open var isPaused: Bool = false

    // MARK: - Touches
    //
    // Declared here rather than in Touches.swift's extension because a
    // method on an extension dispatches statically: the game's 13 overrides
    // would compile and never be called. Delivery itself is in Touches.swift.

    open func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    open func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    open func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    open func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    open func setScale(_ scale: CGFloat) {
        xScale = scale
        yScale = scale
    }

    /// This node's transform relative to its parent.
    public var localTransform: CGAffineTransform {
        CGAffineTransform(scaleX: xScale, y: yScale)
            .rotated(by: zRotation)
            .concatenating(CGAffineTransform(translationX: position.x, y: position.y))
    }

    /// This node's transform relative to the scene.
    public var worldTransform: CGAffineTransform {
        guard let parent else { return localTransform }
        return localTransform.concatenating(parent.worldTransform)
    }

    /// Alpha multiplied down the tree, as SpriteKit composites it.
    public var worldAlpha: CGFloat {
        guard let parent else { return alpha }
        return alpha * parent.worldAlpha
    }

    public func convert(_ point: CGPoint, from node: SKNode) -> CGPoint {
        point.applying(node.worldTransform).applying(worldTransform.inverted())
    }

    public func convert(_ point: CGPoint, to node: SKNode) -> CGPoint {
        point.applying(worldTransform).applying(node.worldTransform.inverted())
    }

    /// The node's own content box in its own coordinates. SKNode itself draws
    /// nothing; drawing subclasses override this.
    open var contentFrame: CGRect { .zero }

    /// This node's frame in its parent's coordinates.
    open var frame: CGRect { contentFrame.applying(localTransform) }

    /// The union of this node's and its descendants' frames, in the
    /// **parent's** coordinates (the node's own transform applied), hidden
    /// and transparent descendants included — SpriteKit's, as measured on the
    /// Mac (`SceneSupportTests`). The game leans on both: a dropdown finds
    /// its anchor by subtracting the anchor's position, and a sample is
    /// fitted by its icon's frame with the icon's scale in it.
    open func calculateAccumulatedFrame() -> CGRect {
        accumulatedContents(includingHidden: true).applying(localTransform)
    }

    /// What this node and its descendants draw, in its **own** coordinates:
    /// the box an effect node's texture covers, and the box a touch is hit
    /// against (with what is hidden left out, as nothing hidden is drawn or
    /// touched).
    func accumulatedContents(includingHidden: Bool) -> CGRect {
        var total: CGRect? = contentFrame == .zero ? nil : contentFrame
        for child in children where includingHidden || !child.isHidden {
            let childFrame = child.accumulatedContents(includingHidden: includingHidden).applying(child.localTransform)
            guard childFrame != .zero else { continue }
            total = total.map { $0.union(childFrame) } ?? childFrame
        }
        return total ?? .zero
    }

    // MARK: Actions

    private var runningActions: [RunningAction] = []

    /// A running action, by reference rather than by value.
    ///
    /// It has to be a reference: an action's own block may start, replace or
    /// stop actions on the very node it is running on — SpriteKit allows it
    /// and the game leans on it everywhere (a looping glance schedules the
    /// next one, a board cue starts the move it announces). Advancing a
    /// struct in place would hold an exclusive access to `runningActions`
    /// open across the block, and the second access from inside it aborts
    /// the process with "Fatal access conflict detected".
    private final class RunningAction {
        let key: String?
        var state: SKAction.State
        let completion: (() -> Void)?
        /// Set when the action is taken off, so a tick already in flight
        /// stops advancing it.
        var isCancelled = false

        init(key: String?, state: SKAction.State, completion: (() -> Void)?) {
            self.key = key
            self.state = state
            self.completion = completion
        }
    }

    open func run(_ action: SKAction) {
        runningActions.append(RunningAction(key: nil, state: action.makeState(), completion: nil))
    }

    open func run(_ action: SKAction, withKey key: String) {
        removeAction(forKey: key)
        runningActions.append(RunningAction(key: key, state: action.makeState(), completion: nil))
    }

    open func run(_ action: SKAction, completion: @escaping () -> Void) {
        runningActions.append(RunningAction(key: nil, state: action.makeState(), completion: completion))
    }

    open func action(forKey key: String) -> SKAction? {
        runningActions.first { $0.key == key }?.state.action
    }

    open func removeAction(forKey key: String) {
        for running in runningActions where running.key == key { running.isCancelled = true }
        runningActions.removeAll { $0.key == key }
    }

    open func removeAllActions() {
        for running in runningActions { running.isCancelled = true }
        runningActions.removeAll()
    }

    open var hasActions: Bool { !runningActions.isEmpty }

    /// Effective playback rate, inherited down the tree.
    var worldSpeed: CGFloat {
        guard let parent else { return speed }
        return speed * parent.worldSpeed
    }

    var isEffectivelyPaused: Bool {
        if isPaused { return true }
        return parent?.isEffectivelyPaused ?? false
    }

    /// Advances this node's actions and its descendants' by `delta` seconds.
    /// The renderer calls this once a frame on the scene.
    public func tickActions(_ delta: TimeInterval) {
        tickTree(delta, pausedAbove: parent?.isEffectivelyPaused ?? false, speedAbove: parent?.worldSpeed ?? 1)
    }

    /// `tickActions` for a node whose ancestors are `pausedAbove` and play
    /// at `speedAbove` (`parent.worldSpeed`), handed down the tree so no
    /// node walks its parents again: a deep tree's walks once took a third
    /// of a frame on the Galaxy M31. Its own `isPaused` and `speed` are read
    /// as it's reached, and again after its actions run, as before.
    func tickTree(_ delta: TimeInterval, pausedAbove: Bool, speedAbove: CGFloat) {
        if !runningActions.isEmpty, !pausedAbove, !isPaused {
            // `worldSpeed`'s own product, in its order.
            let scaled = delta * TimeInterval(max(0, speed * speedAbove))
            // A snapshot of the references, and nothing holding the list
            // open: a block may add to it, take things off it or clear it
            // while it runs. An action taken off meanwhile is cancelled, so
            // this loop drops it rather than advancing it once more.
            let ticking = runningActions
            var finished: [(() -> Void)] = []
            for running in ticking {
                guard !running.isCancelled else { continue }
                guard running.state.advance(by: scaled, on: self) else { continue }
                running.isCancelled = true
                runningActions.removeAll { $0 === running }
                if let completion = running.completion { finished.append(completion) }
            }
            for completion in finished { completion() }
        }
        let paused = pausedAbove || isPaused
        let speed = self.speed * speedAbove
        // A child may remove itself while ticking, so walk a snapshot.
        for child in Array(children) { child.tickTree(delta, pausedAbove: paused, speedAbove: speed) }
    }
}

#endif
