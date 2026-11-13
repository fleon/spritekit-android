#if SPRITEKIT_SHIM
import Foundation

// Core Image, as much of it as the game uses: two soft fields drawn from a
// mask (`LawnNode`'s clearing round the board, `BoardGroundingArt`'s glow and
// shadow), each `clampedToExtent().applyingGaussianBlur(sigma:).cropped(to:)`
// and read back through a `CIContext`. Android has no Core Image, so the blur
// runs here on the CPU, over the premultiplied pixels the software
// `CGContext` drew.
//
// The blur is three box blurs a direction (Wells' "boxes for Gauss"), which
// is within a few levels of a true Gaussian for these sizes and costs the
// same whatever the sigma: Core Image itself approximates large sigmas.

public final class CIImage: @unchecked Sendable {
    /// Premultiplied RGBA, row 0 the top, as `RasterImage` keeps it.
    fileprivate let width: Int
    fileprivate let height: Int
    fileprivate let pixels: [Float]
    /// Edges repeat outward (`clampedToExtent`) rather than fading to clear.
    fileprivate let clamped: Bool

    /// Core Image's extent: the image's own rectangle, origin at zero.
    public var extent: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    fileprivate init(width: Int, height: Int, pixels: [Float], clamped: Bool) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.clamped = clamped
    }

    public convenience init(cgImage: RasterImage) {
        self.init(width: cgImage.width, height: cgImage.height,
                  pixels: cgImage.pixels.map { Float($0) / 255 }, clamped: false)
    }

    public convenience init?(image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        self.init(cgImage: cg)
    }

    public func clampedToExtent() -> CIImage {
        CIImage(width: width, height: height, pixels: pixels, clamped: true)
    }

    /// Cropping to anything but the image's own extent is not needed by the
    /// game, so the pixels are kept and only the clamp is dropped.
    public func cropped(to rect: CGRect) -> CIImage {
        CIImage(width: width, height: height, pixels: pixels, clamped: false)
    }

    public func applyingGaussianBlur(sigma: Double) -> CIImage {
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

    fileprivate var raster: RasterImage {
        RasterImage(width: width, height: height,
                    pixels: pixels.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) })
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

    public func createCGImage(_ image: CIImage, from rect: CGRect) -> RasterImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        return image.raster
    }

    public func clearCaches() {}
}
#endif
