import CZlib
import Foundation
import SpriteKitShim

/// PNG files for `UIImage`, which the shim can't inflate or compress on its
/// own: reading one (a share's avatar, drawn into its credit's disc) with
/// the renderer's own decoder, and writing one (a share film's picture)
/// through Android's zlib.
public enum PNGFiles {
    public static func install() {
        UIImage.decoder = { data in
            guard let image = try? PNGDecoder.decode(data) else { return nil }
            // A `RasterImage` is premultiplied; a PNG's pixels are straight.
            var pixels = [UInt8](image.pixels)
            for at in stride(from: 0, to: pixels.count, by: 4) where pixels[at + 3] < 255 {
                let alpha = UInt16(pixels[at + 3])
                for channel in 0 ..< 3 { pixels[at + channel] = UInt8((UInt16(pixels[at + channel]) * alpha + 127) / 255) }
            }
            return RasterImage(width: image.width, height: image.height, pixels: pixels)
        }
        UIImage.encoder = { PNGEncoder.encode($0, deflate: compress) }
        UIImage.packed = { name in
            guard let entry = AssetIndex.shared?[name] else { return nil }
            return lock.withLock { cut(entry) }
        }
    }

    private static let lock = NSLock()
    /// The last page cut from, decoded: a share's avatar is one image, and
    /// the next share's likely sits on the same page.
    private nonisolated(unsafe) static var lastPage: (number: Int, width: Int, pixels: Data)?

    /// An image set's rect of its page, premultiplied, top row first.
    private static func cut(_ entry: AssetIndex.Entry) -> RasterImage? {
        if lastPage?.number != entry.page {
            guard let page = AssetBundle.page(entry.page) else { return nil }
            lastPage = (entry.page, page.width, page.pixels)
        }
        guard let page = lastPage else { return nil }
        let x = Int(entry.rect.minX), y = Int(entry.rect.minY)
        let width = Int(entry.rect.width), height = Int(entry.rect.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        page.pixels.withUnsafeBytes { source in
            for row in 0 ..< height {
                let from = ((y + row) * page.width + x) * 4
                for at in 0 ..< width * 4 { pixels[row * width * 4 + at] = source[from + at] }
            }
        }
        for at in stride(from: 0, to: pixels.count, by: 4) where pixels[at + 3] < 255 {
            let alpha = UInt16(pixels[at + 3])
            for channel in 0 ..< 3 { pixels[at + channel] = UInt8((UInt16(pixels[at + channel]) * alpha + 127) / 255) }
        }
        return RasterImage(width: width, height: height, pixels: pixels)
    }

    /// A zlib stream of `data`, at zlib's default level: a share film's
    /// picture is a few hundred kilobytes rather than eight megabytes.
    static func compress(_ data: Data) -> Data? {
        var length = compressBound(uLong(data.count))
        var out = Data(count: Int(length))
        let status = out.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                compress2(
                    target.baseAddress!.assumingMemoryBound(to: Bytef.self), &length,
                    source.baseAddress!.assumingMemoryBound(to: Bytef.self), uLong(data.count),
                    Z_DEFAULT_COMPRESSION
                )
            }
        }
        guard status == Z_OK else { return nil }
        out.count = Int(length)
        return out
    }
}
