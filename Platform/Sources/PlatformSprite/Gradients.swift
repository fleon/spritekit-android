import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
import UIKit
#endif

/// A colour at a place along a gradient, from 0 (its start) to 1 (its end).
public struct GradientStop {
    public let position: CGFloat
    public let color: UIColor

    public init(_ position: CGFloat, _ color: UIColor) {
        self.position = position
        self.color = color
    }

    /// Names the stop in a texture's cache key.
    public var cacheKey: String {
        String(format: "%@@%.4f", color.cacheKey, Double(position))
    }
}

extension Array where Element == GradientStop {
    /// Names the stops in a texture's cache key.
    public var cacheKey: String { map(\.cacheKey).joined(separator: ";") }
}

#if canImport(UIKit) || !canImport(Darwin)

extension DrawnTexture {
    /// A linear gradient through `stops` from `start` to `end`, filling a
    /// texture of `size`. Points are in the texture's own points, y down
    /// from its top-left corner; colour carries on past both ends. Cached
    /// by everything it draws.
    public static func linearGradient(
        size: CGSize,
        stops: [GradientStop],
        start: CGPoint,
        end: CGPoint,
        scale: CGFloat? = nil
    ) -> SKTexture {
        let key = "linear-gradient-\(stops.cacheKey)-\(start.x),\(start.y)-\(end.x),\(end.y)-\(scale.map { "\($0)" } ?? "")"
        return texture(size: size, scale: scale, key: key) { context, bounds in
            guard let gradient = cgGradient(stops) else { return }
            context.drawLinearGradient(
                gradient,
                start: pt(bounds.minX + start.x, bounds.minY + start.y),
                end: pt(bounds.minX + end.x, bounds.minY + end.y),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }

    /// Two colours across a texture of `size`: left to right, or top to
    /// bottom when `vertical`.
    public static func linearGradient(
        size: CGSize,
        from start: UIColor,
        to end: UIColor,
        vertical: Bool = false,
        scale: CGFloat? = nil
    ) -> SKTexture {
        linearGradient(
            size: size,
            stops: [GradientStop(0, start), GradientStop(1, end)],
            start: .zero,
            end: vertical ? pt(0, size.height) : pt(size.width, 0),
            scale: scale
        )
    }

    /// A radial gradient through `stops`, from `center` (the texture's
    /// middle unless given) out to `radius` (half its width unless given),
    /// stretched vertically by `aspectRatio` (above 1, a tall ellipse).
    /// Points are y down from the texture's top-left corner; the last
    /// stop's colour fills what lies beyond. Cached by everything it draws.
    public static func radialGradient(
        size: CGSize,
        stops: [GradientStop],
        center: CGPoint? = nil,
        radius: CGFloat? = nil,
        aspectRatio: CGFloat = 1,
        scale: CGFloat? = nil
    ) -> SKTexture {
        let center = center ?? pt(size.width / 2, size.height / 2)
        let radius = radius ?? size.width / 2
        let key = "radial-gradient-\(stops.cacheKey)-\(center.x),\(center.y)-\(radius)-\(aspectRatio)-\(scale.map { "\($0)" } ?? "")"
        return texture(size: size, scale: scale, key: key) { context, bounds in
            guard let gradient = cgGradient(stops), radius > 0 else { return }
            context.saveGState()
            context.translateBy(x: bounds.minX + center.x, y: bounds.minY + center.y)
            context.scaleBy(x: 1, y: aspectRatio)
            context.drawRadialGradient(
                gradient,
                startCenter: .zero,
                startRadius: 0,
                endCenter: .zero,
                endRadius: radius,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            context.restoreGState()
        }
    }

    /// A glow: `color`, opaque at the middle of a disc `diameter` across,
    /// fading to clear at its edge.
    public static func radialGradient(diameter: CGFloat, color: UIColor, scale: CGFloat? = nil) -> SKTexture {
        radialGradient(
            size: sz(diameter, diameter),
            stops: [GradientStop(0, color.withAlphaComponent(1)), GradientStop(1, color.withAlphaComponent(0))],
            scale: scale
        )
    }

    private static func cgGradient(_ stops: [GradientStop]) -> CGGradient? {
        guard !stops.isEmpty else { return nil }
        let colors = stops.map(\.color.cgColor) as CFArray
        let locations = stops.map(\.position)
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations)
    }
}

#endif
