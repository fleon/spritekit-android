import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
import UIKit
import simd
#endif

/// `0xRRGGBB` as a colour.
public func hex(_ hex: UInt32) -> UIColor {
    UIColor(hex: hex)
}

public func hex(_ hex: UInt32, _ alpha: CGFloat) -> UIColor {
    UIColor(hex: hex, alpha: alpha)
}

/// A colour from 0–255 components.
public func rgb(_ red: Int, _ green: Int, _ blue: Int) -> UIColor {
    rgba(red, green, blue, 1)
}

/// A colour from 0–255 components and a 0–1 alpha.
public func rgba(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat) -> UIColor {
    UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
}

public func white(_ alpha: CGFloat) -> UIColor {
    UIColor(white: 1, alpha: alpha)
}

public func black(_ alpha: CGFloat) -> UIColor {
    UIColor(white: 0, alpha: alpha)
}

extension UIColor {
    public convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let red = CGFloat((hex & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((hex & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(hex & 0x0000FF) / 255.0
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// `"#RRGGBB"` or `"RRGGBB"` (a `0x` prefix and surrounding space
    /// allowed), read as far as it runs in hex digits as `Scanner` reads it;
    /// nil with none.
    public convenience init?(hex: String, alpha: CGFloat = 1.0) {
        guard let value = Self.hexValue(hex) else { return nil }
        self.init(hex: UInt32(truncatingIfNeeded: value), alpha: alpha)
    }

    nonisolated static func hexValue(_ text: String) -> UInt64? {
        let isDigit = { (c: Character) in c.isASCII && c.isHexDigit }
        var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: ""))
        // A `0x` with no digits after it reads as the 0 alone.
        if digits.lowercased().hasPrefix("0x"), digits.dropFirst(2).first.map(isDigit) == true { digits = digits.dropFirst(2) }
        let run = digits.prefix(while: isDigit)
        guard !run.isEmpty else { return nil }
        // As `scanHexInt64`, an overflowing run reads as the largest value.
        return UInt64(run, radix: 16) ?? .max
    }

    public func withOpacity(_ opacity: CGFloat) -> UIColor {
        withAlphaComponent(opacity)
    }

    /// This colour over black at `alpha`, opaque.
    public func blended(alpha: CGFloat) -> UIColor {
        blended(on: .black, alpha: alpha)
    }

    /// The opaque colour this one shows composited at `alpha` over
    /// `background`.
    public func blended(on background: UIColor, alpha: CGFloat) -> UIColor {
        var fgR: CGFloat = 0, fgG: CGFloat = 0, fgB: CGFloat = 0, fgA: CGFloat = 0
        var bgR: CGFloat = 0, bgG: CGFloat = 0, bgB: CGFloat = 0, bgA: CGFloat = 0
        getRed(&fgR, green: &fgG, blue: &fgB, alpha: &fgA)
        background.getRed(&bgR, green: &bgG, blue: &bgB, alpha: &bgA)
        let r = (fgR * alpha) + (bgR * (1 - alpha))
        let g = (fgG * alpha) + (bgG * (1 - alpha))
        let b = (fgB * alpha) + (bgB * (1 - alpha))
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Multiplies the RGB channels, like CSS `filter: brightness()`.
    public func brightness(_ factor: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: (r * factor).clamp(0, 1), green: (g * factor).clamp(0, 1), blue: (b * factor).clamp(0, 1), alpha: a)
    }

    /// The RGB components, for a shader's uniform.
    public func toVec3() -> vector_float3 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return vector_float3(Float(r), Float(g), Float(b))
    }

    /// The colour as eight hex digits, `rrggbbaa`, to key caches of what's
    /// drawn in it.
    public var cacheKey: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02x%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
    }
}
