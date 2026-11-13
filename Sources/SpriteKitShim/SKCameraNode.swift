#if SPRITEKIT_SHIM
import Foundation

/// The point a scene is drawn from.
///
/// The game's own scenes never set one: only the debug Mac tools that film
/// the App Store videos do (`EventVideo`, which pans after whoever moves). It
/// is here so a scene that does draws as SpriteKit would, and because the
/// view's mapping between its points and the scene's runs through it.
///
/// What SpriteKit does with a scene's camera, and this does too:
///
/// - The camera's position is drawn in the middle of the view, whatever the
///   scene's `anchorPoint`.
/// - Its scale and rotation are undone: a camera scaled by 2 shows twice as
///   much of the scene, and one turned a quarter left shows it turned a
///   quarter right.
/// - Its children stay where they are on the screen as it moves, which is
///   what a HUD hangs off.
/// - A camera that is not in the scene's own tree is ignored.
open class SKCameraNode: SKNode {
    public override init() {
        super.init()
    }

    /// Whether any of `node` shows in the camera's view.
    open func contains(_ node: SKNode) -> Bool {
        guard let scene, node.scene === scene else { return false }
        return scene.viewedRect.intersects(scene.frameInScene(of: node))
    }

    /// The scene's own children that show in the camera's view.
    ///
    /// SpriteKit's documentation leaves the depth open; the scene's children
    /// are the nodes a game arranges on it, so they are what this tests.
    open func containedNodeSet() -> Set<SKNode> {
        guard let scene else { return [] }
        let viewed = scene.viewedRect
        return Set(scene.children.filter { viewed.intersects(scene.frameInScene(of: $0)) })
    }
}

/// SpriteKit's nodes are `NSObject`s, so they hash and compare by identity;
/// `containedNodeSet()` hands back a `Set<SKNode>`, which needs the same.
extension SKNode: Hashable {
    public static func == (lhs: SKNode, rhs: SKNode) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

// MARK: - Between the view and the scene

extension SKScene {
    /// The part of a scene the view shows, in the scene's own coordinates as
    /// they are with no camera: under aspect fill a little more than the
    /// scene in one direction, under aspect fit the scene inside its bars.
    ///
    /// `GLESRenderer.Viewport` projects with exactly this rectangle; the
    /// numbers are only ever worked out here.
    nonisolated public static func visibleRect(
        sceneSize: CGSize,
        anchorPoint: CGPoint,
        scaleMode: SKSceneScaleMode,
        viewSize: CGSize
    ) -> CGRect {
        var scale = CGPoint(x: 1, y: 1)
        if sceneSize.width > 0, sceneSize.height > 0, viewSize.width > 0, viewSize.height > 0 {
            let sx = viewSize.width / sceneSize.width
            let sy = viewSize.height / sceneSize.height
            switch scaleMode {
            case .fill, .resizeFill: scale = CGPoint(x: sx, y: sy)
            case .aspectFill: scale = CGPoint(x: max(sx, sy), y: max(sx, sy))
            case .aspectFit: scale = CGPoint(x: min(sx, sy), y: min(sx, sy))
            }
        }
        let width = viewSize.width / scale.x
        let height = viewSize.height / scale.y
        // The scene's origin sits at its anchor point, and what is left over
        // is shared evenly either side.
        return CGRect(
            x: -anchorPoint.x * sceneSize.width - (width - sceneSize.width) / 2,
            y: -anchorPoint.y * sceneSize.height - (height - sceneSize.height) / 2,
            width: width,
            height: height
        )
    }

    /// `visibleRect` for this scene in its view, or the scene itself when it
    /// is in none.
    public var visibleFrame: CGRect {
        SKScene.visibleRect(
            sceneSize: size, anchorPoint: anchorPoint, scaleMode: scaleMode,
            viewSize: view?.bounds.size ?? size
        )
    }

    /// The camera, if it counts: it has to be in this scene's tree.
    var activeCamera: SKCameraNode? {
        guard let camera, camera.scene === self else { return nil }
        return camera
    }

    /// Takes a point in the scene to where it is drawn, in the coordinates
    /// `visibleFrame` is given in. Identity with no camera; with one, the
    /// camera's own transform undone and its position moved to the middle of
    /// the frame. A camera's children come out of this exactly where they
    /// stand under the camera, which is why a HUD on it holds still.
    public var cameraTransform: CGAffineTransform {
        guard let camera = activeCamera else { return .identity }
        let middle = CGPoint(
            x: (0.5 - anchorPoint.x) * size.width,
            y: (0.5 - anchorPoint.y) * size.height
        )
        return camera.worldTransform.inverted()
            .concatenating(CGAffineTransform(translationX: middle.x, y: middle.y))
    }

    /// What the view shows, in scene coordinates: the box round
    /// `visibleFrame` as the camera sees it.
    var viewedRect: CGRect {
        visibleFrame.applying(cameraTransform.inverted())
    }

    /// The box round everything `node` and what it holds draw, in this
    /// scene's coordinates. Worked out here from each node's own content
    /// rather than from `calculateAccumulatedFrame()`, whose frame of
    /// reference is the shim's to settle.
    func frameInScene(of node: SKNode) -> CGRect {
        var total: CGRect?
        func visit(_ node: SKNode) {
            guard !node.isHidden else { return }
            let content = node.contentFrame
            if content != .zero {
                let placed = content.applying(node.worldTransform)
                total = total.map { $0.union(placed) } ?? placed
            }
            node.children.forEach(visit)
        }
        visit(node)
        return total ?? .null
    }

    /// A point in the view — UIKit's points, y down from the top left — to
    /// the scene.
    public func convertPoint(fromView point: CGPoint) -> CGPoint {
        let bounds = view?.bounds ?? CGRect(origin: .zero, size: size)
        let frame = visibleFrame
        guard bounds.width > 0, bounds.height > 0 else { return point }
        let across = (point.x - bounds.minX) / bounds.width
        let down = (point.y - bounds.minY) / bounds.height
        let framed = CGPoint(x: frame.minX + across * frame.width, y: frame.minY + (1 - down) * frame.height)
        return framed.applying(cameraTransform.inverted())
    }

    /// A point in the scene to the view's points.
    public func convertPoint(toView point: CGPoint) -> CGPoint {
        let bounds = view?.bounds ?? CGRect(origin: .zero, size: size)
        let frame = visibleFrame
        guard frame.width > 0, frame.height > 0 else { return point }
        let framed = point.applying(cameraTransform)
        let across = (framed.x - frame.minX) / frame.width
        let up = (framed.y - frame.minY) / frame.height
        return CGPoint(x: bounds.minX + across * bounds.width, y: bounds.minY + (1 - up) * bounds.height)
    }
}

public extension SKView {
    /// SpriteKit's `SKView.convert(_:from:)`: a point in `scene` to the
    /// view's points (y down), as `LightCanvas.pixels` asks.
    func convert(_ point: CGPoint, from scene: SKScene) -> CGPoint {
        scene.convertPoint(toView: point)
    }

    /// SpriteKit's `SKView.convert(_:to:)`: a point in the view to `scene`.
    func convert(_ point: CGPoint, to scene: SKScene) -> CGPoint {
        scene.convertPoint(fromView: point)
    }
}

#endif
