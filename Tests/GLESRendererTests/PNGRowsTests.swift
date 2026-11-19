import Foundation
import Testing
@testable import GLESRenderer

/// PNG's row filters undone, and colours premultiplied, in C match the
/// Swift they replaced, byte for byte.
@Suite("PNG row filters")
struct PNGRowsTests {
    /// The Swift unfilter `PNGDecoder` used before, kept as the reference.
    static func reference(_ raw: [UInt8], stride: Int, height: Int, channels: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: stride * height)
        for y in 0 ..< height {
            let filter = raw[y * (stride + 1)]
            for x in 0 ..< stride {
                let input = raw[y * (stride + 1) + 1 + x]
                let a = x >= channels ? Int(out[y * stride + x - channels]) : 0
                let b = y > 0 ? Int(out[(y - 1) * stride + x]) : 0
                let c = x >= channels && y > 0 ? Int(out[(y - 1) * stride + x - channels]) : 0
                let predicted: Int
                switch filter {
                case 0: predicted = 0
                case 1: predicted = a
                case 2: predicted = b
                case 3: predicted = (a + b) >> 1
                case 4:
                    let pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c)
                    predicted = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                default: return nil
                }
                out[y * stride + x] = UInt8(truncatingIfNeeded: Int(input) + predicted)
            }
        }
        return out
    }

    @Test("Every filter, one to four bytes a pixel, matches the reference")
    func matchesReference() {
        var generator = SystemRandomNumberGenerator()
        for channels in 1 ... 4 {
            for width in [1, 2, 7, 33] {
                let stride = width * channels, height = 12
                var raw = [UInt8](repeating: 0, count: (stride + 1) * height)
                for y in 0 ..< height {
                    // Each filter in turn, the first row's included.
                    raw[y * (stride + 1)] = UInt8(y % 5)
                    for x in 0 ..< stride { raw[y * (stride + 1) + 1 + x] = UInt8.random(in: 0 ... 255, using: &generator) }
                }
                let ours = PNGRows.unfilter(raw, stride: stride, height: height, channels: channels)
                #expect(ours.rows == Self.reference(raw, stride: stride, height: height, channels: channels),
                        "\(channels) channels, \(width) wide")
            }
        }
    }

    @Test("Premultiplying rounds as before, every colour at every alpha, flipped or not")
    func premultiply() {
        // 256 rows of 256 pixels: row alpha, pixel colour (each channel apart).
        var straight = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for alpha in 0 ..< 256 {
            for colour in 0 ..< 256 {
                let at = (alpha * 256 + colour) * 4
                straight[at] = UInt8(colour); straight[at + 1] = UInt8(255 - colour); straight[at + 2] = UInt8(colour / 2)
                straight[at + 3] = UInt8(alpha)
            }
        }
        func expected(_ c: UInt8, _ a: UInt8) -> UInt8 { a == 255 ? c : UInt8((UInt32(c) * UInt32(a) + 127) / 255) }
        let premultiplied = [UInt8](Premultiply.rgba(Data(straight)))
        let flipped = [UInt8](Premultiply.rgbaFlipped(Data(straight), width: 256, height: 256))
        var wrong = 0
        for alpha in 0 ..< 256 {
            for colour in 0 ..< 256 {
                let at = (alpha * 256 + colour) * 4, turned = ((255 - alpha) * 256 + colour) * 4
                for channel in 0 ..< 3 {
                    let want = expected(straight[at + channel], UInt8(alpha))
                    if premultiplied[at + channel] != want || flipped[turned + channel] != want { wrong += 1 }
                }
                if premultiplied[at + 3] != UInt8(alpha) || flipped[turned + 3] != UInt8(alpha) { wrong += 1 }
            }
        }
        #expect(wrong == 0)
    }

    @Test("A filter PNG doesn't define names its row")
    func unknownFilter() {
        var raw = [UInt8](repeating: 0, count: 3 * 5)
        raw[2 * 5] = 9
        let result = PNGRows.unfilter(raw, stride: 4, height: 3, channels: 4)
        #expect(result.rows == nil && result.badRow == 2)
    }
}
