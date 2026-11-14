import SpriteKit
import UIKit

/// `Source/Common/Components/GameCenterIcon.swift` on Android: the title's
/// Game Center button is Play Games' (`GameCenterManager`), so it wears Play
/// Games' mark instead of Game Center's circles.
///
/// The mark is Google Play Games' logo, a play triangle holding a gamepad,
/// as Huerings draws it on its Play Games button (its Axmol app's
/// `PlayGamesIconNode`): its 24-unit path data and its two greens, copied
/// in. A brand mark keeps its own colours, as Game Center's does, so it isn't
/// drawn in the button's ink; it stands on the icons' grid, as big as the
/// other corner buttons' icons (`DesignSystem.iconSize` across).
///
/// Where Play Games can't run (no Google Play services, or a build without
/// Play Games), the button isn't shown: its icon hides it as soon as the
/// scene first runs it, before a frame of it is drawn. The game always shows
/// the button, so this is the one place the port can decide.
enum GameCenterIcon {
    /// The play triangle, with rounded corners.
    private static let triangle =
        "M0.0195312 23.117188V2.882812C0.0195312 0.667969 2.488281 -0.71875 4.464844 0.390625L22.5 10.507812"
        + "C24.472656 11.617188 24.472656 14.382812 22.5 15.492188L4.464844 25.609375"
        + "C2.488281 26.71875 0.0195312 25.332031 0.0195312 23.117188Z"
    /// The gamepad, cut into the triangle's left side.
    private static let gamepad =
        "M12.933594 11.492188C12.535156 9.230469 10.515625 7.585938 8.15625 7.585938H0.0195312V18.414062"
        + "H5.804688L10.011719 22.5L14.46875 20Z"
    /// Its four buttons.
    private static let buttons = SVGPath.circle(5.792969, 10.410156, 1.394531) + SVGPath.circle(3.128906, 12.996094, 1.394531)
        + SVGPath.circle(5.792969, 15.589844, 1.394531) + SVGPath.circle(8.492188, 12.996094, 1.394531)

    /// Huerings' greens.
    private static let darkGreen = UIColor(red: 26 / 255, green: 128 / 255, blue: 57 / 255, alpha: 1)
    private static let lightGreen = UIColor(red: 148 / 255, green: 254 / 255, blue: 214 / 255, alpha: 1)
    /// Each part, bottom to top, with its colour.
    private static let parts: [(path: String, color: UIColor)] = [
        (triangle, darkGreen),
        (gamepad, lightGreen),
        (buttons, darkGreen),
    ]

    private static let grid: CGFloat = 24
    /// The point on the grid that stands on the button's centre: the
    /// triangle's own centre, as an equilateral triangle is centred (its
    /// sides' lines meet at (0, -2.1), (0, 28.1) and (26.9, 13), whose
    /// centroid is a third of the way to the tip), not its box's middle,
    /// which would sit it left of the button's centre.
    private static let middle = pt(9, 13)
    /// What the sprite's name says, so a test or a capture can find it.
    static let nodeName = "playGamesIcon"

    /// The mark centred on the button. `size` is what fits Game Center's
    /// circles; this mark takes the icons' size instead.
    static func node(size _: CGFloat) -> SKSpriteNode {
        let scale = DesignSystem.iconSize / grid
        let paths = parts.map { (SVGPath.path($0.path), $0.color) }
        let drawn = paths.reduce(CGRect.null) { $0.union($1.0.boundingBoxOfPath) }
        let spriteSize = sz(drawn.width * scale, drawn.height * scale)
        let texture = SurfaceTexture.texture(size: spriteSize, key: "play-games-icon") { context, bounds in
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
        sprite.anchorPoint = pt((middle.x - drawn.minX) / drawn.width, (drawn.maxY - middle.y) / drawn.height)
        sprite.name = nodeName
        if !GameCenterManager.shared.hasDashboard {
            sprite.run(.run { [weak sprite] in hideButton(holding: sprite) })
        }
        return sprite
    }

    /// Hides the button the icon stands on.
    private static func hideButton(holding icon: SKNode?) {
        var node = icon?.parent
        while let current = node, !(current is IconButtonNode) { node = current.parent }
        node?.isHidden = true
    }
}
