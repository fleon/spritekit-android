import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
import UIKit
#endif

/// One piece of an icon, as SVG path data on the icon's grid (y down from
/// the top left).
public enum IconPart: Equatable, Sendable {
    /// Path data stroked `width` units wide, with round caps and joins.
    case stroke(String, width: CGFloat)
    /// Path data filled; where its subpaths overlap, they cut holes.
    case fill(String)

    /// What it covers on the grid.
    public var bounds: CGRect {
        switch self {
        case let .stroke(data, width):
            // Round joins never miter, so the limit plays no part.
            let outline = SVGPath.path(data).copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 0)
            return outline.boundingBoxOfPath
        case let .fill(data):
            return SVGPath.path(data).boundingBoxOfPath
        }
    }
}

/// A game's icon set: each icon's parts on a square grid, drawn once a size
/// and colour into cached textures (`DrawnTexture`). A game's own enum of
/// icons adopts it and lists their parts; `node(size:color:)` and
/// `draw(in:size:color:center:)` come with it.
public protocol IconDrawing {
    /// The icon's pieces, in grid units.
    var parts: [IconPart] { get }
    /// Names the icon in its textures' cache keys, unique in the set.
    var iconKey: String { get }
    /// The side of the grid the parts are drawn on.
    static var grid: CGFloat { get }
}

extension IconDrawing {
    public static var grid: CGFloat { 24 }
    public var iconKey: String { String(describing: self) }
}

#if canImport(UIKit) || !canImport(Darwin)

extension IconDrawing {
    /// The icon on a grid `size` points across, centred on the origin. The
    /// sprite covers only what the icon draws, as a shape node's frame would.
    /// Drawn white once a size and tinted, so a new ink draws nothing; a
    /// translucent colour, which a tint can't carry, is drawn in.
    public func node(size: CGFloat, color: UIColor) -> SKSpriteNode {
        let grid = Self.grid
        let scale = size / grid
        let drawn = parts.reduce(CGRect.null) { $0.union($1.bounds) }
        let spriteSize = sz(drawn.width * scale, drawn.height * scale)
        let opaque = color.cgColor.alpha >= 1
        let ink = opaque ? UIColor.white : color
        let texture = DrawnTexture.texture(size: spriteSize, key: "icon-\(iconKey)-\(ink.cacheKey)") { context, bounds in
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -drawn.minX, y: -drawn.minY)
            drawParts(in: context, color: ink)
        }
        let sprite = SKSpriteNode(texture: texture, size: spriteSize)
        if opaque {
            sprite.color = color
            sprite.colorBlendFactor = 1
        }
        // The grid's centre stays on the origin; the sprite's y runs up.
        let middle = grid / 2
        sprite.anchorPoint = pt((middle - drawn.minX) / drawn.width, (drawn.maxY - middle) / drawn.height)
        return sprite
    }

    /// Draws the icon into `context` (y down) on a grid `size` points across
    /// centred on `center`, to bake it into a bigger picture.
    public func draw(in context: CGContext, size: CGFloat, color: UIColor, center: CGPoint) {
        let scale = size / Self.grid
        context.saveGState()
        context.translateBy(x: center.x - size / 2, y: center.y - size / 2)
        context.scaleBy(x: scale, y: scale)
        drawParts(in: context, color: color)
        context.restoreGState()
    }

    /// The path data in grid units, y down from the top left, like the context.
    private func drawParts(in context: CGContext, color: UIColor) {
        context.setFillColor(color.cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for part in parts {
            switch part {
            case let .stroke(data, width):
                context.setLineWidth(width)
                context.addPath(SVGPath.path(data))
                context.strokePath()
            case let .fill(data):
                context.addPath(SVGPath.path(data))
                context.fillPath(using: .evenOdd)
            }
        }
    }
}

#endif
