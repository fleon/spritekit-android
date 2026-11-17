import CZlib
import Foundation
import GLESRenderer
import SpriteKitShim

/// PNG files for `UIImage`, which the shim can't inflate or compress on its
/// own: reading one (an image the game draws into a context) with the
/// renderer's own decoder, and writing one (a picture the game saves)
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
    /// The last page cut from: images read one after another likely sit on
    /// the same page.
    private nonisolated(unsafe) static var lastPage: (number: Int, page: PageImage)?

    /// An image set's rect of its page, premultiplied, top row first.
    private static func cut(_ entry: AssetIndex.Entry) -> RasterImage? {
        if lastPage?.number != entry.page {
            guard let page = AssetBundle.page(entry.page) else { return nil }
            lastPage = (entry.page, page)
        }
        guard let page = lastPage?.page else { return nil }
        let x = Int(entry.rect.minX), y = Int(entry.rect.minY)
        let width = Int(entry.rect.width), height = Int(entry.rect.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        if let compressed = page.compressed {
            // Premultiplied already, and bottom row first, as it ships.
            let decoded = compressed.decode(x: x, y: page.height - y - height, width: width, height: height)
            guard decoded.count == pixels.count else { return nil }
            for row in 0 ..< height {
                let from = (height - 1 - row) * width * 4
                pixels.replaceSubrange(row * width * 4 ..< (row + 1) * width * 4, with: decoded[from ..< from + width * 4])
            }
            return RasterImage(width: width, height: height, pixels: pixels)
        }
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

    /// A zlib stream of `data`, at zlib's default level: a full-screen
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
