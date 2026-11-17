#if SPRITEKIT_SHIM
import Foundation

public enum SKSceneScaleMode: Int, Sendable {
    case fill, aspectFill, aspectFit, resizeFill
}

/// The root of a scene graph. The game's eight SKScene subclasses override
/// `didMove(to:)`, `update(_:)` and `didChangeSize(_:)`, so those are the
/// hooks the renderer drives.
open class SKScene: SKNode {
    open var size: CGSize {
        didSet {
            guard size != oldValue else { return }
            didChangeSize(oldValue)
        }
    }

    open var scaleMode: SKSceneScaleMode = .aspectFill
    open var backgroundColor: SKColor = .black
    open var anchorPoint: CGPoint = .zero
    open internal(set) weak var view: SKView?

    /// The node the view draws the scene from, if it is in this scene's
    /// tree: its position stands in the middle of the view, its scale and
    /// rotation are undone, and its own children stay put on the screen
    /// (see `SKCameraNode`).
    open weak var camera: SKCameraNode?

    /// Touches in flight, by finger, each with the node that took it, so
    /// every phase after `began` reaches the same node (see Touches.swift).
    var activeTouches: [Int: ActiveTouch] = [:]
    /// Whether its actions have had a frame in the view since it was last
    /// presented: SpriteKit starts a scene's action clock on its first
    /// frame, so that frame counts no time (`SKView.advance`).
    var actionClockStarted = false

    /// Nodes with constraints, in their turn order, and those that join it
    /// at the next pass (`SKConstraint.swift`).
    var constrained: [ConstrainedNode] = []
    var pendingConstrained: [ConstrainedNode] = []

    public init(size: CGSize) {
        self.size = size
        super.init()
    }

    /// Called once the scene is in a view.
    open func didMove(to view: SKView) {}
    open func willMove(from view: SKView) {}

    /// Called once a frame, before actions are advanced.
    open func update(_ currentTime: TimeInterval) {}
    /// Called once a frame, after the constraints are applied.
    open func didApplyConstraints() {}
    open func didChangeSize(_ oldSize: CGSize) {}

    open override var contentFrame: CGRect {
        CGRect(origin: .zero, size: size)
    }
}

#endif
