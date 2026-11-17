#if SPRITEKIT_SHIM
import Foundation

/// Writes a PNG with no compression of its own: deflate's stored blocks,
/// which need no zlib, so the shim can write one on any host. The shell
/// installs a compressing encoder (`UIImage.encoder`), so a full-screen
/// picture isn't eight megabytes; this is what stands when none is.
///
/// The pixels go in as straight RGBA, since a PNG's alpha isn't
/// premultiplied and a `RasterImage`'s is.
public enum PNGEncoder {
    public static func encode(_ image: RasterImage, deflate: ((Data) -> Data?)? = nil) -> Data? {
        guard image.width > 0, image.height > 0, image.pixels.count >= image.width * image.height * 4 else { return nil }
        var raw = Data(capacity: (image.width * 4 + 1) * image.height)
        image.pixels.withUnsafeBufferPointer { pixels in
            for y in 0 ..< image.height {
                raw.append(0) // no filter
                for x in 0 ..< image.width {
                    let at = (y * image.width + x) * 4
                    let alpha = pixels[at + 3]
                    if alpha == 255 || alpha == 0 {
                        raw.append(contentsOf: [pixels[at], pixels[at + 1], pixels[at + 2], alpha])
                    } else {
                        func unpremultiply(_ value: UInt8) -> UInt8 { UInt8(min(255, (Int(value) * 255 + Int(alpha) / 2) / Int(alpha))) }
                        raw.append(contentsOf: [unpremultiply(pixels[at]), unpremultiply(pixels[at + 1]), unpremultiply(pixels[at + 2]), alpha])
                    }
                }
            }
        }
        guard let compressed = deflate.map({ $0(raw) }) ?? zlibStored(raw) else { return nil }
        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var header = Data()
        header.append(bigEndian: UInt32(image.width))
        header.append(bigEndian: UInt32(image.height))
        header.append(contentsOf: [8, 6, 0, 0, 0]) // 8-bit RGBA, deflate, no filter, no interlace
        png.appendChunk("IHDR", header)
        png.appendChunk("IDAT", compressed)
        png.appendChunk("IEND", Data())
        return png
    }

    /// A zlib stream of stored blocks.
    static func zlibStored(_ data: Data) -> Data? {
        var out = Data([0x78, 0x01])
        let blockSize = 65_535
        var offset = 0
        repeat {
            let count = min(blockSize, data.count - offset)
            let last: UInt8 = offset + count >= data.count ? 1 : 0
            out.append(last)
            out.append(UInt8(count & 0xFF))
            out.append(UInt8(count >> 8))
            out.append(UInt8(~count & 0xFF))
            out.append(UInt8((~count >> 8) & 0xFF))
            out.append(data[data.startIndex + offset ..< data.startIndex + offset + count])
            offset += count
        } while offset < data.count
        out.append(bigEndian: adler32(data))
        return out
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return b << 16 | a
    }

    static let crcTable: [UInt32] = (0 ..< 256).map { n in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendChunk(_ type: String, _ body: Data) {
        append(bigEndian: UInt32(body.count))
        let typed = Data(type.utf8) + body
        append(typed)
        append(bigEndian: PNGEncoder.crc32(typed))
    }
}
#endif
