import Foundation

/// An `SKEffectNode`'s `CIGaussianBlur` as the renderer draws it: two passes
/// over the node's texture, across then up, each a Gaussian of `sigma`
/// pixels sampled out to three sigmas, as far as the texture reaches past
/// the node's contents (`SKEffectNode.effectBounds`).
///
/// Each pass reads the texel under the pixel and pairs of texels either
/// side, each pair in one linear fetch placed between them by their
/// weights, so a pass costs half the taps it covers. A blur wider than the
/// pairs reach is run over a copy halved `downsample` times over, then
/// stretched back, as Core Image blurs at large radii: still a Gaussian
/// out to three sigmas, for a fraction of the taps.
/// `ShaderTranslator.blurFragmentShader` runs a pass; `blurred(_:width:height:)`
/// is the same picture on the CPU, for the tests.
public struct EffectBlur: Equatable {
    /// The most pairs a pass takes, a reach of twice as many texels.
    public static let maximumPairs = 64

    /// How many times smaller the copy the kernel runs over is: 1, or a
    /// power of two once three sigmas reach past `2 × maximumPairs` texels.
    public let downsample: Int
    /// The weight of the texel under the pixel.
    public let centre: Float
    /// Each pair as (offset in texels of the copy, weight of the pair), one
    /// side; the other side mirrors it.
    public let pairs: [SIMD2<Float>]

    /// A blur of `sigma` texels, or nil when it would move nothing.
    public init?(sigma: Double) {
        guard sigma > 0.01 else { return nil }
        var factor = 1
        while 3 * sigma / Double(factor) > Double(2 * Self.maximumPairs) { factor *= 2 }
        downsample = factor
        // Halving and stretching back blur a little themselves (a box of
        // `factor` texels, then a tent twice as wide): the kernel spreads
        // only what is left, so the whole spreads by `sigma`.
        let own = factor > 1 ? Double(3 * factor * factor - 1) / 12 : 0
        let kernelSigma = max(sigma * sigma - own, 1e-4).squareRoot() / Double(factor)
        let reach = Int((3 * kernelSigma).rounded(.up))
        let weights = (0...reach).map { exp(-Double($0 * $0) / (2 * kernelSigma * kernelSigma)) }
        let total = weights[0] + 2 * weights.dropFirst().reduce(0, +)
        centre = Float(weights[0] / total)
        var pairs: [SIMD2<Float>] = []
        var first = 1
        while first <= reach {
            let a = weights[first] / total
            let b = first + 1 <= reach ? weights[first + 1] / total : 0
            let offset = (Double(first) * a + Double(first + 1) * b) / (a + b)
            pairs.append(SIMD2(Float(offset), Float(a + b)))
            first += 2
        }
        self.pairs = pairs
    }

    /// The pairs packed two to a vec4 (offset, weight, offset, weight), as
    /// the shader's `u_blur_pairs` takes them, padded with empty pairs.
    public var packedPairs: [Float] {
        var packed = [Float](repeating: 0, count: Self.maximumPairs * 2)
        for (index, pair) in pairs.enumerated() {
            packed[index * 2] = pair.x
            packed[index * 2 + 1] = pair.y
        }
        return packed
    }

    /// The size of each copy the picture is halved into, from `width` ×
    /// `height`, smallest last: what the renderer draws into.
    public func halvings(width: Int, height: Int) -> [(width: Int, height: Int)] {
        var sizes: [(width: Int, height: Int)] = []
        var (w, h) = (width, height)
        var factor = 1
        while factor < downsample {
            (w, h) = (max(1, (w + 1) / 2), max(1, (h + 1) / 2))
            sizes.append((w, h))
            factor *= 2
        }
        return sizes
    }

    /// The whole blur over premultiplied RGBA rows, as the renderer draws
    /// it: halved, blurred across and up, stretched back.
    public func blurred(_ pixels: [Float], width: Int, height: Int) -> [Float] {
        var (image, w, h) = (pixels, width, height)
        for size in halvings(width: width, height: height) {
            image = Self.resampled(image, width: w, height: h, to: size.width, size.height)
            (w, h) = size
        }
        image = blurred(image, width: w, height: h, horizontal: true)
        image = blurred(image, width: w, height: h, horizontal: false)
        guard downsample > 1 else { return image }
        return Self.resampled(image, width: w, height: h, to: width, height)
    }

    /// `pixels` drawn over a target of another size, as a quad over the
    /// whole target samples it: linear between texels, clamped at the edges.
    static func resampled(_ pixels: [Float], width: Int, height: Int, to newWidth: Int, _ newHeight: Int) -> [Float] {
        var out = [Float](repeating: 0, count: newWidth * newHeight * 4)
        for y in 0..<newHeight {
            let sy = (Float(y) + 0.5) * Float(height) / Float(newHeight) - 0.5
            let y0 = Int(sy.rounded(.down)), fy = sy - Float(y0)
            let ya = min(max(y0, 0), height - 1), yb = min(max(y0 + 1, 0), height - 1)
            for x in 0..<newWidth {
                let sx = (Float(x) + 0.5) * Float(width) / Float(newWidth) - 0.5
                let x0 = Int(sx.rounded(.down)), fx = sx - Float(x0)
                let xa = min(max(x0, 0), width - 1), xb = min(max(x0 + 1, 0), width - 1)
                for channel in 0..<4 {
                    func at(_ px: Int, _ py: Int) -> Float { pixels[(py * width + px) * 4 + channel] }
                    let top = at(xa, ya) + (at(xb, ya) - at(xa, ya)) * fx
                    let bottom = at(xa, yb) + (at(xb, yb) - at(xa, yb)) * fx
                    out[(y * newWidth + x) * 4 + channel] = top + (bottom - top) * fy
                }
            }
        }
        return out
    }

    /// One pass of the kernel over premultiplied RGBA rows, along x
    /// (`horizontal`) or y, as the shader samples: linear between texels,
    /// clamped at the edges.
    public func blurred(_ pixels: [Float], width: Int, height: Int, horizontal: Bool) -> [Float] {
        var out = [Float](repeating: 0, count: pixels.count)
        func texel(_ x: Int, _ y: Int, _ channel: Int) -> Float {
            let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
            return pixels[(cy * width + cx) * 4 + channel]
        }
        func sample(_ x: Int, _ y: Int, _ offset: Float, _ channel: Int) -> Float {
            let whole = Int(offset.rounded(.down)), part = offset - Float(whole)
            let (dx, dy) = horizontal ? (1, 0) : (0, 1)
            let near = texel(x + dx * whole, y + dy * whole, channel)
            let far = texel(x + dx * (whole + 1), y + dy * (whole + 1), channel)
            return near + (far - near) * part
        }
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<4 {
                    var sum = centre * texel(x, y, channel)
                    for pair in pairs {
                        sum += pair.y * (sample(x, y, pair.x, channel) + sample(x, y, -pair.x, channel))
                    }
                    out[(y * width + x) * 4 + channel] = sum
                }
            }
        }
        return out
    }
}
