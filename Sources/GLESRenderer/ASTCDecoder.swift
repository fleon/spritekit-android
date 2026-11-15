import Foundation

/// Decodes ASTC LDR blocks to RGBA8 on the CPU.
///
/// The packed pages ship ASTC (`CompressedPage`), which the GPU samples as
/// it is. A few things still want their pixels on the CPU: the game draws
/// some packed images into CoreGraphics surfaces (ledges' mitred ends, the
/// Mainframe's floor, share avatars: `UIImage(named:)`), shaders sample an
/// atlas image cut out of its page (`ResourceCache.cutOut`), and a GPU
/// without ASTC (no `GL_KHR_texture_compression_astc_ldr`) takes the page
/// as RGBA8 instead. This covers what android-art.js's astcenc writes: 2D
/// blocks, every LDR endpoint mode, one to four partitions and dual planes;
/// HDR and 3D blocks decode to the error colour, as a GPU would show them.
///
/// Each texel is the top byte of the 16-bit value the format interpolates,
/// which is what astcenc's own decoder writes to an 8-bit image
/// (`ASTCDecoderTests` holds it to that byte for byte).
public struct ASTCDecoder {
    public let blockWidth: Int
    public let blockHeight: Int

    public init(blockWidth: Int, blockHeight: Int) {
        self.blockWidth = blockWidth
        self.blockHeight = blockHeight
    }

    /// The texels of `region` (in texels, counted as the data's rows run)
    /// of a `width`×`height` level whose blocks are `data`, RGBA8,
    /// premultiplied if the data was, rows in the data's order.
    public func decode(_ data: Data, width: Int, height: Int, region: (x: Int, y: Int, width: Int, height: Int)? = nil) -> [UInt8] {
        let area = region ?? (0, 0, width, height)
        guard area.width > 0, area.height > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: area.width * area.height * 4)
        let across = (width + blockWidth - 1) / blockWidth
        let down = (height + blockHeight - 1) / blockHeight
        guard data.count >= across * down * 16 else { return out }
        var state = State(blockWidth: blockWidth, blockHeight: blockHeight)
        var texels = [UInt8](repeating: 0, count: blockWidth * blockHeight * 4)
        let firstColumn = max(0, area.x / blockWidth), lastColumn = min(across - 1, (area.x + area.width - 1) / blockWidth)
        let firstRow = max(0, area.y / blockHeight), lastRow = min(down - 1, (area.y + area.height - 1) / blockHeight)
        guard firstColumn <= lastColumn, firstRow <= lastRow else { return out }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for row in firstRow ... lastRow {
                for column in firstColumn ... lastColumn {
                    let at = (row * across + column) * 16
                    let lo = raw.loadUnaligned(fromByteOffset: at, as: UInt64.self).littleEndian
                    let hi = raw.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self).littleEndian
                    state.decodeBlock(lo: lo, hi: hi, into: &texels)
                    for ty in 0 ..< blockHeight {
                        let y = row * blockHeight + ty - area.y
                        guard y >= 0, y < area.height else { continue }
                        for tx in 0 ..< blockWidth {
                            let x = column * blockWidth + tx - area.x
                            guard x >= 0, x < area.width else { continue }
                            let from = (ty * blockWidth + tx) * 4, to = (y * area.width + x) * 4
                            out[to] = texels[from]
                            out[to + 1] = texels[from + 1]
                            out[to + 2] = texels[from + 2]
                            out[to + 3] = texels[from + 3]
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: Ranges

    /// The 21 integer ranges ASTC encodes, as (trits, quints, bits).
    fileprivate static let ranges: [(trits: Bool, quints: Bool, bits: Int)] = [
        (false, false, 1), (true, false, 0), (false, false, 2), (false, true, 0), (true, false, 1),
        (false, false, 3), (false, true, 1), (true, false, 2), (false, false, 4), (false, true, 2),
        (true, false, 3), (false, false, 5), (false, true, 3), (true, false, 4), (false, false, 6),
        (false, true, 4), (true, false, 5), (false, false, 7), (false, true, 5), (true, false, 6),
        (false, false, 8),
    ]

    /// Bits `count` integers of `range` take.
    fileprivate static func iseBits(_ count: Int, range: Int) -> Int {
        let r = ranges[range]
        if r.trits { return count * r.bits + (8 * count + 4) / 5 }
        if r.quints { return count * r.bits + (7 * count + 2) / 3 }
        return count * r.bits
    }

    /// Each range's integers unquantized to 0…255 (colour endpoints), by
    /// the integer as encoded: the spec's bit-replicate and its
    /// `T = D·C + B; T ^= A` for trits and quints.
    fileprivate static let colorTables: [[Int]] = ranges.indices.map { range in
        let r = ranges[range]
        let size = (r.trits ? 3 : r.quints ? 5 : 1) << r.bits
        return (0 ..< size).map { value in
            if !r.trits, !r.quints { return replicate(value, bits: r.bits, to: 8) }
            let n = r.bits, m = value & ((1 << n) - 1), d = value >> n
            let a = m & 1 == 1 ? 0x1FF : 0
            let pattern: String, c: Int
            if r.trits {
                c = [0, 204, 93, 44, 22, 11, 5][n]
                pattern = ["000000000", "000000000", "b000b0bb0", "cb000cbcb", "dcb000dcb", "edcb000ed", "fedcb000f"][n]
            } else {
                c = [0, 113, 54, 26, 13, 6][n]
                pattern = ["000000000", "000000000", "b0000bb00", "cb0000cbc", "dcb0000dc", "edcb0000e"][n]
            }
            var t = d * c + bitPattern(pattern, m)
            t ^= a
            return (a & 0x80) | (t >> 2)
        }
    }

    /// Ranges 0…11 unquantized to weights of 0…64.
    fileprivate static let weightTables: [[Int]] = (0 ..< 12).map { range in
        let r = ranges[range]
        let size = (r.trits ? 3 : r.quints ? 5 : 1) << r.bits
        return (0 ..< size).map { value in
            var t: Int
            if !r.trits, !r.quints {
                t = replicate(value, bits: r.bits, to: 6)
            } else if r.bits == 0 {
                t = r.trits ? [0, 32, 63][value] : [0, 16, 32, 47, 63][value]
            } else {
                let n = r.bits, m = value & ((1 << n) - 1), d = value >> n
                let a = m & 1 == 1 ? 0x7F : 0
                let c: Int, pattern: String
                if r.trits {
                    c = [0, 50, 23, 11][n]
                    pattern = ["", "0000000", "b000b0b", "cb000cb"][n]
                } else {
                    c = [0, 28, 13][n]
                    pattern = ["", "0000000", "b0000b0"][n]
                }
                t = d * c + bitPattern(pattern, m)
                t ^= a
                t = (a & 0x20) | (t >> 2)
            }
            return t > 32 ? t + 1 : t
        }
    }

    private static func replicate(_ value: Int, bits: Int, to width: Int) -> Int {
        var out = 0, have = 0
        while have < width {
            out = (out << bits) | value
            have += bits
        }
        return out >> (have - width)
    }

    /// The spec's patterns, `b` the value's second bit, `c` its third, and so on.
    private static func bitPattern(_ pattern: String, _ m: Int) -> Int {
        var out = 0
        for character in pattern.utf8 {
            let bit: Int
            switch character {
            case UInt8(ascii: "b"): bit = (m >> 1) & 1
            case UInt8(ascii: "c"): bit = (m >> 2) & 1
            case UInt8(ascii: "d"): bit = (m >> 3) & 1
            case UInt8(ascii: "e"): bit = (m >> 4) & 1
            case UInt8(ascii: "f"): bit = (m >> 5) & 1
            default: bit = 0
            }
            out = (out << 1) | bit
        }
        return out
    }
}

// MARK: - One block

private struct Bits128 {
    var lo: UInt64
    var hi: UInt64

    /// `count` bits (at most 32) from `at`; bits past the end read as zero.
    func read(_ at: Int, _ count: Int) -> Int {
        guard count > 0, at < 128 else { return 0 }
        var value: UInt64
        if at >= 64 {
            value = hi >> UInt64(at - 64)
        } else if at == 0 {
            value = lo
        } else {
            value = (lo >> UInt64(at)) | (hi << UInt64(64 - at))
        }
        return Int(value & ((1 << UInt64(count)) - 1))
    }

    /// The block's bits in reverse order: where the weights are read from.
    var reversed: Bits128 { Bits128(lo: Self.reverse(hi), hi: Self.reverse(lo)) }

    private static func reverse(_ x: UInt64) -> UInt64 {
        var v = x
        v = ((v >> 1) & 0x5555_5555_5555_5555) | ((v & 0x5555_5555_5555_5555) << 1)
        v = ((v >> 2) & 0x3333_3333_3333_3333) | ((v & 0x3333_3333_3333_3333) << 2)
        v = ((v >> 4) & 0x0F0F_0F0F_0F0F_0F0F) | ((v & 0x0F0F_0F0F_0F0F_0F0F) << 4)
        return v.byteSwapped
    }
}

private struct Bounded {
    let bits: Bits128
    let end: Int

    func read(_ at: Int, _ count: Int) -> Int {
        let usable = min(count, end - at)
        return usable > 0 ? bits.read(at, usable) : 0
    }
}

private struct State {
    let blockWidth: Int
    let blockHeight: Int
    /// Bilinear infill from a weight grid to the block's texels, by grid size.
    private var infills: [Int: [(Int, Int, Int, Int, Int, Int, Int, Int)]] = [:]
    private var ise = [Int](repeating: 0, count: 64)
    private var colors = [Int](repeating: 0, count: 18)
    private var gridWeights = [Int](repeating: 0, count: 64)
    private var texelWeights = [Int](repeating: 0, count: 144 * 2)
    /// Each texel's partition, by partition count and seed.
    private var partitions: [Int: [UInt8]] = [:]
    /// Endpoint pairs, eight values a partition (e0 RGBA, e1 RGBA).
    private var ends = [Int](repeating: 0, count: 32)
    private var modes = [0, 0, 0, 0]

    init(blockWidth: Int, blockHeight: Int) {
        self.blockWidth = blockWidth
        self.blockHeight = blockHeight
    }

    mutating func decodeBlock(lo: UInt64, hi: UInt64, into out: inout [UInt8]) {
        let block = Bits128(lo: lo, hi: hi)
        let texels = blockWidth * blockHeight
        let mode = block.read(0, 11)

        // A void extent: one colour over the block.
        if mode & 0x1FF == 0x1FC {
            guard mode & 0x200 == 0 else { return error(&out) }
            let r = UInt8(block.read(64, 16) >> 8), g = UInt8(block.read(80, 16) >> 8)
            let b = UInt8(block.read(96, 16) >> 8), a = UInt8(block.read(112, 16) >> 8)
            for t in 0 ..< texels {
                out[t * 4] = r
                out[t * 4 + 1] = g
                out[t * 4 + 2] = b
                out[t * 4 + 3] = a
            }
            return
        }

        guard let shape = Self.blockMode(mode) else { return error(&out) }
        guard shape.width <= blockWidth, shape.height <= blockHeight else { return error(&out) }
        let planes = shape.dualPlane ? 2 : 1
        let weightCount = shape.width * shape.height * planes
        guard weightCount <= 64 else { return error(&out) }
        let weightBits = ASTCDecoder.iseBits(weightCount, range: shape.range)
        guard weightBits >= 24, weightBits <= 96 else { return error(&out) }

        let partitions = block.read(11, 2) + 1
        guard !(shape.dualPlane && partitions == 4) else { return error(&out) }

        // Endpoint modes.
        var belowWeights = 128 - weightBits
        var extraBits = 0
        if partitions == 1 {
            modes[0] = block.read(13, 4)
        } else {
            let selector = block.read(23, 6)
            if selector & 3 == 0 {
                for p in 0 ..< partitions { modes[p] = (selector >> 2) & 0xF }
            } else {
                extraBits = 3 * partitions - 4
                belowWeights -= extraBits
                let encoded = selector | (block.read(belowWeights, extraBits) << 6)
                let base = (encoded & 3) - 1
                var at = 2
                for p in 0 ..< partitions {
                    modes[p] = (((encoded >> at) & 1) + base) << 2
                    at += 1
                }
                for p in 0 ..< partitions {
                    modes[p] |= (encoded >> at) & 3
                    at += 2
                }
            }
        }
        var integerCount = 0
        for p in 0 ..< partitions { integerCount += ((modes[p] >> 2) + 1) * 2 }
        guard integerCount <= 18 else { return error(&out) }

        var colorBits = (partitions == 1 ? 111 : 99) - weightBits - extraBits
        if shape.dualPlane { colorBits -= 2 }
        var colorRange = -1
        for range in stride(from: 20, through: 4, by: -1) where ASTCDecoder.iseBits(integerCount, range: range) <= colorBits {
            colorRange = range
            break
        }
        guard colorRange >= 4 else { return error(&out) }

        readISE(block, from: partitions == 1 ? 17 : 29, count: integerCount, range: colorRange)
        let colorTable = ASTCDecoder.colorTables[colorRange]
        for i in 0 ..< integerCount { colors[i] = colorTable[ise[i]] }

        var consumed = 0
        for p in 0 ..< partitions {
            guard let pair = Self.endpoints(mode: modes[p], colors, from: consumed) else { return error(&out) }
            ends[p * 8] = pair.e0.0; ends[p * 8 + 1] = pair.e0.1; ends[p * 8 + 2] = pair.e0.2; ends[p * 8 + 3] = pair.e0.3
            ends[p * 8 + 4] = pair.e1.0; ends[p * 8 + 5] = pair.e1.1; ends[p * 8 + 6] = pair.e1.2; ends[p * 8 + 7] = pair.e1.3
            consumed += ((modes[p] >> 2) + 1) * 2
        }

        // Weights, read from the top of the block down.
        readISE(block.reversed, from: 0, count: weightCount, range: shape.range)
        let weightTable = ASTCDecoder.weightTables[shape.range]
        for i in 0 ..< weightCount { gridWeights[i] = weightTable[ise[i]] }
        let planeTwo = shape.dualPlane ? block.read(belowWeights - 2, 2) : -1
        infill(gridWidth: shape.width, gridHeight: shape.height, planes: planes)

        let seed = partitions > 1 ? block.read(13, 10) : 0
        let assignment = partitions > 1 ? partitionTable(seed: seed, count: partitions) : nil
        for t in 0 ..< texels {
            let p = assignment.map { Int($0[t]) } ?? 0
            let e = p * 8
            let w1 = texelWeights[t * planes]
            let w2 = shape.dualPlane ? texelWeights[t * planes + 1] : w1
            out[t * 4] = Self.lerp(ends[e], ends[e + 4], planeTwo == 0 ? w2 : w1)
            out[t * 4 + 1] = Self.lerp(ends[e + 1], ends[e + 5], planeTwo == 1 ? w2 : w1)
            out[t * 4 + 2] = Self.lerp(ends[e + 2], ends[e + 6], planeTwo == 2 ? w2 : w1)
            out[t * 4 + 3] = Self.lerp(ends[e + 3], ends[e + 7], planeTwo == 3 ? w2 : w1)
        }
    }

    /// Which partition each texel of the block falls in, worked out once a seed.
    private mutating func partitionTable(seed: Int, count: Int) -> [UInt8] {
        let key = count << 10 | seed
        if let known = partitions[key] { return known }
        let small = blockWidth * blockHeight < 32
        var table = [UInt8](repeating: 0, count: blockWidth * blockHeight)
        for y in 0 ..< blockHeight {
            for x in 0 ..< blockWidth {
                table[y * blockWidth + x] = UInt8(Self.partition(seed: seed, x: x, y: y, count: count, small: small))
            }
        }
        partitions[key] = table
        return table
    }

    private static func lerp(_ a: Int, _ b: Int, _ w: Int) -> UInt8 {
        let value = (a * 257 * (64 - w) + b * 257 * w + 32) >> 6
        return UInt8(value >> 8)
    }

    /// The error colour: opaque magenta, as the spec has a decoder show a block it can't read.
    private func error(_ out: inout [UInt8]) {
        for t in 0 ..< blockWidth * blockHeight {
            out[t * 4] = 255
            out[t * 4 + 1] = 0
            out[t * 4 + 2] = 255
            out[t * 4 + 3] = 255
        }
    }

    // MARK: Block mode

    private static func blockMode(_ mode: Int) -> (width: Int, height: Int, dualPlane: Bool, range: Int)? {
        var base = (mode >> 4) & 1
        var high = (mode >> 9) & 1
        var dual = (mode >> 10) & 1
        let a = (mode >> 5) & 3
        var width = 0, height = 0
        if mode & 3 != 0 {
            base |= (mode & 3) << 1
            var b = (mode >> 7) & 3
            switch (mode >> 2) & 3 {
            case 0: width = b + 4; height = a + 2
            case 1: width = b + 8; height = a + 2
            case 2: width = a + 2; height = b + 8
            default:
                b &= 1
                if mode & 0x100 != 0 {
                    width = b + 2; height = a + 2
                } else {
                    width = a + 2; height = b + 6
                }
            }
        } else {
            base |= ((mode >> 2) & 3) << 1
            guard (mode >> 2) & 3 != 0 else { return nil }
            let b = (mode >> 9) & 3
            switch (mode >> 7) & 3 {
            case 0: width = 12; height = a + 2
            case 1: width = a + 2; height = 12
            case 2:
                width = a + 6; height = b + 6
                dual = 0
                high = 0
            default:
                switch (mode >> 5) & 3 {
                case 0: width = 6; height = 10
                case 1: width = 10; height = 6
                default: return nil
                }
            }
        }
        let range = base - 2 + 6 * high
        guard range >= 0, range < 12 else { return nil }
        return (width, height, dual != 0, range)
    }

    // MARK: Integer sequences

    /// Decodes `count` integers of `range` from `bits` at `from` into `ise`.
    private mutating func readISE(_ block: Bits128, from start: Int, count: Int, range: Int) {
        let r = ASTCDecoder.ranges[range]
        // Bits past the sequence's end read as zero: a last group of trits
        // or quints is cut short, the rest of its packed value taken as 0.
        let bits = Bounded(bits: block, end: start + ASTCDecoder.iseBits(count, range: range))
        let n = r.bits
        var at = start
        if r.trits {
            var i = 0
            while i < count {
                var t = 0
                let m0 = bits.read(at, n); at += n
                t |= bits.read(at, 2); at += 2
                let m1 = bits.read(at, n); at += n
                t |= bits.read(at, 2) << 2; at += 2
                let m2 = bits.read(at, n); at += n
                t |= bits.read(at, 1) << 4; at += 1
                let m3 = bits.read(at, n); at += n
                t |= bits.read(at, 2) << 5; at += 2
                let m4 = bits.read(at, n); at += n
                t |= bits.read(at, 1) << 7; at += 1
                let trits = Self.tritTable[t]
                if i < count { ise[i] = (trits.0 << n) | m0 }
                if i + 1 < count { ise[i + 1] = (trits.1 << n) | m1 }
                if i + 2 < count { ise[i + 2] = (trits.2 << n) | m2 }
                if i + 3 < count { ise[i + 3] = (trits.3 << n) | m3 }
                if i + 4 < count { ise[i + 4] = (trits.4 << n) | m4 }
                i += 5
            }
        } else if r.quints {
            var i = 0
            while i < count {
                var q = 0
                let m0 = bits.read(at, n); at += n
                q |= bits.read(at, 3); at += 3
                let m1 = bits.read(at, n); at += n
                q |= bits.read(at, 2) << 3; at += 2
                let m2 = bits.read(at, n); at += n
                q |= bits.read(at, 2) << 5; at += 2
                let quints = Self.quintTable[q]
                if i < count { ise[i] = (quints.0 << n) | m0 }
                if i + 1 < count { ise[i + 1] = (quints.1 << n) | m1 }
                if i + 2 < count { ise[i + 2] = (quints.2 << n) | m2 }
                i += 3
            }
        } else {
            for i in 0 ..< count {
                ise[i] = bits.read(at, n)
                at += n
            }
        }
    }

    private static func bit(_ v: Int, _ i: Int) -> Int { (v >> i) & 1 }

    private static let tritTable: [(Int, Int, Int, Int, Int)] = (0 ..< 256).map { t in
        let v = trits(t)
        return (v[0], v[1], v[2], v[3], v[4])
    }

    private static let quintTable: [(Int, Int, Int)] = (0 ..< 128).map { q in
        let v = quints(q)
        return (v[0], v[1], v[2])
    }

    private static func trits(_ t: Int) -> [Int] {
        var c: Int, t3: Int, t4: Int
        if (t >> 2) & 7 == 7 {
            c = (((t >> 5) & 7) << 2) | (t & 3)
            t4 = 2
            t3 = 2
        } else {
            c = t & 0x1F
            if (t >> 5) & 3 == 3 {
                t4 = 2
                t3 = bit(t, 7)
            } else {
                t4 = bit(t, 7)
                t3 = (t >> 5) & 3
            }
        }
        let t0: Int, t1: Int, t2: Int
        if c & 3 == 3 {
            t2 = 2
            t1 = bit(c, 4)
            t0 = (bit(c, 3) << 1) | (bit(c, 2) & ~bit(c, 3) & 1)
        } else if (c >> 2) & 3 == 3 {
            t2 = 2
            t1 = 2
            t0 = c & 3
        } else {
            t2 = bit(c, 4)
            t1 = (c >> 2) & 3
            t0 = (bit(c, 1) << 1) | (bit(c, 0) & ~bit(c, 1) & 1)
        }
        return [t0, t1, t2, t3, t4]
    }

    private static func quints(_ q: Int) -> [Int] {
        let q0: Int, q1: Int, q2: Int
        if (q >> 1) & 3 == 3, (q >> 5) & 3 == 0 {
            q2 = (bit(q, 0) << 2) | ((bit(q, 4) & ~bit(q, 0) & 1) << 1) | (bit(q, 3) & ~bit(q, 0) & 1)
            q1 = 4
            q0 = 4
        } else {
            let c: Int
            if (q >> 1) & 3 == 3 {
                q2 = 4
                c = (((q >> 3) & 3) << 3) | ((~(q >> 5) & 3) << 1) | bit(q, 0)
            } else {
                q2 = (q >> 5) & 3
                c = q & 0x1F
            }
            if c & 7 == 5 {
                q1 = 4
                q0 = (c >> 3) & 3
            } else {
                q1 = (c >> 3) & 3
                q0 = c & 7
            }
        }
        return [q0, q1, q2]
    }

    // MARK: Endpoints

    private typealias Colour = (Int, Int, Int, Int)

    private static func endpoints(mode: Int, _ v: [Int], from i: Int) -> (e0: Colour, e1: Colour)? {
        func clamped(_ c: Colour) -> Colour {
            (min(255, max(0, c.0)), min(255, max(0, c.1)), min(255, max(0, c.2)), min(255, max(0, c.3)))
        }
        func transfer(_ a: Int, _ b: Int) -> (a: Int, b: Int) {
            // bit_transfer_signed: b takes a's top bit, a becomes a signed 6-bit delta.
            var b = b >> 1
            b |= a & 0x80
            var a = (a >> 1) & 0x3F
            if a & 0x20 != 0 { a -= 0x40 }
            return (a, b)
        }
        func blueContract(_ c: Colour) -> Colour { ((c.0 + c.2) >> 1, (c.1 + c.2) >> 1, c.2, c.3) }
        switch mode {
        case 0:
            return ((v[i], v[i], v[i], 255), (v[i + 1], v[i + 1], v[i + 1], 255))
        case 1:
            let l0 = (v[i] >> 2) | (v[i + 1] & 0xC0)
            let l1 = min(255, l0 + (v[i + 1] & 0x3F))
            return ((l0, l0, l0, 255), (l1, l1, l1, 255))
        case 4:
            return ((v[i], v[i], v[i], v[i + 2]), (v[i + 1], v[i + 1], v[i + 1], v[i + 3]))
        case 5:
            let l = transfer(v[i + 1], v[i]), a = transfer(v[i + 3], v[i + 2])
            let e0: Colour = (l.b, l.b, l.b, a.b)
            return (e0, clamped((l.b + l.a, l.b + l.a, l.b + l.a, a.b + a.a)))
        case 6:
            let s = v[i + 3]
            return (((v[i] * s) >> 8, (v[i + 1] * s) >> 8, (v[i + 2] * s) >> 8, 255), (v[i], v[i + 1], v[i + 2], 255))
        case 8, 12:
            let alpha = mode == 12
            var e0: Colour = (v[i], v[i + 2], v[i + 4], alpha ? v[i + 6] : 255)
            var e1: Colour = (v[i + 1], v[i + 3], v[i + 5], alpha ? v[i + 7] : 255)
            if e0.0 + e0.1 + e0.2 > e1.0 + e1.1 + e1.2 {
                (e0, e1) = (blueContract(e1), blueContract(e0))
            }
            return (e0, e1)
        case 9, 13:
            let alpha = mode == 13
            let r = transfer(v[i + 1], v[i]), g = transfer(v[i + 3], v[i + 2]), b = transfer(v[i + 5], v[i + 4])
            let a = alpha ? transfer(v[i + 7], v[i + 6]) : (a: 0, b: 255)
            var e0: Colour = (r.b, g.b, b.b, a.b)
            var e1: Colour = (r.b + r.a, g.b + g.a, b.b + b.a, alpha ? a.b + a.a : 255)
            if r.a + g.a + b.a < 0 {
                (e0, e1) = (blueContract(e1), blueContract(e0))
            }
            return (clamped(e0), clamped(e1))
        case 10:
            let s = v[i + 3]
            return (((v[i] * s) >> 8, (v[i + 1] * s) >> 8, (v[i + 2] * s) >> 8, v[i + 4]), (v[i], v[i + 1], v[i + 2], v[i + 5]))
        default:
            // HDR modes (2, 3, 7, 11, 14, 15): never written for these pages.
            return nil
        }
    }

    // MARK: Partitions

    private static func hash52(_ input: UInt32) -> UInt32 {
        var p = input
        p ^= p >> 15
        p &*= 0xEEDE_0891
        p ^= p >> 5
        p &+= p << 16
        p ^= p >> 7
        p ^= p >> 3
        p ^= p << 6
        p ^= p >> 17
        return p
    }

    private static func partition(seed rawSeed: Int, x: Int, y: Int, count: Int, small: Bool) -> Int {
        let x = small ? x << 1 : x, y = small ? y << 1 : y
        let seed = rawSeed + (count - 1) * 1024
        let rnum = hash52(UInt32(seed))
        var s = [Int](repeating: 0, count: 12)
        let shifts: [UInt32] = [0, 4, 8, 12, 16, 20, 24, 28, 18, 22, 26]
        for k in 0 ..< 11 { s[k] = Int((rnum >> shifts[k]) & 0xF) }
        s[11] = Int(((rnum >> 30) | (rnum << 2)) & 0xF)
        for k in 0 ..< 12 { s[k] *= s[k] }
        let sh1: Int, sh2: Int
        if seed & 1 != 0 {
            sh1 = seed & 2 != 0 ? 4 : 5
            sh2 = count == 3 ? 6 : 5
        } else {
            sh1 = count == 3 ? 6 : 5
            sh2 = seed & 2 != 0 ? 4 : 5
        }
        let sh3 = seed & 0x10 != 0 ? sh1 : sh2
        for k in 0 ..< 8 { s[k] >>= k % 2 == 0 ? sh1 : sh2 }
        for k in 8 ..< 12 { s[k] >>= sh3 }
        let r = Int(rnum)
        var a = s[0] * x + s[1] * y + (r >> 14)
        var b = s[2] * x + s[3] * y + (r >> 10)
        var c = s[4] * x + s[5] * y + (r >> 6)
        var d = s[6] * x + s[7] * y + (r >> 2)
        a &= 0x3F; b &= 0x3F; c &= 0x3F; d &= 0x3F
        if count <= 3 { d = 0 }
        if count <= 2 { c = 0 }
        if a >= b, a >= c, a >= d { return 0 }
        if b >= c, b >= d { return 1 }
        if c >= d { return 2 }
        return 3
    }

    // MARK: Weight infill

    /// Spreads the grid's weights over the block's texels (`texelWeights`,
    /// plane by plane per texel) by the spec's bilinear infill.
    private mutating func infill(gridWidth: Int, gridHeight: Int, planes: Int) {
        let key = gridWidth << 8 | gridHeight
        if infills[key] == nil {
            var table: [(Int, Int, Int, Int, Int, Int, Int, Int)] = []
            let ds = (1024 + blockWidth / 2) / max(1, blockWidth - 1)
            let dt = (1024 + blockHeight / 2) / max(1, blockHeight - 1)
            for t in 0 ..< blockHeight {
                for s in 0 ..< blockWidth {
                    let gs = (ds * s * (gridWidth - 1) + 32) >> 6
                    let gt = (dt * t * (gridHeight - 1) + 32) >> 6
                    let js = gs >> 4, fs = gs & 0xF
                    let jt = gt >> 4, ft = gt & 0xF
                    let v0 = js + jt * gridWidth
                    let w11 = (fs * ft + 8) >> 4
                    let w10 = ft - w11
                    let w01 = fs - w11
                    let w00 = 16 - fs - ft + w11
                    // Grid indices past the grid's edge come with a zero factor.
                    let p01 = js + 1 < gridWidth ? v0 + 1 : v0
                    let p10 = jt + 1 < gridHeight ? v0 + gridWidth : v0
                    let p11 = js + 1 < gridWidth && jt + 1 < gridHeight ? v0 + gridWidth + 1 : v0
                    table.append((v0, p01, p10, p11, w00, w01, w10, w11))
                }
            }
            infills[key] = table
        }
        guard let table = infills[key] else { return }
        for (t, e) in table.enumerated() {
            for plane in 0 ..< planes {
                let w = (gridWeights[e.0 * planes + plane] * e.4 + gridWeights[e.1 * planes + plane] * e.5
                    + gridWeights[e.2 * planes + plane] * e.6 + gridWeights[e.3 * planes + plane] * e.7 + 8) >> 4
                texelWeights[t * planes + plane] = w
            }
        }
    }
}
