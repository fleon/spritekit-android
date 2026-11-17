#if SPRITEKIT_SHIM
import Foundation

// Core Image, as much of it as the games use: soft fields drawn from a
// mask (Switchlings' `LawnNode` clearing round the board, `BoardGroundingArt`'s
// glow and shadow), each `clampedToExtent().applyingGaussianBlur(sigma:).cropped(to:)`
// and read back through a `CIContext`; and three filters by name
// (`CoreImageFilters.swift`): Hue Rings' and Zyl's linear and radial gradient
// textures and the Gaussian blur Zyl and Phantom Words put on effect nodes.
// Android has no Core Image, so all of it runs here on the CPU, over the
// premultiplied pixels the software `CGContext` drew.
//
// The blur is three box blurs a direction (Wells' "boxes for Gauss"), which
// is within a few levels of a true Gaussian for these sizes and costs the
// same whatever the sigma: Core Image itself approximates large sigmas.
//
// Core Image works in linear light: it decodes an sRGB image's colour as it
// reads it and encodes it again as it writes it out, on unpremultiplied
// colour, leaving alpha as it is. So a blurred black-and-white mask comes out
// lighter in its middle tones (a 50/50 mix writes about 187, not 128, as on a Mac), and
// `LawnNode`'s clearing reaches that much further from the board; a white
// mask on clear (`BoardGroundingArt`) keeps its alpha as blurred.

public final class CIImage: @unchecked Sendable {
    /// Premultiplied RGBA, row 0 the top, as `RasterImage` keeps it.
    fileprivate let width: Int
    fileprivate let height: Int
    fileprivate let pixels: [Float]
    /// Edges repeat outward (`clampedToExtent`) rather than fading to clear.
    fileprivate let clamped: Bool
    /// A generator's picture instead of pixels (a gradient filter's output):
    /// premultiplied colour in linear light at a point, y up, as Core Image
    /// works. Drawn when a context renders a rectangle of it.
    let field: (@Sendable (CGFloat, CGFloat) -> SIMD4<Float>)?
    /// A generator's extent: infinite, as Core Image's, unless cropped (or a
    /// radial gradient that ends clear).
    private let fieldExtent: CGRect

    /// Core Image's extent: the image's own rectangle, origin at zero, or a
    /// generator's.
    public var extent: CGRect {
        field == nil ? CGRect(x: 0, y: 0, width: width, height: height) : fieldExtent
    }

    fileprivate init(width: Int, height: Int, pixels: [Float], clamped: Bool) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.clamped = clamped
        field = nil
        fieldExtent = .zero
    }

    /// A generator, over `extent` (`CIImage.infiniteExtent` for all of it).
    init(extent: CGRect, field: @escaping @Sendable (CGFloat, CGFloat) -> SIMD4<Float>) {
        width = 0
        height = 0
        pixels = []
        clamped = false
        self.field = field
        fieldExtent = extent
    }

    /// Core Image's infinite rectangle, as its generators report it.
    public static let infiniteExtent = CGRect(
        x: -CGFloat.greatestFiniteMagnitude / 2, y: -CGFloat.greatestFiniteMagnitude / 2,
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
    )

    public convenience init(cgImage: RasterImage) {
        var pixels = cgImage.pixels.map { Float($0) / 255 }
        Self.convertColour(&pixels, Self.linear)
        self.init(width: cgImage.width, height: cgImage.height, pixels: pixels, clamped: false)
    }

    public convenience init?(image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        self.init(cgImage: cg)
    }

    public func clampedToExtent() -> CIImage {
        if field != nil { return self }
        return CIImage(width: width, height: height, pixels: pixels, clamped: true)
    }

    /// Cropping a bitmap to anything but its own extent is not needed by the
    /// games, so the pixels are kept and only the clamp is dropped. A
    /// generator is cropped to the rectangle: clear outside it.
    public func cropped(to rect: CGRect) -> CIImage {
        if let field { return CIImage(extent: fieldExtent.intersection(rect), field: field) }
        return CIImage(width: width, height: height, pixels: pixels, clamped: false)
    }

    public func applyingGaussianBlur(sigma: Double) -> CIImage {
        if field != nil {
            // A generator is drawn over its extent first; an infinite one
            // (a gradient that never ends) has nothing to blur against.
            guard fieldExtent.width < 1e7, fieldExtent.height < 1e7,
                  let drawn = render(fieldExtent) else { return self }
            return CIImage(cgImage: drawn).applyingGaussianBlur(sigma: sigma)
        }
        guard sigma > 0, width > 0, height > 0 else { return self }
        var out = pixels
        var scratch = [Float](repeating: 0, count: max(width, height) * 4)
        for box in Self.boxes(sigma: sigma) {
            let radius = (box - 1) / 2
            guard radius > 0 else { continue }
            Self.boxPass(&out, count: width, lines: height, step: 4, lineStride: width * 4,
                         radius: radius, clamped: clamped, scratch: &scratch)
            Self.boxPass(&out, count: height, lines: width, step: width * 4, lineStride: 4,
                         radius: radius, clamped: clamped, scratch: &scratch)
        }
        return CIImage(width: width, height: height, pixels: out, clamped: clamped)
    }

    /// Three odd box widths whose passes together match `sigma`.
    static func boxes(sigma: Double, count: Int = 3) -> [Int] {
        let n = Double(count)
        let ideal = (12 * sigma * sigma / n + 1).squareRoot()
        var lower = Int(ideal.rounded(.down))
        if lower % 2 == 0 { lower -= 1 }
        let upper = lower + 2
        let l = Double(lower)
        let m = ((12 * sigma * sigma - n * l * l - 4 * n * l - 3 * n) / (-4 * l - 4)).rounded()
        return (0..<count).map { Double($0) < m ? lower : upper }
    }

    /// One box blur along every line of `values`: `count` samples a line,
    /// `step` apart, lines `lineStride` apart.
    private static func boxPass(_ values: inout [Float], count: Int, lines: Int, step: Int, lineStride: Int,
                                radius: Int, clamped: Bool, scratch: inout [Float]) {
        let scale = 1 / Float(radius * 2 + 1)
        for line in 0..<lines {
            let base = line * lineStride
            for channel in 0..<4 {
                func at(_ i: Int) -> Float {
                    if i < 0 { return clamped ? values[base + channel] : 0 }
                    if i >= count { return clamped ? values[base + (count - 1) * step + channel] : 0 }
                    return values[base + i * step + channel]
                }
                var sum: Float = 0
                for i in -radius...radius { sum += at(i) }
                for i in 0..<count {
                    scratch[i * 4 + channel] = sum * scale
                    sum += at(i + radius + 1) - at(i - radius)
                }
            }
            for i in 0..<count {
                for channel in 0..<4 { values[base + i * step + channel] = scratch[i * 4 + channel] }
            }
        }
    }

    /// A generator drawn over `rect`: a pixel a point from its bottom left,
    /// each sampled at its centre, the last column and row covering only
    /// what of them the rectangle reaches (as Core Image renders a
    /// fractional rectangle: whole pixels from its origin, a part one at
    /// its far edge). Colour is encoded to sRGB from linear light as it's
    /// written.
    fileprivate func render(_ rect: CGRect) -> RasterImage? {
        guard let field else { return nil }
        let width = Int((rect.width - 1e-9).rounded(.up)), height = Int((rect.height - 1e-9).rounded(.up))
        guard width > 0, height > 0, width * height <= 1 << 26 else { return nil }
        let lastColumn = Float(rect.width - CGFloat(width - 1))
        let lastRow = Float(rect.height - CGFloat(height - 1))
        let inside = fieldExtent
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let up = height - 1 - row
            let y = rect.minY + CGFloat(up) + 0.5
            let rowCover = up == height - 1 ? lastRow : 1
            for column in 0..<width {
                let x = rect.minX + CGFloat(column) + 0.5
                guard inside.minX <= x, x < inside.maxX, inside.minY <= y, y < inside.maxY else { continue }
                var colour = field(x, y)
                let alpha = colour.w
                guard alpha > 0 else { continue }
                for channel in 0..<3 {
                    colour[channel] = Self.encoded(min(1, max(0, colour[channel] / alpha))) * alpha
                }
                let cover = (column == width - 1 ? lastColumn : 1) * rowCover
                let base = (row * width + column) * 4
                for channel in 0..<4 {
                    out[base + channel] = UInt8(max(0, min(255, (colour[channel] * cover * 255).rounded())))
                }
            }
        }
        return RasterImage(width: width, height: height, pixels: out)
    }

    fileprivate var raster: RasterImage {
        var encoded = pixels
        Self.convertColour(&encoded, Self.encoded)
        return RasterImage(width: width, height: height,
                           pixels: encoded.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) })
    }

    /// Applies `transfer` to each premultiplied pixel's colour, unpremultiplied.
    private static func convertColour(_ values: inout [Float], _ transfer: (Float) -> Float) {
        for base in stride(from: 0, to: values.count - 3, by: 4) {
            let alpha = values[base + 3]
            guard alpha > 0 else { continue }
            for channel in 0..<3 {
                values[base + channel] = transfer(min(1, values[base + channel] / alpha)) * alpha
            }
        }
    }

    /// The sRGB transfer function, decoding and encoding.
    static func linear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ value: Float) -> Float {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}

public struct CIContextOption: Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let useSoftwareRenderer = CIContextOption(rawValue: "useSoftwareRenderer")
    public static let cacheIntermediates = CIContextOption(rawValue: "cacheIntermediates")
}

public final class CIContext: @unchecked Sendable {
    public init(options: [CIContextOption: Any]? = nil) {}

    /// A bitmap's pixels as they are (the games read back the whole
    /// extent), or a generator drawn over `rect`.
    public func createCGImage(_ image: CIImage, from rect: CGRect) -> RasterImage? {
        if image.field != nil { return image.render(rect) }
        guard image.width > 0, image.height > 0 else { return nil }
        return image.raster
    }

    public func clearCaches() {}
}
#endif
