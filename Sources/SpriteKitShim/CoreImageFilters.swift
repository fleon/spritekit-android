#if SPRITEKIT_SHIM
import Foundation

// Core Image's filters by name: gradient textures (`CILinearGradient`,
// `CIRadialGradient`, read back through a `CIContext`) and the blur a game
// may hang on an `SKEffectNode` (`CIGaussianBlur`). Measured
// against Core Image on a Mac (macOS 27.2) and pinned in `CoreImageTests`:
//
// - Gradients mix premultiplied colour in linear light and encode it to
//   sRGB as they're written: black to white is 188 half way, not 128, and a
//   colour fading to clear keeps its hue all the way out (red to clear blue
//   has no blue in it).
// - A pixel takes the colour at its centre; past either end of a linear
//   gradient, or inside `inputRadius0` and outside `inputRadius1`, the end
//   colour holds. A zero-length linear gradient is `inputColor0`
//   everywhere; a radial one whose radii are the wrong way round runs from
//   `inputColor1` inside to `inputColor0` outside.
// - Generators are infinite, but for a radial gradient that ends clear,
//   whose extent is its outer circle's box.
// - `CIGaussianBlur`'s `inputRadius` is `applyingGaussianBlur(sigma:)`'s
//   sigma, and its default 10.

/// A Core Image colour: sRGB components, as `CIColor(color:)` takes a
/// UIColor's.
public final class CIColor: @unchecked Sendable {
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

    public convenience init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }

    public convenience init(color: UIColor) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    #if !canImport(Darwin)
    /// `CGColor` is the shim's colour here (the host's is CoreGraphics').
    public convenience init(cgColor: CGColor) {
        self.init(color: cgColor)
    }
    #endif

    public var numberOfComponents: Int { 4 }

    public static let black = CIColor(red: 0, green: 0, blue: 0)
    public static let white = CIColor(red: 1, green: 1, blue: 1)
    public static let gray = CIColor(red: 0.5, green: 0.5, blue: 0.5)
    public static let red = CIColor(red: 1, green: 0, blue: 0)
    public static let green = CIColor(red: 0, green: 1, blue: 0)
    public static let blue = CIColor(red: 0, green: 0, blue: 1)
    public static let cyan = CIColor(red: 0, green: 1, blue: 1)
    public static let magenta = CIColor(red: 1, green: 0, blue: 1)
    public static let yellow = CIColor(red: 1, green: 1, blue: 0)
    public static let clear = CIColor(red: 0, green: 0, blue: 0, alpha: 0)

    /// Premultiplied, in linear light: what Core Image mixes.
    var linearPremultiplied: SIMD4<Float> {
        let a = Float(alpha)
        return SIMD4(CIImage.linear(Float(red)) * a, CIImage.linear(Float(green)) * a,
                     CIImage.linear(Float(blue)) * a, a)
    }
}

/// A Core Image vector: a point, a rectangle or up to any number of values.
public final class CIVector: @unchecked Sendable {
    private let values: [CGFloat]

    init(_ values: [CGFloat]) { self.values = values }

    public convenience init(values: UnsafePointer<CGFloat>, count: Int) {
        self.init(Array(UnsafeBufferPointer(start: values, count: count)))
    }

    public convenience init(x: CGFloat) { self.init([x]) }
    public convenience init(x: CGFloat, y: CGFloat) { self.init([x, y]) }
    public convenience init(x: CGFloat, y: CGFloat, z: CGFloat) { self.init([x, y, z]) }
    public convenience init(x: CGFloat, y: CGFloat, z: CGFloat, w: CGFloat) { self.init([x, y, z, w]) }
    public convenience init(cgPoint p: CGPoint) { self.init([p.x, p.y]) }
    public convenience init(cgRect r: CGRect) { self.init([r.origin.x, r.origin.y, r.width, r.height]) }

    public var count: Int { values.count }
    /// Zero past the end, as Core Image's.
    public func value(at index: Int) -> CGFloat { index < values.count ? values[index] : 0 }
    public var x: CGFloat { value(at: 0) }
    public var y: CGFloat { value(at: 1) }
    public var z: CGFloat { value(at: 2) }
    public var w: CGFloat { value(at: 3) }
    public var cgPointValue: CGPoint { CGPoint(x: x, y: y) }
    public var cgRectValue: CGRect { CGRect(x: x, y: y, width: z, height: w) }
}

public let kCIInputImageKey = "inputImage"
public let kCIInputRadiusKey = "inputRadius"
public let kCIInputCenterKey = "inputCenter"
public let kCIInputColorKey = "inputColor"
public let kCIInputIntensityKey = "inputIntensity"
public let kCIInputScaleKey = "inputScale"
public let kCIInputAngleKey = "inputAngle"
public let kCIInputExtentKey = "inputExtent"
public let kCIOutputImageKey = "outputImage"

/// A Core Image filter by name: `CILinearGradient`, `CIRadialGradient` and
/// `CIGaussianBlur`, with Core Image's own input keys and defaults. Any
/// other name makes nil, as Core Image does for a name it doesn't know.
open class CIFilter: @unchecked Sendable {
    enum Kind: String {
        case linearGradient = "CILinearGradient"
        case radialGradient = "CIRadialGradient"
        case gaussianBlur = "CIGaussianBlur"
    }

    let kind: Kind
    private var inputs: [String: Any] = [:]

    public init?(name: String) {
        guard let kind = Kind(rawValue: name) else { return nil }
        self.kind = kind
        self.name = name
        setDefaults()
    }

    public convenience init?(name: String, parameters: [String: Any]?) {
        self.init(name: name)
        for (key, value) in parameters ?? [:] { setValue(value, forKey: key) }
    }

    /// The filter's name: its kind's until set (Core Image lets a filter be
    /// renamed, and keeps doing what it did).
    open var name: String

    open var inputKeys: [String] {
        switch kind {
        case .linearGradient: return ["inputPoint0", "inputPoint1", "inputColor0", "inputColor1"]
        case .radialGradient: return ["inputCenter", "inputRadius0", "inputRadius1", "inputColor0", "inputColor1"]
        case .gaussianBlur: return [kCIInputImageKey, kCIInputRadiusKey]
        }
    }

    open var outputKeys: [String] { [kCIOutputImageKey] }

    /// Core Image's defaults for each input.
    open func setDefaults() {
        switch kind {
        case .linearGradient:
            inputs = ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 200, y: 200),
                      "inputColor0": CIColor.white, "inputColor1": CIColor.black]
        case .radialGradient:
            inputs = ["inputCenter": CIVector(x: 150, y: 150), "inputRadius0": CGFloat(5), "inputRadius1": CGFloat(100),
                      "inputColor0": CIColor.white, "inputColor1": CIColor.black]
        case .gaussianBlur:
            inputs = [kCIInputRadiusKey: CGFloat(10)]
        }
    }

    open func setValue(_ value: Any?, forKey key: String) {
        inputs[key] = value
    }

    open func value(forKey key: String) -> Any? {
        key == kCIOutputImageKey ? outputImage : inputs[key]
    }

    open var outputImage: CIImage? {
        switch kind {
        case .linearGradient:
            guard let p0 = vector("inputPoint0"), let p1 = vector("inputPoint1"),
                  let c0 = color("inputColor0"), let c1 = color("inputColor1") else { return nil }
            return Self.linearGradient(from: p0.cgPointValue, to: p1.cgPointValue, c0, c1)
        case .radialGradient:
            guard let center = vector("inputCenter"), let r0 = number("inputRadius0"), let r1 = number("inputRadius1"),
                  let c0 = color("inputColor0"), let c1 = color("inputColor1") else { return nil }
            return Self.radialGradient(center: center.cgPointValue, r0: r0, r1: r1, c0, c1)
        case .gaussianBlur:
            guard let image = inputs[kCIInputImageKey] as? CIImage else { return nil }
            return image.applyingGaussianBlur(sigma: Double(number(kCIInputRadiusKey) ?? 10))
        }
    }

    /// The blur's sigma, if this is a Gaussian blur: what an effect node
    /// carrying it hands the renderer.
    package var gaussianBlurRadius: CGFloat? {
        kind == .gaussianBlur ? max(0, number(kCIInputRadiusKey) ?? 10) : nil
    }

    // MARK: Inputs as Core Image takes them (NSNumber, CGFloat, Double, Int…)

    private func vector(_ key: String) -> CIVector? { inputs[key] as? CIVector }
    private func color(_ key: String) -> CIColor? { inputs[key] as? CIColor }

    private func number(_ key: String) -> CGFloat? {
        switch inputs[key] {
        case let value as CGFloat: return value
        case let value as Double: return CGFloat(value)
        case let value as Float: return CGFloat(value)
        case let value as Int: return CGFloat(value)
        case let value as NSNumber: return CGFloat(value.doubleValue)
        default: return nil
        }
    }

    // MARK: The generators

    static func linearGradient(from p0: CGPoint, to p1: CGPoint, _ c0: CIColor, _ c1: CIColor) -> CIImage {
        let start = c0.linearPremultiplied, end = c1.linearPremultiplied
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let length2 = dx * dx + dy * dy
        return CIImage(extent: CGRect.infinite) { x, y in
            guard length2 > 0 else { return start }
            let t = min(max(((x - p0.x) * dx + (y - p0.y) * dy) / length2, 0), 1)
            return start + (end - start) * Float(t)
        }
    }

    static func radialGradient(center: CGPoint, r0: CGFloat, r1: CGFloat, _ c0: CIColor, _ c1: CIColor) -> CIImage {
        let inner = c0.linearPremultiplied, outer = c1.linearPremultiplied
        // The colour past the outer radius: clear there, and nothing shows
        // beyond its circle.
        let outside = r1 >= r0 ? c1 : c0
        let reach = max(r0, r1)
        let extent = outside.alpha == 0
            ? CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2)
            : CGRect.infinite
        return CIImage(extent: extent) { x, y in
            let d = ((x - center.x) * (x - center.x) + (y - center.y) * (y - center.y)).squareRoot()
            let t: CGFloat = r1 == r0 ? (d < r0 ? 0 : 1) : min(max((d - r0) / (r1 - r0), 0), 1)
            return inner + (outer - inner) * Float(t)
        }
    }
}

public extension CIImage {
    /// `applyingFilter(_:parameters:)`, for the filters above: this image as
    /// the filter's `inputImage`. A name Core Image doesn't know gives an
    /// empty image, as Core Image's does.
    func applyingFilter(_ filterName: String, parameters: [String: Any]) -> CIImage {
        guard let filter = CIFilter(name: filterName, parameters: parameters) else { return .empty() }
        filter.setValue(self, forKey: kCIInputImageKey)
        return filter.outputImage ?? .empty()
    }

    func applyingFilter(_ filterName: String) -> CIImage {
        applyingFilter(filterName, parameters: [:])
    }
}

#endif
