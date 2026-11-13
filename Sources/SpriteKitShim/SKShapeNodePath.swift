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

    /// A rectangle of `size` centred on the node.
    convenience init(rectOf size: CGSize, cornerRadius: CGFloat = 0) {
        self.init(rect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                  cornerRadius: cornerRadius)
    }

    convenience init(rect: CGRect, cornerRadius: CGFloat = 0) {
        self.init()
        path = cornerRadius > 0
            ? CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            : CGPath(rect: rect, transform: nil)
    }

    convenience init(circleOfRadius radius: CGFloat) {
        self.init(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
    }

    convenience init(ellipseIn rect: CGRect) {
        self.init()
        path = CGPath(ellipseIn: rect, transform: nil)
    }

    convenience init(ellipseOf size: CGSize) {
        self.init(ellipseIn: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
    }
}
#endif
