import Foundation

/// Raw DEFLATE (RFC 1951) decompression: what Foundation's
/// `NSData.decompressed(using: .zlib)` reads on Apple — a DEFLATE stream with
/// no zlib header or checksum. Plain Swift, so it builds and tests on the
/// Mac; on Android `NSData.decompressed(using:)` below is it.
public enum Inflate {
    public enum Failure: Error, Equatable {
        /// The stream ended early, or has a block or code that can't be.
        case corrupt
    }

    /// `data` inflated; throws on a truncated or malformed stream.
    public static func decompress(_ data: Data) throws -> Data {
        var inflater = Inflater(input: [UInt8](data))
        try inflater.run()
        return Data(inflater.output)
    }
}

#if !canImport(Darwin)
extension NSData {
    /// Foundation's algorithms; only `.zlib` (raw DEFLATE) is here.
    public enum CompressionAlgorithm: Int, Sendable {
        case lzfse, lz4, lzma, zlib
    }

    /// The data inflated, as Foundation's on Apple. Throws for an algorithm
    /// other than `.zlib` and for a stream that doesn't decode.
    public func decompressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        guard algorithm == .zlib else { throw CocoaError(.featureUnsupported) }
        do {
            return try Inflate.decompress(Data(referencing: self)) as NSData
        } catch {
            // Apple's NSDecompressionFailedError, for empty input too.
            throw CocoaError(CocoaError.Code(rawValue: 5377))
        }
    }
}
#endif

// MARK: - The decoder (after zlib's puff.c)

private struct Huffman {
    /// Codes of each length, 0…15, and the symbols in canonical order.
    var counts = [Int](repeating: 0, count: 16)
    var symbols: [Int] = []

    /// More codes of some length than the lengths before leave room for:
    /// no stream can use such a set.
    private(set) var isOversubscribed = false

    init(lengths: ArraySlice<Int>) {
        symbols = [Int](repeating: 0, count: lengths.count)
        for length in lengths { counts[length] += 1 }
        var left = 1
        for length in 1 ..< 16 {
            left <<= 1
            left -= counts[length]
            if left < 0 { isOversubscribed = true }
        }
        var offsets = [Int](repeating: 0, count: 16)
        for length in 1 ..< 15 { offsets[length + 1] = offsets[length] + counts[length] }
        for (symbol, length) in zip(0..., lengths) where length != 0 {
            symbols[offsets[length]] = symbol
            offsets[length] += 1
        }
    }
}

private struct Inflater {
    let input: [UInt8]
    var output: [UInt8] = []
    private var position = 0
    private var bitBuffer = 0
    private var bitCount = 0

    init(input: [UInt8]) {
        self.input = input
        output.reserveCapacity(input.count * 4)
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let fixed: (Huffman, Huffman) = {
        var lengths = [Int](repeating: 8, count: 288)
        for symbol in 144 ..< 256 { lengths[symbol] = 9 }
        for symbol in 256 ..< 280 { lengths[symbol] = 7 }
        return (Huffman(lengths: lengths[...]), Huffman(lengths: [Int](repeating: 5, count: 30)[...]))
    }()

    mutating func run() throws {
        var last = false
        repeat {
            last = try bits(1) == 1
            switch try bits(2) {
            case 0: try stored()
            case 1: try codes(Self.fixed.0, Self.fixed.1)
            case 2:
                let (literals, distances) = try dynamicTables()
                try codes(literals, distances)
            default: throw Inflate.Failure.corrupt
            }
        } while !last
    }

    private mutating func bits(_ count: Int) throws -> Int {
        var value = bitBuffer
        while bitCount < count {
            guard position < input.count else { throw Inflate.Failure.corrupt }
            value |= Int(input[position]) << bitCount
            position += 1
            bitCount += 8
        }
        bitBuffer = value >> count
        bitCount -= count
        return value & ((1 << count) - 1)
    }

    private mutating func stored() throws {
        bitBuffer = 0
        bitCount = 0
        guard position + 4 <= input.count else { throw Inflate.Failure.corrupt }
        let length = Int(input[position]) | Int(input[position + 1]) << 8
        let complement = Int(input[position + 2]) | Int(input[position + 3]) << 8
        guard length == ~complement & 0xffff else { throw Inflate.Failure.corrupt }
        position += 4
        guard position + length <= input.count else { throw Inflate.Failure.corrupt }
        output.append(contentsOf: input[position ..< position + length])
        position += length
    }

    private mutating func decode(_ huffman: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for length in 1 ..< 16 {
            code |= try bits(1)
            let count = huffman.counts[length]
            if code - count < first { return huffman.symbols[index + (code - first)] }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw Inflate.Failure.corrupt
    }

    private mutating func codes(_ literals: Huffman, _ distances: Huffman) throws {
        while true {
            let symbol = try decode(literals)
            if symbol < 256 {
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let lengthIndex = symbol - 257
                guard lengthIndex < 29 else { throw Inflate.Failure.corrupt }
                let length = Self.lengthBase[lengthIndex] + (try bits(Self.lengthExtra[lengthIndex]))
                let distanceIndex = try decode(distances)
                guard distanceIndex < 30 else { throw Inflate.Failure.corrupt }
                let distance = Self.distanceBase[distanceIndex] + (try bits(Self.distanceExtra[distanceIndex]))
                guard distance <= output.count else { throw Inflate.Failure.corrupt }
                let start = output.count - distance
                for offset in 0 ..< length { output.append(output[start + offset]) }
            }
        }
    }

    private mutating func dynamicTables() throws -> (Huffman, Huffman) {
        let literalCount = try bits(5) + 257
        let distanceCount = try bits(5) + 1
        let codeLengthCount = try bits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw Inflate.Failure.corrupt }
        var codeLengths = [Int](repeating: 0, count: 19)
        for index in 0 ..< codeLengthCount { codeLengths[Self.codeLengthOrder[index]] = try bits(3) }
        let lengthCode = Huffman(lengths: codeLengths[...])
        guard !lengthCode.isOversubscribed else { throw Inflate.Failure.corrupt }

        var lengths = [Int](repeating: 0, count: literalCount + distanceCount)
        var index = 0
        while index < lengths.count {
            let symbol = try decode(lengthCode)
            if symbol < 16 {
                lengths[index] = symbol
                index += 1
                continue
            }
            var repeated = 0
            let count: Int
            switch symbol {
            case 16:
                guard index > 0 else { throw Inflate.Failure.corrupt }
                repeated = lengths[index - 1]
                count = 3 + (try bits(2))
            case 17: count = 3 + (try bits(3))
            default: count = 11 + (try bits(7))
            }
            guard index + count <= lengths.count else { throw Inflate.Failure.corrupt }
            for _ in 0 ..< count {
                lengths[index] = repeated
                index += 1
            }
        }
        let literals = Huffman(lengths: lengths[0 ..< literalCount])
        let distances = Huffman(lengths: lengths[literalCount...])
        guard lengths[256] != 0, !literals.isOversubscribed, !distances.isOversubscribed else { throw Inflate.Failure.corrupt }
        return (literals, distances)
    }
}
