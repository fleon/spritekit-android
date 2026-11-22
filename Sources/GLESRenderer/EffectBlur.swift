import Foundation

/// An `SKEffectNode`'s `CIGaussianBlur` as the renderer draws it: two passes
/// over the node's texture, across then up, each a Gaussian of `sigma`
/// pixels sampled out to three sigmas, as far as the texture reaches past
/// the node's contents (`SKEffectNode.effectBounds`).
///
/// Each pass reads the texel under the pixel and pairs of texels either
/// side, each pair in one linear fetch placed between them by their
/// weights, so a pass costs half the taps it covers.
/// `ShaderTranslator.blurFragmentShader` runs it; `blurred` is the same
/// sum on the CPU, for the tests.
public struct EffectBlur: Equatable {
    /// The most pairs a pass takes, a reach of twice as many texels: past
    /// it a wider blur is cut short at its tails.
    public static let maximumPairs = 64

    /// The weight of the texel under the pixel.
    public let centre: Float
    /// Each pair as (offset in texels, weight of the pair), one side; the
    /// other side mirrors it.
    public let pairs: [SIMD2<Float>]

    /// A blur of `sigma` texels, or nil when it would move nothing.
    public init?(sigma: Double) {
        guard sigma > 0.01 else { return nil }
        let reach = min(Int((3 * sigma).rounded(.up)), 2 * Self.maximumPairs)
        let weights = (0...reach).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
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

    /// One pass over premultiplied RGBA rows, along x (`horizontal`) or y,
    /// as the shader samples: linear between texels, clamped at the edges.
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
