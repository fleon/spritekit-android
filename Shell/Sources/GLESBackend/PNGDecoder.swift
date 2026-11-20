import CZlib
import Foundation
import GLESRenderer

/// Decodes the packed art's PNGs to straight RGBA8.
///
/// Deliberately narrow: it reads what an art packer writes for `AssetIndex` —
/// 8-bit, non-interlaced, colour type 0, 2, 4 or 6 — and refuses anything
/// else loudly rather than producing a plausible-looking wrong image. That
/// is the contract the packer is held to, and the reason the runtime needs
/// no image library: Android gives us zlib,
/// and PNG's remaining work is a row filter per scanline.
public enum PNGDecoder {

    public struct Image {
        public let width: Int
        public let height: Int
        /// Straight RGBA8, top row first, ready for `glTexImage2D`.
        public let pixels: Data
    }

    public enum Failure: Error, CustomStringConvertible {
        case notAPNG
        case unsupported(String)
        case corrupt(String)

        public var description: String {
            switch self {
            case .notAPNG: return "not a PNG"
            case let .unsupported(what): return "unsupported: \(what)"
            case let .corrupt(what): return "corrupt: \(what)"
            }
        }
    }

    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    public static func decode(_ data: Data) throws -> Image {
        let bytes = [UInt8](data)
        guard bytes.count > 8, Array(bytes[0 ..< 8]) == signature else { throw Failure.notAPNG }

        var width = 0, height = 0, depth = 0, colour = 0, interlace = 0
        var compressed = Data()
        var palette: [UInt8] = []
        // Transparency (tRNS): a palette's alphas, or the one grey or rgb
        // value that is clear (a colour emoji's strike has them).
        var transparency: [UInt8] = []
        var sawHeader = false

        var i = 8
        while i + 8 <= bytes.count {
            let length = Int(be32(bytes, i))
            let type = String(bytes: bytes[i + 4 ..< i + 8], encoding: .ascii) ?? ""
            let start = i + 8
            guard start + length <= bytes.count else { throw Failure.corrupt("chunk \(type) runs past the end") }

            switch type {
            case "IHDR":
                guard length >= 13 else { throw Failure.corrupt("short IHDR") }
                width = Int(be32(bytes, start))
                height = Int(be32(bytes, start + 4))
                depth = Int(bytes[start + 8])
                colour = Int(bytes[start + 9])
                interlace = Int(bytes[start + 12])
                sawHeader = true
            case "PLTE":
                palette = Array(bytes[start ..< start + length])
            case "tRNS":
                transparency = Array(bytes[start ..< start + length])
            case "IDAT":
                compressed.append(contentsOf: bytes[start ..< start + length])
            case "IEND":
                i = bytes.count
            default:
                break
            }
            i = start + length + 4   // + CRC
        }

        guard sawHeader else { throw Failure.corrupt("no IHDR") }
        guard width > 0, height > 0 else { throw Failure.corrupt("\(width)x\(height)") }
        // A header's word only: a font's or a server's image can claim any
        // size, so none past what a texture can be.
        guard width <= maxSide, height <= maxSide else { throw Failure.unsupported("\(width)x\(height)") }
        guard depth == 8 else { throw Failure.unsupported("\(depth)-bit") }
        guard interlace == 0 else { throw Failure.unsupported("interlaced") }
        guard !compressed.isEmpty else { throw Failure.corrupt("no IDAT") }

        let channels: Int
        switch colour {
        case 0: channels = 1          // grey
        case 2: channels = 3          // rgb
        case 3: channels = 1          // palette index
        case 4: channels = 2          // grey + alpha
        case 6: channels = 4          // rgba
        default: throw Failure.unsupported("colour type \(colour)")
        }
        if colour == 3, palette.count < 3 { throw Failure.corrupt("palette image with no PLTE") }

        let (stride, wide) = width.multipliedReportingOverflow(by: channels)
        let (expected, big) = (stride + 1).multipliedReportingOverflow(by: height)
        guard !wide, !big, !(width * height).multipliedReportingOverflow(by: 4).overflow else {
            throw Failure.unsupported("\(width)x\(height)")
        }
        let raw = try inflate(compressed, expecting: expected)
        guard raw.count >= expected else { throw Failure.corrupt("truncated pixel data") }

        let unfiltered = PNGRows.unfilter(raw, stride: stride, height: height, channels: channels)
        guard let lines = unfiltered.rows else { throw Failure.corrupt("row \(unfiltered.badRow ?? 0) has an unknown filter") }

        return Image(
            width: width,
            height: height,
            pixels: expand(lines, width: width, height: height, colour: colour, channels: channels, palette: palette,
                           transparency: transparency)
        )
    }

    // MARK: Pieces

    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (UInt32(bytes[at]) << 24) | (UInt32(bytes[at + 1]) << 16)
            | (UInt32(bytes[at + 2]) << 8) | UInt32(bytes[at + 3])
    }

    /// The widest or tallest image decoded.
    static let maxSide = 16384

    /// zlib's one-shot inflate into `expecting` bytes, the buffer first no
    /// bigger than DEFLATE can expand the data to (1032 to 1), so a header
    /// claiming a vast image costs what its data can fill.
    private static func inflate(_ data: Data, expecting: Int) throws -> [UInt8] {
        let reach = data.count.multipliedReportingOverflow(by: 1032)
        var capacity = max(1024, min(expecting, reach.overflow ? expecting : reach.partialValue + 1024))
        for _ in 0 ..< 8 {
            var out = [UInt8](repeating: 0, count: capacity)
            var produced = uLongf(capacity)
            let status: Int32 = data.withUnsafeBytes { source in
                out.withUnsafeMutableBufferPointer { destination in
                    uncompress(
                        destination.baseAddress, &produced,
                        source.baseAddress!.assumingMemoryBound(to: Bytef.self),
                        uLong(data.count)
                    )
                }
            }
            switch status {
            case Z_OK:
                out.removeLast(capacity - Int(produced))
                return out
            case Z_BUF_ERROR:
                // More than the image holds is a corrupt stream, not a bigger buffer.
                guard capacity < expecting else { throw Failure.corrupt("more pixel data than the image holds") }
                capacity = min(expecting, capacity * 2)
            default:
                throw Failure.corrupt("inflate returned \(status)")
            }
        }
        throw Failure.corrupt("inflate would not fit")
    }

    private static func expand(
        _ lines: [UInt8], width: Int, height: Int,
        colour: Int, channels: Int, palette: [UInt8], transparency: [UInt8] = []
    ) -> Data {
        if colour == 6 { return Data(lines) }
        // A grey or rgb key: 16-bit samples, of which an 8-bit image uses the low byte.
        let key: [UInt8]? = switch colour {
        case 0 where transparency.count >= 2: [transparency[1]]
        case 2 where transparency.count >= 6: [transparency[1], transparency[3], transparency[5]]
        default: nil
        }

        var out = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0 ..< (width * height) {
            let source = i * channels
            let destination = i * 4
            switch colour {
            case 0:
                let g = lines[source]
                out[destination] = g; out[destination + 1] = g; out[destination + 2] = g
                if let key, g == key[0] { out[destination + 3] = 0 }
            case 2:
                out[destination] = lines[source]
                out[destination + 1] = lines[source + 1]
                out[destination + 2] = lines[source + 2]
                if let key, lines[source] == key[0], lines[source + 1] == key[1], lines[source + 2] == key[2] {
                    out[destination + 3] = 0
                }
            case 3:
                let entry = Int(lines[source]), index = entry * 3
                if index + 2 < palette.count {
                    out[destination] = palette[index]
                    out[destination + 1] = palette[index + 1]
                    out[destination + 2] = palette[index + 2]
                }
                if entry < transparency.count { out[destination + 3] = transparency[entry] }
            case 4:
                let g = lines[source]
                out[destination] = g; out[destination + 1] = g; out[destination + 2] = g
                out[destination + 3] = lines[source + 1]
            default:
                break
            }
        }
        return Data(out)
    }
}
