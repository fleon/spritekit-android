import CZlib
import Foundation

/// Decodes the packed art's PNGs to straight RGBA8.
///
/// Deliberately narrow: it reads what `Tools/Art/android-art.js` writes —
/// 8-bit, non-interlaced, colour type 0, 2, 4 or 6 — and refuses anything
/// else loudly rather than producing a plausible-looking wrong image. That
/// is the same contract the exporter's own decoder holds on the Node side,
/// and the reason the port needs no image library: Android gives us zlib,
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

        let stride = width * channels
        let raw = try inflate(compressed, expecting: (stride + 1) * height)
        guard raw.count >= (stride + 1) * height else { throw Failure.corrupt("truncated pixel data") }

        var lines = [UInt8](repeating: 0, count: stride * height)
        try unfilter(raw, into: &lines, stride: stride, height: height, channels: channels)

        return Image(
            width: width,
            height: height,
            pixels: expand(lines, width: width, height: height, colour: colour, channels: channels, palette: palette)
        )
    }

    // MARK: Pieces

    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (UInt32(bytes[at]) << 24) | (UInt32(bytes[at + 1]) << 16)
            | (UInt32(bytes[at + 2]) << 8) | UInt32(bytes[at + 3])
    }

    /// zlib's one-shot inflate, grown if the first guess was short.
    private static func inflate(_ data: Data, expecting: Int) throws -> [UInt8] {
        var capacity = max(expecting, 1024)
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
                capacity *= 2
            default:
                throw Failure.corrupt("inflate returned \(status)")
            }
        }
        throw Failure.corrupt("inflate would not fit")
    }

    /// Undoes PNG's per-row filters in place.
    private static func unfilter(
        _ raw: [UInt8], into lines: inout [UInt8],
        stride: Int, height: Int, channels: Int
    ) throws {
        // A row at a time through pointers, the filter chosen once a row and
        // the first pixel's bytes (no left neighbour) apart from the rest:
        // the byte-at-a-time switch took seconds a page in a debug build,
        // on the thread that draws. Zeros stand in for the row above the
        // first, as the format says.
        let zeros = [UInt8](repeating: 0, count: stride)
        try raw.withUnsafeBufferPointer { rawBuffer in
            try zeros.withUnsafeBufferPointer { zeroBuffer in
                try lines.withUnsafeMutableBufferPointer { lineBuffer in
                    guard let source = rawBuffer.baseAddress, let out = lineBuffer.baseAddress,
                          let zero = zeroBuffer.baseAddress else { return }
                    let lead = min(channels, stride)
                    for y in 0 ..< height {
                        let filter = source[y * (stride + 1)]
                        let input = source + y * (stride + 1) + 1
                        let row = out + y * stride
                        let above = y > 0 ? UnsafePointer(row - stride) : zero
                        switch filter {
                        case 0:
                            row.update(from: input, count: stride)
                        case 1:
                            for x in 0 ..< lead { row[x] = input[x] }
                            for x in lead ..< stride { row[x] = input[x] &+ row[x - channels] }
                        case 2:
                            for x in 0 ..< stride { row[x] = input[x] &+ above[x] }
                        case 3:
                            for x in 0 ..< lead { row[x] = input[x] &+ above[x] >> 1 }
                            for x in lead ..< stride {
                                row[x] = input[x] &+ UInt8((UInt16(row[x - channels]) + UInt16(above[x])) >> 1)
                            }
                        case 4:
                            // Paeth; with no left neighbour it picks the byte above.
                            for x in 0 ..< lead { row[x] = input[x] &+ above[x] }
                            for x in lead ..< stride {
                                let a = Int(row[x - channels]), b = Int(above[x]), c = Int(above[x - channels])
                                let pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c)
                                row[x] = input[x] &+ UInt8(truncatingIfNeeded: pa <= pb && pa <= pc ? a : (pb <= pc ? b : c))
                            }
                        default:
                            throw Failure.corrupt("row \(y) has filter \(filter)")
                        }
                    }
                }
            }
        }
    }

    private static func expand(
        _ lines: [UInt8], width: Int, height: Int,
        colour: Int, channels: Int, palette: [UInt8]
    ) -> Data {
        if colour == 6 { return Data(lines) }

        var out = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0 ..< (width * height) {
            let source = i * channels
            let destination = i * 4
            switch colour {
            case 0:
                let g = lines[source]
                out[destination] = g; out[destination + 1] = g; out[destination + 2] = g
            case 2:
                out[destination] = lines[source]
                out[destination + 1] = lines[source + 1]
                out[destination + 2] = lines[source + 2]
            case 3:
                let index = Int(lines[source]) * 3
                if index + 2 < palette.count {
                    out[destination] = palette[index]
                    out[destination + 1] = palette[index + 1]
                    out[destination + 2] = palette[index + 2]
                }
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
