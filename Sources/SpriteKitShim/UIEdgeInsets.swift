#if SPRITEKIT_SHIM
import Foundation

/// UIKit's edge insets, which a game reads for every 9-sliced image. The
/// shim vends them because on Android no system UIKit does, and game code
/// (generated or not) names the type directly.
public struct UIEdgeInsets: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = UIEdgeInsets()
}

public extension CGRect {
    /// The rect with each edge moved inward by its inset, as UIKit's
    /// `inset(by:)` does.
    func inset(by insets: UIEdgeInsets) -> CGRect {
        CGRect(
            x: minX + insets.left,
            y: minY + insets.top,
            width: width - insets.left - insets.right,
            height: height - insets.top - insets.bottom
        )
    }
}

#endif
