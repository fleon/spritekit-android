import Foundation
import PlatformSprite
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
import UIKit
#endif

/// Game Center's mark, four overlapping translucent bubbles, each a vertical
/// gradient, for a game's Game Center button where the service behind it is
/// Game Center (Apple platforms). A brand mark keeps its own colours, as
/// Play Games' does (`PlayGamesMark`), so it isn't drawn in a button's ink.
/// Each game keeps its own button and stands this on it; `GameServiceMark`
/// picks between the two.
public enum GameCenterMark {
    /// One bubble: its centre and radius on the 24-unit grid (y down), and
    /// its gradient, top to bottom, as 0–255 components at `locations`.
    public struct Bubble: Sendable {
        public let center: CGPoint
        public let radius: CGFloat
        public let colors: [(red: Int, green: Int, blue: Int)]
        public let locations: [CGFloat]
    }

    /// The grid the bubbles are drawn on: the mark's 23-unit artwork,
    /// centred, as Play Games' mark's grid, so one icon size suits both.
    public static let grid: CGFloat = 24

    /// Every bubble's opacity: where two overlap, both show.
    public static let bubbleAlpha: CGFloat = 0.8

    /// Each bubble, bottom to top.
    public static let bubbles: [Bubble] = [
        // Purple, small, bottom left.
        Bubble(center: CGPoint(x: 9.226562, y: 19.136719), radius: 4.46875,
               colors: [(155, 38, 223), (143, 48, 255)], locations: [0, 1]),
        // Yellow, top right.
        Bubble(center: CGPoint(x: 15.972656, y: 7.222656), radius: 6.886719,
               colors: [(244, 204, 1), (251, 233, 77)], locations: [0, 1]),
        // Blue, the largest, top left.
        Bubble(center: CGPoint(x: 9.703125, y: 9.808594), radius: 9.203125,
               colors: [(92, 154, 243), (107, 209, 229)], locations: [0, 1]),
        // Pink, red through magenta to orange, bottom right.
        Bubble(center: CGPoint(x: 17.367188, y: 16.566406), radius: 6.132812,
               colors: [(255, 29, 75), (255, 29, 170), (254, 153, 42)], locations: [0, 0.6, 1]),
    ]

    /// The point on the grid that stands on a button's centre: the grid's
    /// middle, as the artwork is centred on it.
    public static let centre = CGPoint(x: grid / 2, y: grid / 2)

    /// What the bubbles cover on the grid (a little past the artwork's 23
    /// units at the top and bottom).
    public static let drawnBounds: CGRect = bubbles.reduce(CGRect.null) {
        $0.union(CGRect(x: $1.center.x - $1.radius, y: $1.center.y - $1.radius, width: $1.radius * 2, height: $1.radius * 2))
    }

    /// The name the mark's sprite goes by, for a test or a capture to find.
    public static let nodeName = "gameCenterMark"

    /// The sprite's size for a mark `size` points across the grid: the
    /// bubbles' bounds at that scale.
    public static func spriteSize(size: CGFloat) -> CGSize {
        let scale = size / grid
        return CGSize(width: drawnBounds.width * scale, height: drawnBounds.height * scale)
    }

    /// The sprite's anchor that stands `centre` on its position.
    public static var anchorPoint: CGPoint {
        CGPoint(x: (centre.x - drawnBounds.minX) / drawnBounds.width, y: (drawnBounds.maxY - centre.y) / drawnBounds.height)
    }

    /// Draws the mark's bubbles filling `rect` (`drawnBounds` scaled into it)
    /// in a context whose y grows down, as UIKit's renderer hands over.
    public static func draw(in context: CGContext, rect: CGRect) {
        let scale = rect.width / drawnBounds.width
        let space = CGColorSpaceCreateDeviceRGB()
        for bubble in bubbles {
            let radius = bubble.radius * scale
            let disc = CGRect(
                x: rect.minX + (bubble.center.x - drawnBounds.minX) * scale - radius,
                y: rect.minY + (bubble.center.y - drawnBounds.minY) * scale - radius,
                width: radius * 2,
                height: radius * 2
            )
            let colors = bubble.colors.map {
                CGColor(red: CGFloat($0.red) / 255, green: CGFloat($0.green) / 255, blue: CGFloat($0.blue) / 255, alpha: 1)
            }
            guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: bubble.locations) else { continue }
            context.saveGState()
            context.setAlpha(bubbleAlpha)
            context.addEllipse(in: disc)
            context.clip()
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: disc.midX, y: disc.minY),
                end: CGPoint(x: disc.midX, y: disc.maxY),
                options: []
            )
            context.restoreGState()
        }
    }

    // Drawn through UIKit's renderer: everywhere but the Mac host the tests
    // run on, whose shim has no UIKit renderer.
    #if canImport(UIKit) || !canImport(Darwin)
    /// The mark as a texture `size` points across the grid, drawn once a
    /// size and cached.
    public static func texture(size: CGFloat) -> SKTexture {
        DrawnTexture.texture(size: spriteSize(size: size), key: "game-center-mark") { context, bounds in
            draw(in: context, rect: bounds)
        }
    }

    /// The mark as a sprite `size` points across the grid (a button's icon
    /// size), anchored at `centre`.
    public static func node(size: CGFloat) -> SKSpriteNode {
        let sprite = SKSpriteNode(texture: texture(size: size), size: spriteSize(size: size))
        sprite.anchorPoint = anchorPoint
        sprite.name = nodeName
        return sprite
    }
    #endif
}

/// The mark of the service behind a game's Game Center button where it's
/// built (`GameService.current`): Game Center's on Apple platforms, Play
/// Games' on Android. Both stand on a 24-unit grid, centred on the button.
public enum GameServiceMark {
    #if canImport(UIKit) || !canImport(Darwin)
    /// The service's mark as a sprite `size` points across its grid. With
    /// `manager`, where Play Games can't run the sprite hides its button (the
    /// first ancestor `isButton` picks, else its parent), as
    /// `PlayGamesMark.node(size:manager:isButton:)` does; Game Center's is
    /// never hidden.
    public static func node(size: CGFloat, manager: GameCenterManager? = nil, isButton: ((SKNode) -> Bool)? = nil) -> SKSpriteNode {
        switch GameService.current {
        case .gameCenter: GameCenterMark.node(size: size)
        case .playGames: PlayGamesMark.node(size: size, manager: manager, isButton: isButton)
        }
    }
    #endif

    /// The name the service's mark goes by.
    public static var nodeName: String {
        switch GameService.current {
        case .gameCenter: GameCenterMark.nodeName
        case .playGames: PlayGamesMark.nodeName
        }
    }
}
