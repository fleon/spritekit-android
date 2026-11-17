#if SPRITEKIT_SHIM
import Foundation

public extension SKNode {
    /// Moves the node to a new parent, keeping where it stands — what
    /// a skeletal rig uses to put a slot's parts inside the crop node of the
    /// clipping attachment that masks them.
    ///
    /// SpriteKit's own keeps the node where it is by converting through both
    /// parents, and so does this: the node's own origin, expressed in the new
    /// parent's space, is the position it should take there.
    func move(toParent parent: SKNode) {
        guard self.parent !== parent else { return }
        let at = convert(CGPoint.zero, to: parent)
        removeFromParent()
        parent.addChild(self)
        position = at
    }
}
#endif
