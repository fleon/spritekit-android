import Foundation
import SpriteKitShim

/// Where the player last touched, or the control they last pressed without
/// a touch (the remote, a gamepad, a keyboard shortcut), in window points.
/// Panels may zoom out of it and back into it.
public enum TouchOrigin {
    private static var windowPoint: CGPoint?

    public static func record(_ point: CGPoint) {
        windowPoint = point
    }

    public static func record(_ node: SKNode) {
        guard let scene = node.scene, let view = scene.view, let parent = node.parent else { return }
        let inScene = parent === scene ? node.position : scene.convert(node.position, from: parent)
        windowPoint = view.convert(scene.convertPoint(toView: inScene), to: nil)
    }

    /// The point in `node`'s space, if anything was touched yet.
    public static func location(in node: SKNode) -> CGPoint? {
        guard let windowPoint, let scene = node.scene, let view = scene.view else { return nil }
        let inScene = scene.convertPoint(fromView: view.convert(windowPoint, from: nil))
        return node === scene ? inScene : node.convert(inScene, from: scene)
    }
}

/// Notes every touch in `TouchOrigin` before the scene sees it.
open class TouchOriginWindow: UIWindow {
    override open func sendEvent(_ event: UIEvent) {
        if event.type == .touches,
           let touch = event.allTouches?.first(where: { $0.phase == .began || $0.phase == .ended }) {
            TouchOrigin.record(touch.location(in: nil))
        }
        super.sendEvent(event)
    }
}
