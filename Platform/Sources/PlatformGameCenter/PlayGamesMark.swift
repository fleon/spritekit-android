import Foundation
import PlatformSprite
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
import UIKit
#endif

/// Google Play Games' mark, a play triangle holding a gamepad, for a game's
/// Game Center button where the service behind it is Play Games (Android).
/// A brand mark keeps its own colours, as Game Center's does, so it isn't
/// drawn in a button's ink. Each game keeps its own button and stands this
/// on it.
public enum PlayGamesMark {
    /// One filled shape of the mark, on its 24-unit grid (SVG's y down), and
    /// its colour as 0–255 components.
    public struct Part: Sendable {
        public let path: String
        public let red: Int, green: Int, blue: Int
    }

    /// The grid the path data is drawn on.
    public static let grid: CGFloat = 24

    /// The play triangle, with rounded corners.
    static let triangle =
        "M0.0195312 23.117188V2.882812C0.0195312 0.667969 2.488281 -0.71875 4.464844 0.390625L22.5 10.507812"
        + "C24.472656 11.617188 24.472656 14.382812 22.5 15.492188L4.464844 25.609375"
        + "C2.488281 26.71875 0.0195312 25.332031 0.0195312 23.117188Z"
    /// The gamepad, cut into the triangle's left side.
    static let gamepad =
        "M12.933594 11.492188C12.535156 9.230469 10.515625 7.585938 8.15625 7.585938H0.0195312V18.414062"
        + "H5.804688L10.011719 22.5L14.46875 20Z"
    /// Its four buttons.
    static let buttons = SVGPath.circle(5.792969, 10.410156, 1.394531) + SVGPath.circle(3.128906, 12.996094, 1.394531)
        + SVGPath.circle(5.792969, 15.589844, 1.394531) + SVGPath.circle(8.492188, 12.996094, 1.394531)

    /// Each part, bottom to top, in the mark's two greens.
    public static let parts: [Part] = [
        Part(path: triangle, red: 26, green: 128, blue: 57),
        Part(path: gamepad, red: 148, green: 254, blue: 214),
        Part(path: buttons, red: 26, green: 128, blue: 57),
    ]

    /// The point on the grid that stands on a button's centre: the
    /// triangle's own centre (its sides' lines meet at (0, -2.1), (0, 28.1)
    /// and (26.9, 13), whose centroid is a third of the way to the tip), not
    /// its box's middle, which would sit it left of the button's centre.
    public static let centre = CGPoint(x: 9, y: 13)

    /// The name the mark's sprite goes by, for a test or a capture to find.
    public static let nodeName = "playGamesMark"

    /// Where Play Games can't run (no Google Play services, or a build
    /// without Play Games), the button that offers it isn't shown: its
    /// dashboard is what it opens, and there is none. Game Center's button
    /// on Apple platforms is never hidden by this.
    public static func hidesButton(for manager: GameCenterManager) -> Bool {
        #if SPRITEKIT_SHIM
        !manager.hasDashboard
        #else
        false
        #endif
    }

    // Drawn through UIKit's renderer: everywhere but the Mac host the tests
    // run on, whose shim has no UIKit renderer.
    #if canImport(UIKit) || !canImport(Darwin)
    /// The mark as a sprite `size` points across the grid (a button's icon
    /// size), anchored at `centre`. With `manager`, where Play Games can't
    /// run the sprite hides the button it stands on (the first ancestor
    /// `isButton` picks, else its parent) the first time it runs, before a
    /// frame of it is drawn.
    public static func node(size: CGFloat, manager: GameCenterManager? = nil, isButton: ((SKNode) -> Bool)? = nil) -> SKSpriteNode {
        let scale = size / grid
        let paths = parts.map { (SVGPath.path($0.path), UIColor(red: CGFloat($0.red) / 255, green: CGFloat($0.green) / 255, blue: CGFloat($0.blue) / 255, alpha: 1)) }
        let drawn = paths.reduce(CGRect.null) { $0.union($1.0.boundingBoxOfPath) }
        let spriteSize = CGSize(width: drawn.width * scale, height: drawn.height * scale)
        let texture = DrawnTexture.texture(size: spriteSize, key: "play-games-mark") { context, bounds in
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -drawn.minX, y: -drawn.minY)
            for (path, color) in paths {
                context.setFillColor(color.cgColor)
                context.addPath(path)
                context.fillPath()
            }
        }
        let sprite = SKSpriteNode(texture: texture, size: spriteSize)
        sprite.anchorPoint = CGPoint(x: (centre.x - drawn.minX) / drawn.width, y: (drawn.maxY - centre.y) / drawn.height)
        sprite.name = nodeName
        if let manager, hidesButton(for: manager) {
            sprite.run(.run { [weak sprite] in
                var node = sprite?.parent
                if let isButton {
                    while let current = node, !isButton(current) { node = current.parent }
                }
                node?.isHidden = true
            })
        }
        return sprite
    }
    #endif
}
