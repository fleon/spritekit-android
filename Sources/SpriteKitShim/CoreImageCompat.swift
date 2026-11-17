#if SPRITEKIT_SHIM
import Foundation

// Core Image, as much of it as games use: soft fields drawn from a mask,
// each `clampedToExtent().applyingGaussianBlur(sigma:).cropped(to:)` and read
// back through a `CIContext`; and three filters by name
// (`CoreImageFilters.swift`): linear and radial gradients and the Gaussian
// blur, which a game may also put on an effect node.
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
// lighter in its middle tones (a 50/50 mix writes about 187, not 128, as on a
// Mac), and a field drawn from it reaches that much further; a white mask on
// clear keeps its alpha as blurred.

public final class CIImage: @unchecked Sendable {
    /// Premultiplied RGBA, row 0 the top, as `RasterImage` keeps it.
    fileprivate let width: Int
    fileprivate let height: Int
    fileprivate let pixels: [Float]
    /// Edges repeat outward (`clampedToExtent`) rather than fading to clear.
    fileprivate let clamped: Bool
    /// The bitmap's bottom-left corner in Core Image's space, y up: zero,
    /// or where a blur grew it to.
    fileprivate let originX: Int
    fileprivate let originY: Int
    /// A generator's picture instead of pixels (a gradient filter's output):
    /// premultiplied colour in linear light at a point, y up, as Core Image
    /// works. Drawn when a context renders a rectangle of it.
    let field: (@Sendable (CGFloat, CGFloat) -> SIMD4<Float>)?
    /// A generator's extent: infinite, as Core Image's, unless cropped (or a
    /// radial gradient that ends clear).
    private let fieldExtent: CGRect

    /// Core Image's extent: the bitmap's rectangle (origin at zero, as
    /// drawn), or a generator's.
    public var extent: CGRect {
        field == nil ? CGRect(x: originX, y: originY, width: width, height: height) : fieldExtent
    }

    fileprivate init(width: Int, height: Int, pixels: [Float], clamped: Bool, originX: Int = 0, originY: Int = 0) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.clamped = clamped
        self.originX = originX
        self.originY = originY
        field = nil
        fieldExtent = .zero
    }

    /// A generator, over `extent` (`CGRect.infinite` for all of it).
    init(extent: CGRect, field: @escaping @Sendable (CGFloat, CGFloat) -> SIMD4<Float>) {
        width = 0
        height = 0
        pixels = []
        clamped = false
        originX = 0
        originY = 0
        self.field = field
        fieldExtent = extent
    }

    /// An image with nothing in it, and an empty extent.
    public static func empty() -> CIImage {
        CIImage(width: 0, height: 0, pixels: [], clamped: false)
    }

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
        return CIImage(width: width, height: height, pixels: pixels, clamped: true, originX: originX, originY: originY)
    }

    /// A generator is cropped to the rectangle: clear outside it. A bitmap
    /// is cut to the rectangle; one that isn't on whole pixels takes every
    /// pixel it reaches, where Core Image keeps the fractional extent. A
    /// clamped bitmap keeps its pixels (it's cropped back to its own extent)
    /// and drops the clamp.
    public func cropped(to rect: CGRect) -> CIImage {
        if let field { return CIImage(extent: fieldExtent.intersection(rect), field: field) }
        if clamped { return CIImage(width: width, height: height, pixels: pixels, clamped: false, originX: originX, originY: originY) }
        let kept = rect.intersection(extent)
        guard !kept.isNull, !kept.isEmpty else { return .empty() }
        let cut = kept.integral
        if cut == extent { return self }
        let x0 = Int(cut.minX) - originX, y0 = Int(cut.minY) - originY
        let w = Int(cut.width), h = Int(cut.height)
        var out = [Float](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            // Row 0 is the top: Core Image's y counts up from the bottom.
            let sourceRow = height - 1 - (y0 + (h - 1 - row))
            let from = (sourceRow * width + x0) * 4
            out[row * w * 4..<(row + 1) * w * 4] = pixels[from..<from + w * 4]
        }
        return CIImage(width: w, height: h, pixels: out, clamped: false, originX: Int(cut.minX), originY: Int(cut.minY))
    }

    public func applyingGaussianBlur(sigma: Double) -> CIImage {
        if field != nil {
            // A generator is drawn over its extent first; an infinite one
            // (a gradient that never ends) has nothing to blur against.
            guard fieldExtent.width < 1e7, fieldExtent.height < 1e7,
                  let drawn = render(fieldExtent) else { return self }
            let bitmap = CIImage(cgImage: drawn)
            let placed = CIImage(width: bitmap.width, height: bitmap.height, pixels: bitmap.pixels, clamped: false,
                                 originX: Int(fieldExtent.minX.rounded(.down)), originY: Int(fieldExtent.minY.rounded(.down)))
            return placed.applyingGaussianBlur(sigma: sigma)
        }
        guard sigma > 0, width > 0, height > 0 else { return self }
        // Unclamped, the blur spreads past the edges, and the extent grows
        // by Core Image's margin; clamped, the edges repeat instead.
        let pad = clamped ? 0 : Self.blurMargin(sigma: sigma)
        let w = width + 2 * pad, h = height + 2 * pad
        var out: [Float]
        if pad == 0 {
            out = pixels
        } else {
            out = [Float](repeating: 0, count: w * h * 4)
            for row in 0..<height {
                let to = ((row + pad) * w + pad) * 4
                out[to..<to + width * 4] = pixels[row * width * 4..<(row + 1) * width * 4]
            }
        }
        var scratch = [Float](repeating: 0, count: max(w, h) * 4)
        for box in Self.boxes(sigma: sigma) {
            let radius = (box - 1) / 2
            guard radius > 0 else { continue }
            Self.boxPass(&out, count: w, lines: h, step: 4, lineStride: w * 4,
                         radius: radius, clamped: clamped, scratch: &scratch)
            Self.boxPass(&out, count: h, lines: w, step: w * 4, lineStride: 4,
                         radius: radius, clamped: clamped, scratch: &scratch)
        }
        return CIImage(width: w, height: h, pixels: out, clamped: clamped, originX: originX - pad, originY: originY - pad)
    }

    /// How far Core Image grows an unclamped image's extent for a blur of
    /// `sigma`, each side (measured on macOS 27.2, `CoreImageTests`): from
    /// 2.6667 it's ⌈3σ⌉ in single precision; below, it steps at the sigmas
    /// here, bisected to 1e-9.
    static func blurMargin(sigma: Double) -> Int {
        guard sigma > 0 else { return 0 }
        if sigma >= 2.6667 { return Int((Float(3) * Float(sigma)).rounded(.up)) }
        let steps = [0.16, 0.4, 0.7, 1.179349421, 1.516306418, 1.853282308, 2.191319279, 2.543177693]
        return steps.filter { sigma >= $0 }.count
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

    /// A generator drawn over `rect`, or a bitmap's pixels in `rect`'s
    /// whole pixels: clear outside the bitmap, or its edges repeated if
    /// it's clamped.
    public func createCGImage(_ image: CIImage, from rect: CGRect) -> RasterImage? {
        if image.field != nil { return image.render(rect) }
        guard image.width > 0, image.height > 0, !rect.isNull, !rect.isEmpty, !rect.isInfinite else { return nil }
        let cut = rect.integral
        if cut == image.extent { return image.raster }
        let w = Int(cut.width), h = Int(cut.height)
        guard w * h <= 1 << 26 else { return nil }
        let source = image.raster
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            var y = Int(cut.maxY) - 1 - row - image.originY
            if image.clamped { y = min(max(y, 0), image.height - 1) }
            guard (0..<image.height).contains(y) else { continue }
            let sourceRow = image.height - 1 - y
            for column in 0..<w {
                var x = Int(cut.minX) + column - image.originX
                if image.clamped { x = min(max(x, 0), image.width - 1) }
                guard (0..<image.width).contains(x) else { continue }
                let from = (sourceRow * image.width + x) * 4, to = (row * w + column) * 4
                out[to..<to + 4] = source.pixels[from..<from + 4]
            }
        }
        return RasterImage(width: w, height: h, pixels: out)
    }

    public func clearCaches() {}
}
#endif
