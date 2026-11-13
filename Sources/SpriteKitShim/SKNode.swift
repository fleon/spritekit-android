#if SPRITEKIT_SHIM
import Foundation

/// The scene graph node.
///
/// Open rather than final, so the game's 104 SpriteKit subclasses compile
/// against it unchanged — the reason this layer is Swift-native rather than a
/// wrapper over a C++ engine, which Swift cannot subclass.
open class SKNode {
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
    }

    open func insertChild(_ node: SKNode, at index: Int) {
        precondition(node.parent == nil, "node already has a parent")
        node.parent = self
        children.insert(node, at: index)
    }

    open func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        self.parent = nil
    }

    open func removeAllChildren() {
        for child in children { child.parent = nil }
        children.removeAll()
    }

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

    /// Action playback rate, inherited multiplicatively as SpriteKit does.
    open var speed: CGFloat = 1
    open var isPaused: Bool = false

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

    /// The union of this node's and its descendants' frames, in the parent's
    /// coordinates. Hidden nodes are left out, as SpriteKit leaves them out.
    open func calculateAccumulatedFrame() -> CGRect {
        var total: CGRect? = contentFrame == .zero ? nil : contentFrame
        for child in children where !child.isHidden {
            let childFrame = child.calculateAccumulatedFrame().applying(child.localTransform)
            guard childFrame != .zero else { continue }
            total = total.map { $0.union(childFrame) } ?? childFrame
        }
        return total ?? .zero
    }

    // MARK: Actions

    private var runningActions: [RunningAction] = []

    private struct RunningAction {
        let key: String?
        var state: SKAction.State
        let completion: (() -> Void)?
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
        runningActions.removeAll { $0.key == key }
    }

    open func removeAllActions() {
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
        if !isEffectivelyPaused, !runningActions.isEmpty {
            let scaled = delta * TimeInterval(max(0, worldSpeed))
            var finished: [(() -> Void)] = []
            for index in runningActions.indices.reversed() {
                let done = runningActions[index].state.advance(by: scaled, on: self)
                if done {
                    if let completion = runningActions[index].completion { finished.append(completion) }
                    runningActions.remove(at: index)
                }
            }
            for completion in finished { completion() }
        }
        // A child may remove itself while ticking, so walk a snapshot.
        for child in children { child.tickActions(delta) }
    }
}

#endif
