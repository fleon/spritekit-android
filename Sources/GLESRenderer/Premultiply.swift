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
}
