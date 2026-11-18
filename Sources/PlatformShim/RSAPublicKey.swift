import Foundation

/// An RSA public key and PKCS #1 v1.5 encryption with it (RFC 8017, 7.2.1),
/// for a game that encrypts a token to its server's key as Security's
/// `SecKeyCreateEncryptedData(_:.rsaEncryptionPKCS1,_:_:)` does. Plain
/// Swift; `Security` in `Modules` puts Apple's names on it, and the tests
/// decrypt what it writes with Security's own private key on the Mac.
public struct RSAPublicKey: Equatable, Sendable {
    /// The modulus and the public exponent, big-endian, without leading zeros.
    public let modulus: [UInt8]
    public let exponent: [UInt8]

    /// The modulus' length in bytes: what a ciphertext is long.
    public var blockSize: Int { modulus.count }

    /// A PKCS #1 `RSAPublicKey` (DER: a SEQUENCE of the modulus and the
    /// exponent), the one form `SecKeyCreateWithData` takes for a public key.
    public init?(pkcs1 der: Data) {
        var reader = DERReader(bytes: Array(der))
        guard var sequence = reader.read(tag: 0x30), reader.isAtEnd,
              let modulus = sequence.readInteger(), let exponent = sequence.readInteger(), sequence.isAtEnd,
              let last = modulus.last, last & 1 == 1, modulus.count >= 64, !exponent.isEmpty
        else { return nil }
        self.modulus = modulus
        self.exponent = exponent
    }

    /// `message` padded (`0x00 0x02`, at least eight random non-zero bytes,
    /// `0x00`) and raised to the exponent: `blockSize` bytes, or nil when the
    /// message is longer than `blockSize - 11`. `random` fills the padding
    /// (a test passes its own).
    public func encryptPKCS1(
        _ message: Data,
        random: (inout [UInt8]) -> Void = RSAPublicKey.systemRandom
    ) -> Data? {
        let k = blockSize
        guard message.count <= k - 11 else { return nil }
        var padding = [UInt8](repeating: 0, count: k - message.count - 3)
        random(&padding)
        for index in padding.indices {
            while padding[index] == 0 {
                var one: [UInt8] = [0]
                random(&one)
                padding[index] = one[0]
            }
        }
        let block = [0x00, 0x02] + padding + [0x00] + Array(message)
        let modulus = Montgomery(modulus: Limbs(bigEndian: self.modulus))
        let result = modulus.power(Limbs(bigEndian: block), exponent: exponent)
        return Data(result.bigEndian(count: k))
    }

    /// The system's generator, as Security pads with.
    public static func systemRandom(_ bytes: inout [UInt8]) {
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
    }
}

// MARK: - DER

/// Just enough DER for a public key: definite lengths, primitive INTEGERs.
private struct DERReader {
    var bytes: ArraySlice<UInt8>

    init(bytes: [UInt8]) { self.bytes = bytes[...] }
    private init(slice: ArraySlice<UInt8>) { bytes = slice }

    var isAtEnd: Bool { bytes.isEmpty }

    mutating func read(tag: UInt8) -> DERReader? {
        guard bytes.first == tag else { return nil }
        bytes.removeFirst()
        guard let first = bytes.popFirst() else { return nil }
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7f)
            guard count >= 1, count <= 4, bytes.count >= count else { return nil }
            for _ in 0 ..< count { length = length << 8 | Int(bytes.removeFirst()) }
        }
        guard bytes.count >= length else { return nil }
        let content = bytes.prefix(length)
        bytes.removeFirst(length)
        return DERReader(slice: content)
    }

    /// A non-negative INTEGER's magnitude, leading zeros dropped.
    mutating func readInteger() -> [UInt8]? {
        guard let integer = read(tag: 0x02), let first = integer.bytes.first, first & 0x80 == 0 else { return nil }
        return Array(integer.bytes.drop { $0 == 0 })
    }
}

// MARK: - Arithmetic

/// A non-negative number in 32-bit limbs, least significant first.
private struct Limbs {
    var words: [UInt32]

    init(words: [UInt32]) { self.words = words }

    init(bigEndian bytes: [UInt8]) {
        var words = [UInt32](repeating: 0, count: max(1, (bytes.count + 3) / 4))
        for (offset, byte) in bytes.reversed().enumerated() {
            words[offset / 4] |= UInt32(byte) << (8 * UInt32(offset % 4))
        }
        self.words = words
    }

    func bigEndian(count: Int) -> [UInt8] {
        (0 ..< count).reversed().map { offset in
            let word = offset / 4
            return word < words.count ? UInt8(truncatingIfNeeded: words[word] >> (8 * UInt32(offset % 4))) : 0
        }
    }

    /// Padded with zero limbs (or cut) to `count`.
    func resized(_ count: Int) -> [UInt32] {
        words.count >= count ? Array(words.prefix(count)) : words + [UInt32](repeating: 0, count: count - words.count)
    }
}

/// Montgomery multiplication modulo an odd modulus (CIOS).
private struct Montgomery {
    let n: [UInt32]
    /// -n⁻¹ mod 2³².
    let inverse: UInt32
    /// R² mod n, R = 2^(32·limbs).
    let rSquared: [UInt32]

    init(modulus: Limbs) {
        var n = modulus.words
        while n.count > 1, n.last == 0 { n.removeLast() }
        self.n = n
        // Newton's iteration for n[0]⁻¹ mod 2³² (n[0] is odd).
        var x: UInt32 = 1
        for _ in 0 ..< 5 { x = x &* (2 &- n[0] &* x) }
        inverse = 0 &- x
        // R² mod n by doubling 1, 2·32·limbs times.
        var value = [UInt32](repeating: 0, count: n.count)
        value[0] = 1
        for _ in 0 ..< 64 * n.count { value = Self.doubled(value, modulo: n) }
        rSquared = value
    }

    private static func doubled(_ value: [UInt32], modulo n: [UInt32]) -> [UInt32] {
        var result = value
        var carry: UInt32 = 0
        for index in result.indices {
            let word = result[index]
            result[index] = word << 1 | carry
            carry = word >> 31
        }
        if carry == 1 || !isLess(result, n) { subtract(&result, n) }
        return result
    }

    private static func isLess(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for index in a.indices.reversed() where a[index] != b[index] { return a[index] < b[index] }
        return false
    }

    /// a −= b, mod 2^(32·count) (the borrow out is dropped: the caller knows a ≥ b, or the top carry covers it).
    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for index in a.indices {
            let difference = UInt64(a[index]) &- UInt64(b[index]) &- borrow
            a[index] = UInt32(truncatingIfNeeded: difference)
            borrow = difference >> 63
        }
    }

    /// a·b·R⁻¹ mod n.
    func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let s = n.count
        var t = [UInt64](repeating: 0, count: s + 2)
        for i in 0 ..< s {
            var carry: UInt64 = 0
            let bi = UInt64(b[i])
            for j in 0 ..< s {
                let sum = t[j] + UInt64(a[j]) * bi + carry
                t[j] = sum & 0xffff_ffff
                carry = sum >> 32
            }
            var sum = t[s] + carry
            t[s] = sum & 0xffff_ffff
            t[s + 1] = sum >> 32
            let m = UInt64(UInt32(truncatingIfNeeded: t[0]) &* inverse)
            sum = t[0] + m * UInt64(n[0])
            carry = sum >> 32
            for j in 1 ..< s {
                sum = t[j] + m * UInt64(n[j]) + carry
                t[j - 1] = sum & 0xffff_ffff
                carry = sum >> 32
            }
            sum = t[s] + carry
            t[s - 1] = sum & 0xffff_ffff
            t[s] = t[s + 1] + (sum >> 32)
            t[s + 1] = 0
        }
        var result = t.prefix(s).map { UInt32(truncatingIfNeeded: $0) }
        if t[s] != 0 || !Self.isLess(result, n) { Self.subtract(&result, n) }
        return result
    }

    /// base^exponent mod n, for base < n.
    func power(_ base: Limbs, exponent: [UInt8]) -> Limbs {
        let s = n.count
        let one = [1] + [UInt32](repeating: 0, count: s - 1)
        let x = multiply(base.resized(s), rSquared)
        var result = multiply(one, rSquared)
        for byte in exponent {
            for bit in (0 ..< 8).reversed() {
                result = multiply(result, result)
                if byte >> bit & 1 == 1 { result = multiply(result, x) }
            }
        }
        return Limbs(words: multiply(result, one))
    }
}
