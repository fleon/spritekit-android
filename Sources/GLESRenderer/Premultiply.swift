import Foundation

/// Straight RGBA8, as a PNG holds it, turned into premultiplied, as
/// SpriteKit keeps every texture it loads from an image and as the renderer
/// blends (`GL_ONE, GL_ONE_MINUS_SRC_ALPHA`) and its shaders assume.
///
/// The packed pages and the rigs' own PNGs decode straight. Uploaded as
/// they were, every soft edge drew at its colour's full strength over what
/// lay behind it: a light halo round every Switchling, home and piece, and
/// a sleeper that looked undimmed, its edges brightened past the dimming.
public enum Premultiply {
    public static func rgba(_ pixels: Data) -> Data {
        var out = pixels
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var at = 0
            let count = raw.count - raw.count % 4
            while at < count {
                let alpha = UInt32(bytes[at + 3])
                if alpha < 255 {
                    bytes[at] = UInt8((UInt32(bytes[at]) * alpha + 127) / 255)
                    bytes[at + 1] = UInt8((UInt32(bytes[at + 1]) * alpha + 127) / 255)
                    bytes[at + 2] = UInt8((UInt32(bytes[at + 2]) * alpha + 127) / 255)
                }
                at += 4
            }
        }
        return out
    }

    /// Premultiplied as `rgba(_:)`, with its rows turned over into the
    /// bottom-first order GL takes them in, in the same pass: the page's
    /// upload then copies it as it is. Done where the page decodes, off the
    /// frame thread: turning a scene's pages over as they uploaded took
    /// 150 ms of a Galaxy M31's loading-screen warm-up.
    public static func rgbaFlipped(_ pixels: Data, width: Int, height: Int) -> Data {
        let stride = width * 4
        guard stride > 0, height > 0, pixels.count >= stride * height else { return rgba(pixels) }
        var out = Data(count: stride * height)
        pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                guard let from = source.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let to = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for row in 0 ..< height {
                    let input = from + row * stride
                    let output = to + (height - 1 - row) * stride
                    var at = 0
                    while at < stride {
                        let alpha = UInt32(input[at + 3])
                        if alpha == 255 {
                            output[at] = input[at]
                            output[at + 1] = input[at + 1]
                            output[at + 2] = input[at + 2]
                        } else {
                            output[at] = UInt8((UInt32(input[at]) * alpha + 127) / 255)
                            output[at + 1] = UInt8((UInt32(input[at + 1]) * alpha + 127) / 255)
                            output[at + 2] = UInt8((UInt32(input[at + 2]) * alpha + 127) / 255)
                        }
                        output[at + 3] = UInt8(alpha)
                        at += 4
                    }
                }
            }
        }
        return out
    }

    /// Rows in the opposite order: PNG's top-first into GL's bottom-first.
    public static func flippedRows(_ pixels: Data, width: Int, height: Int) -> Data {
        let stride = width * 4
        guard stride > 0, height > 0, pixels.count >= stride * height else { return pixels }
        var out = Data(count: stride * height)
        pixels.withUnsafeBytes { source in
            out.withUnsafeMutableBytes { destination in
                guard let from = source.baseAddress, let to = destination.baseAddress else { return }
                for row in 0 ..< height {
                    memcpy(to.advanced(by: (height - 1 - row) * stride), from.advanced(by: row * stride), stride)
                }
            }
        }
        return out
    }
}
