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

    public init(size: CGSize) {
        self.size = size
        super.init()
    }

    /// Called once the scene is in a view.
    open func didMove(to view: SKView) {}
    open func willMove(from view: SKView) {}

    /// Called once a frame, before actions are advanced.
    open func update(_ currentTime: TimeInterval) {}
    open func didChangeSize(_ oldSize: CGSize) {}

    open override var contentFrame: CGRect {
        CGRect(origin: .zero, size: size)
    }
}

/// The host surface. On Android this is backed by the GLES 3 context; the
/// shim keeps only what the game reads from it.
open class SKView {
    public var bounds: CGRect
    public private(set) var scene: SKScene?
    public var preferredFramesPerSecond: Int = 60
    public var isPaused: Bool = false

    /// Points-to-pixels, as the display reports it.
    public var contentScaleFactor: CGFloat = 3

    public init(bounds: CGRect) {
        self.bounds = bounds
    }

    open func presentScene(_ scene: SKScene?) {
        if let current = self.scene {
            current.willMove(from: self)
            current.view = nil
        }
        self.scene = scene
        guard let scene else { return }
        scene.view = self
        scene.didMove(to: self)
    }

    /// One frame: the scene's own update, then actions, then a draw list.
    open func tick(currentTime: TimeInterval, delta: TimeInterval) -> DrawList {
        guard let scene, !isPaused else { return DrawList() }
        scene.update(currentTime)
        scene.tickActions(delta)
        return DrawList(scene: scene)
    }
}

#endif
