import CPixelRows
import Foundation

/// Straight RGBA8, as a PNG holds it, turned into premultiplied, as
/// SpriteKit keeps every texture it loads from an image and as the renderer
/// blends (`GL_ONE, GL_ONE_MINUS_SRC_ALPHA`) and its shaders assume.
///
/// The packed pages and loose PNGs decode straight. Uploaded as they were,
/// every soft edge drew at its colour's full strength over what lay behind
/// it: a light halo round every sprite, and a dimmed sprite whose edges were
/// brightened past the dimming.
public enum Premultiply {
    /// In C (`pixel_rows_premultiply`), as `PNGRows` is: a debug build's
    /// unoptimised Swift took most of a second for a large image.
    public static func rgba(_ pixels: Data) -> Data {
        var out = pixels
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            pixel_rows_premultiply(bytes, raw.count - raw.count % 4)
        }
        return out
    }

    /// Premultiplied as `rgba(_:)`, with its rows turned over into the
    /// bottom-first order GL takes them in, in the same pass: the page's
    /// upload then copies it as it is. Done where the page decodes, off the
    /// frame thread: turning a scene's pages over as they uploaded took
    /// 150 ms of a loading screen's warm-up on a Mali-G72 phone.
    public static func rgbaFlipped(_ pixels: Data, width: Int, height: Int) -> Data {
        let stride = width * 4
        guard stride > 0, height > 0, pixels.count >= stride * height else { return rgba(pixels) }
        var out = Data(count: stride * height)
        pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                guard let from = source.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let to = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                pixel_rows_premultiply_flipped(from, to, width, height)
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
