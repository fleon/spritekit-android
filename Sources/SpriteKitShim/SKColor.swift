#if SPRITEKIT_SHIM
import Foundation

/// Stands in for UIColor. The game only ever asks a colour for its components
/// or builds one from them, so this keeps extended-range sRGB values and does
/// no colour management.
public final class SKColor: @unchecked Sendable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public convenience init(white: CGFloat, alpha: CGFloat) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    /// Hue, saturation and brightness, as UIColor takes them (all 0...1).
    public convenience init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let sector = floor(h)
        let f = h - sector
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch Int(sector) % 6 {
        case 0: rgb = (brightness, t, p)
        case 1: rgb = (q, brightness, p)
        case 2: rgb = (p, brightness, t)
        case 3: rgb = (p, q, brightness)
        case 4: rgb = (t, p, brightness)
        default: rgb = (brightness, p, q)
        }
        self.init(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
    }

    public func withAlphaComponent(_ alpha: CGFloat) -> SKColor {
        SKColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Mirrors UIColor's getter, which reports success for any colour this
    /// type can hold.
    @discardableResult
    public func getRed(
        _ red: UnsafeMutablePointer<CGFloat>?,
        green: UnsafeMutablePointer<CGFloat>?,
        blue: UnsafeMutablePointer<CGFloat>?,
        alpha: UnsafeMutablePointer<CGFloat>?
    ) -> Bool {
        red?.pointee = self.red
        green?.pointee = self.green
        blue?.pointee = self.blue
        alpha?.pointee = self.alpha
        return true
    }

    public static let white = SKColor(white: 1, alpha: 1)
    public static let black = SKColor(white: 0, alpha: 1)
    public static let clear = SKColor(white: 0, alpha: 0)
    public static let red = SKColor(red: 1, green: 0, blue: 0, alpha: 1)
    public static let green = SKColor(red: 0, green: 1, blue: 0, alpha: 1)
    public static let blue = SKColor(red: 0, green: 0, blue: 1, alpha: 1)
}

/// UIColor is an `NSObject`, equal and hashed by its components.
extension SKColor: Hashable {
    public static func == (a: SKColor, b: SKColor) -> Bool {
        a.red == b.red && a.green == b.green && a.blue == b.blue && a.alpha == b.alpha
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(red)
        hasher.combine(green)
        hasher.combine(blue)
        hasher.combine(alpha)
    }
}

public typealias UIColor = SKColor

public enum SKBlendMode: Int, Sendable {
    case alpha, add, subtract, multiply, multiplyX2, screen, replace, multiplyAlpha
}

#endif
