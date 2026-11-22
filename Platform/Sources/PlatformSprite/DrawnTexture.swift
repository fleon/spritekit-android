import Foundation
import SpriteKitShim

// Drawn in UIKit's renderer, whose context the Mac host's shim hands over as
// its own bitmap context rather than CoreGraphics': everywhere but there.
#if canImport(UIKit) || !canImport(Darwin)

/// Textures drawn in code (with CoreGraphics on Apple, the shim's bitmap
/// context on Android) at the screen's density, cached by key and priced by
/// their pixels up to a budget, so what's drawn once a size and colour is
/// drawn only once. What a sprite still shows stays with it.
public enum DrawnTexture {
    /// The cache's budget in bytes. Set it before anything is drawn.
    public nonisolated(unsafe) static var cacheBytes = 48 * 1024 * 1024 {
        didSet { cache.totalCostLimit = cacheBytes }
    }

    /// The fewest pixels a point is drawn with, however low the screen's
    /// density: textures shown scaled up stay sharp enough.
    public nonisolated(unsafe) static var minimumScale: CGFloat = 2

    nonisolated(unsafe) private static let cache: NSCache<NSString, SKTexture> = {
        let cache = NSCache<NSString, SKTexture>()
        cache.totalCostLimit = cacheBytes
        return cache
    }()

    /// Pixels per point textures are drawn at.
    public static var renderScale: CGFloat {
        max(UITraitCollection.current.displayScale, minimumScale)
    }

    /// Renders `draw` into a texture of `size` plus `padding` on every side.
    /// The closure receives the content rect (in UIKit coordinates, y down).
    /// `key` caches it (with its size and padding); `data`: what it draws
    /// are values (a normal map), kept in the standard range so no wider
    /// colour space shifts them.
    public static func texture(
        size: CGSize,
        padding: CGFloat = 0,
        scale: CGFloat? = nil,
        key: String? = nil,
        data: Bool = false,
        draw: (CGContext, CGRect) -> Void
    ) -> SKTexture {
        let fullKey = key.map { "\($0)-\(size.width)x\(size.height)-\(padding)" }
        if let fullKey, let cached = cache.object(forKey: fullKey as NSString) { return cached }
        let canvas = sz(size.width + padding * 2, size.height + padding * 2)
        let renderScale = scale ?? renderScale
        let image = image(size: size, padding: padding, scale: renderScale, standardRange: data, draw: draw)
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        if let fullKey {
            let pixels = canvas.width * renderScale * canvas.height * renderScale
            cache.setObject(texture, forKey: fullKey as NSString, cost: Int(pixels) * 4)
        }
        return texture
    }

    /// `draw` rendered into an image of `size` plus `padding` on every side.
    public static func image(size: CGSize, padding: CGFloat, scale: CGFloat, standardRange: Bool = false, draw: (CGContext, CGRect) -> Void) -> UIImage {
        let canvas = sz(size.width + padding * 2, size.height + padding * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        if standardRange { format.preferredRange = .standard }
        return UIGraphicsImageRenderer(size: canvas, format: format).image { renderer in
            draw(renderer.cgContext, rect(padding, padding, size.width, size.height))
        }
    }

    /// Forgets every texture drawn (they stay with the sprites showing them).
    public static func clear() {
        cache.removeAllObjects()
    }
}

#endif
