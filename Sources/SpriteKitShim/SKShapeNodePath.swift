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
}
#endif
