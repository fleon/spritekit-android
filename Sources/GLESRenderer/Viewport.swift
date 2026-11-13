import Foundation
import SpriteKitShim

/// Maps scene points to clip space.
///
/// The game already decides its own scene size — `DesignSystem.sceneSize(for:)`
/// gives the view's size on a wide canvas so aspect fill draws the design 1:1
/// and a design point is a point, and that file cross-compiles for Android
/// unchanged. So nothing here re-derives layout; this is only the projection
/// and the points-to-pixels scale the GL viewport needs.
///
/// SpriteKit's scene coordinates are y-up with the origin at the scene's
/// `anchorPoint` (the default `.zero` puts it bottom-left), which is also
/// GL's convention — so unlike a port to a y-down 2D API, nothing is flipped.
public struct Viewport: Equatable {
    /// The drawable, in pixels.
    public let drawableSize: CGSize
    /// The scene, in points.
    public let sceneSize: CGSize
    public let scaleMode: SKSceneScaleMode
    public let anchorPoint: CGPoint

    public init(
        drawableSize: CGSize,
        sceneSize: CGSize,
        scaleMode: SKSceneScaleMode = .aspectFill,
        anchorPoint: CGPoint = .zero
    ) {
        self.drawableSize = drawableSize
        self.sceneSize = sceneSize
        self.scaleMode = scaleMode
        self.anchorPoint = anchorPoint
    }

    /// Pixels per point. Uniform for every mode but `.fill`, which may
    /// stretch the axes differently.
    public var scale: CGPoint {
        guard sceneSize.width > 0, sceneSize.height > 0,
              drawableSize.width > 0, drawableSize.height > 0
        else { return CGPoint(x: 1, y: 1) }

        let sx = drawableSize.width / sceneSize.width
        let sy = drawableSize.height / sceneSize.height

        switch scaleMode {
        case .fill, .resizeFill:
            return CGPoint(x: sx, y: sy)
        case .aspectFill:
            let s = max(sx, sy)
            return CGPoint(x: s, y: s)
        case .aspectFit:
            let s = min(sx, sy)
            return CGPoint(x: s, y: s)
        }
    }

    /// The scene rectangle the drawable shows. Under aspect fill this is
    /// larger than the drawable in one axis — the part that spills off — and
    /// under aspect fit it is the whole scene inside letterboxing.
    public var visibleSceneRect: CGRect {
        let scale = self.scale
        guard scale.x > 0, scale.y > 0 else { return CGRect(origin: .zero, size: sceneSize) }
        let width = drawableSize.width / scale.x
        let height = drawableSize.height / scale.y
        // The scene's origin sits at its anchor point, and the extra width or
        // height is shared evenly either side.
        let originX = -anchorPoint.x * sceneSize.width - (width - sceneSize.width) / 2
        let originY = -anchorPoint.y * sceneSize.height - (height - sceneSize.height) / 2
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Column-major 4x4, as GL wants it: scene points in, clip space out.
    public var projection: [Float] {
        let rect = visibleSceneRect
        guard rect.width > 0, rect.height > 0 else { return Self.identity }

        let sx = 2 / Float(rect.width)
        let sy = 2 / Float(rect.height)
        let tx = -1 - Float(rect.minX) * sx
        let ty = -1 - Float(rect.minY) * sy

        return [
            sx, 0, 0, 0,
            0, sy, 0, 0,
            0, 0, -1, 0,
            tx, ty, 0, 1,
        ]
    }

    /// Where a scene point lands in clip space. Used by the tests, and handy
    /// when chasing a quad that is off screen.
    public func clipPosition(of point: CGPoint) -> (x: Float, y: Float) {
        let m = projection
        return (
            m[0] * Float(point.x) + m[12],
            m[5] * Float(point.y) + m[13]
        )
    }

    static let identity: [Float] = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ]
}
