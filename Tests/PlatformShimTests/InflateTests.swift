#if canImport(Darwin)
import Foundation
import PlatformShim
import Testing

/// Raw DEFLATE, checked against what Foundation's own `.zlib` writes.
@Suite struct InflateTests {
    private static func deflated(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    private static var samples: [Data] {
        var generator = SystemRandomNumberGenerator()
        let random = Data((0 ..< 70_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let text = Data(String(repeating: "{\"bones\":[{\"name\":\"root\"},{\"name\":\"head\",\"x\":12.5}]} ", count: 4_000).utf8)
        let runs = Data((0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0 / 997) })
        return [Data(), Data("a".utf8), text, random, runs, random.prefix(100) + text + random.suffix(3_000)]
    }

    @Test func readsWhatFoundationWrites() throws {
        for sample in Self.samples {
            #expect(try Inflate.decompress(try Self.deflated(sample)) == sample)
        }
    }

    @Test func storedFixedAndDynamicBlocks() throws {
        // A stored block ("hi"), a fixed-code block ("a"), and Foundation's
        // dynamic one for repetitive text.
        #expect(try Inflate.decompress(Data([0x01, 0x02, 0x00, 0xfd, 0xff, 0x68, 0x69])) == Data("hi".utf8))
        #expect(try Inflate.decompress(Data([0x4b, 0x04, 0x00])) == Data("a".utf8))
        let text = Data(String(repeating: "quiet meadow ", count: 500).utf8)
        #expect(try Inflate.decompress(try Self.deflated(text)) == text)
    }

    @Test func truncatedOrBadStreamsThrow() throws {
        let deflated = try Self.deflated(Self.samples[2])
        #expect(throws: Inflate.Failure.corrupt) { try Inflate.decompress(deflated.prefix(deflated.count / 2)) }
        #expect(throws: Inflate.Failure.corrupt) { try Inflate.decompress(Data([0x07])) }   // block type 3
        #expect(throws: Inflate.Failure.corrupt) { try Inflate.decompress(Data([0x01, 0x02, 0x00, 0x00, 0x00, 0x68, 0x69])) }
        #expect(throws: Inflate.Failure.corrupt) { try Inflate.decompress(Data()) }
    }
}
#endif
