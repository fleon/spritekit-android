#if SPRITEKIT_SHIM
import Foundation

public extension SKShapeNode {
    /// SpriteKit's `SKShapeNode(path:)`. The game mostly assigns `path`
    /// afterwards, through its own `shape(_:)` helper, but a rig's clipping
    /// mask is built this way.
    convenience init(path: CGPath) {
        self.init()
        self.path = path
    }

    /// SpriteKit's `SKShapeNode(circleOfRadius:)`, centred on the node.
    convenience init(circleOfRadius radius: CGFloat) {
        self.init()
        self.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    /// SpriteKit's `SKShapeNode(rect:)`: `BackdropNode`'s debug outlines.
    convenience init(rect: CGRect) {
        self.init()
        self.path = CGPath(rect: rect, transform: nil)
    }
}
#endif
