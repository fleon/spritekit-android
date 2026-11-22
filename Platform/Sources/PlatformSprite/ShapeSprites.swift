import Foundation
import SpriteKitShim

#if canImport(UIKit) || !canImport(Darwin)

/// Simple shapes (rings, pills, discs, outlines) drawn as sprites: white,
/// drawn once at the screen's density (`DrawnTexture.renderScale`) by
/// CoreGraphics and cached, tinted per use. Never shape nodes, but as crop
/// masks: SpriteKit draws each on its own, and Android's runtime rasterises
/// each on the CPU, again at every step of a scale animation.
public enum ShapeSprite {
    /// The cache's budget in bytes. Set it before anything is drawn.
    public nonisolated(unsafe) static var cacheBytes = 16 * 1024 * 1024 {
        didSet { cache.totalCostLimit = cacheBytes }
    }

    /// The room left round a shape for its antialiased edge, in points.
    public nonisolated(unsafe) static var room: CGFloat = 1

    /// How much thinner than asked a line is stroked, in pixels, so it shows
    /// as a shape node's does: SpriteKit's antialiasing takes a little off
    /// each side.
    public nonisolated(unsafe) static var strokeThinning: CGFloat = 0.7

    nonisolated(unsafe) private static let cache: NSCache<NSString, SKTexture> = {
        let cache = NSCache<NSString, SKTexture>()
        cache.totalCostLimit = cacheBytes
        return cache
    }()

    /// A sprite of `bounds` (in its parent's space, y up) drawing what `draw`
    /// fills or strokes there in white, with a little room round it for its
    /// antialiased edge. `key` caches the texture; `sharpness` draws it that
    /// much denser, for a sprite shown scaled up.
    public static func make(bounds: CGRect, key: String?, sharpness: CGFloat = 1, draw: (CGContext) -> Void) -> SKSpriteNode {
        let node = SKSpriteNode(texture: texture(bounds: bounds, key: key, sharpness: sharpness, draw: draw), size: canvas(bounds.size, sharpness: sharpness))
        node.position = pt(bounds.midX, bounds.midY)
        return node
    }

    /// The size of the sprite `make` shows for `size`: its room round it,
    /// rounded out to whole pixels of its texture, the shape in the middle.
    public static func canvas(_ size: CGSize, sharpness: CGFloat = 1) -> CGSize {
        let scale = DrawnTexture.renderScale * sharpness
        let room = Self.room
        return sz(((size.width + room * 2) * scale).rounded(.up) / scale, ((size.height + room * 2) * scale).rounded(.up) / scale)
    }

    /// The texture `make` shows.
    public static func texture(bounds: CGRect, key: String?, sharpness: CGFloat = 1, draw: (CGContext) -> Void) -> SKTexture {
        let scale = DrawnTexture.renderScale * sharpness
        let fullKey = key.map { "\($0)-\(scale)" as NSString }
        if let fullKey, let cached = cache.object(forKey: fullKey) { return cached }
        let canvas = canvas(bounds.size, sharpness: sharpness)
        let width = Int((canvas.width * scale).rounded()), height = Int((canvas.height * scale).rounded())
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let image: CGImage? = bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            // y up, the shape's middle on the bitmap's.
            context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.midX, y: -bounds.midY)
            context.setFillColor(UIColor.white.cgColor)
            context.setStrokeColor(UIColor.white.cgColor)
            draw(context)
            return context.makeImage()
        }
        let texture = image.map { SKTexture(cgImage: $0) } ?? SKTexture(data: Data(count: 4), size: sz(1, 1))
        texture.filteringMode = .linear
        if let fullKey { cache.setObject(texture, forKey: fullKey, cost: width * height * 4) }
        return texture
    }

    /// A filled `path`, centred where the path's bounds are.
    public static func fill(_ path: CGPath, key: String?, color: UIColor = .white) -> SKSpriteNode {
        let node = make(bounds: path.boundingBoxOfPath, key: key) { context in
            context.addPath(path)
            context.fillPath()
        }
        return tint(node, color)
    }

    /// A rounded rect (a pill when `cornerRadius` is half its height), centred on the origin.
    public static func roundedRect(_ size: CGSize, cornerRadius: CGFloat, color: UIColor = .white) -> SKSpriteNode {
        let radius = min(cornerRadius, min(size.width, size.height) / 2)
        let path = CGPath(roundedRect: rect(size).anchor(0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
        return fill(path, key: "rounded-\(size.width)x\(size.height)-\(radius)", color: color)
    }

    /// An ellipse filling `frame`.
    public static func ellipse(in frame: CGRect, color: UIColor = .white) -> SKSpriteNode {
        let node = fill(CGPath(ellipseIn: rect(frame.size).anchor(0.5), transform: nil), key: "ellipse-\(frame.width)x\(frame.height)", color: color)
        node.position = pt(frame.midX, frame.midY)
        return node
    }

    /// A disc of `radius`, centred on the origin.
    public static func disc(_ radius: CGFloat, color: UIColor = .white) -> SKSpriteNode {
        ellipse(in: rect(radius * 2).anchor(0.5), color: color)
    }

    /// A circle of `radius` stroked `width` wide, centred on the origin,
    /// drawn sharp enough to scale up to `upTo`.
    public static func ring(_ radius: CGFloat, width: CGFloat, color: UIColor = .white, upTo: CGFloat = 1) -> SKSpriteNode {
        let reach = radius + width / 2
        let node = make(bounds: rect(reach * 2).anchor(0.5), key: "ring-\(radius)-\(width)", sharpness: upTo) { context in
            context.setLineWidth(strokeWidth(width))
            context.addEllipse(in: rect(radius * 2).anchor(0.5))
            context.strokePath()
        }
        return tint(node, color)
    }

    /// `path` stroked `width` wide with butt caps and mitred joins, as a
    /// shape's stroke is by default.
    public static func stroke(_ path: CGPath, width: CGFloat, key: String?, color: UIColor = .white) -> SKSpriteNode {
        let bounds = path.boundingBoxOfPath.insetBy(dx: -width / 2, dy: -width / 2)
        let node = make(bounds: bounds, key: key) { context in
            context.setLineWidth(strokeWidth(width))
            context.addPath(path)
            context.strokePath()
        }
        return tint(node, color)
    }

    /// How wide to stroke a line `width` wide so it shows as a shape
    /// node's does: SpriteKit's antialiasing takes a little off each side.
    public static func strokeWidth(_ width: CGFloat) -> CGFloat {
        max(width - strokeThinning / DrawnTexture.renderScale, 0)
    }

    /// Tints a white sprite `color`, taking the colour's alpha as its own.
    @discardableResult
    public static func tint(_ node: SKSpriteNode, _ color: UIColor) -> SKSpriteNode {
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        node.color = UIColor(red: red, green: green, blue: blue, alpha: 1)
        node.colorBlendFactor = 1
        node.alpha = alpha
        return node
    }
}

#endif
