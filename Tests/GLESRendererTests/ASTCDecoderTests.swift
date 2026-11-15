import Foundation
import Testing
@testable import GLESRenderer

/// The CPU decoder against astcenc's own: `Fixtures/ASTC` holds one image
/// (smooth colour, grey and colour noise, luminance with alpha, hard
/// multi-coloured shapes with holes, a soft premultiplied blob) compressed
/// by astcenc 5.7.1 at several block sizes and qualities (`<block>-<quality>.astc`),
/// and astcenc's decode of each to RGBA8 (`.rgba`).
struct ASTCDecoderTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ASTC")

    /// An .astc file's header: magic, block size, image size.
    static func load(_ name: String) throws -> (block: (Int, Int), width: Int, height: Int, blocks: Data, expected: [UInt8]) {
        let file = try Data(contentsOf: fixtures.appendingPathComponent("\(name).astc"))
        let expected = try [UInt8](Data(contentsOf: fixtures.appendingPathComponent("\(name).rgba")))
        let bytes = [UInt8](file.prefix(16))
        let width = Int(bytes[7]) | Int(bytes[8]) << 8 | Int(bytes[9]) << 16
        let height = Int(bytes[10]) | Int(bytes[11]) << 8 | Int(bytes[12]) << 16
        return ((Int(bytes[4]), Int(bytes[5])), width, height, file.dropFirst(16), expected)
    }

    @Test(arguments: ["4x4", "5x5", "6x6", "8x8", "10x6", "12x12"].flatMap { ["\($0)-thorough", "\($0)-fast"] })
    func matchesAstcenc(_ name: String) throws {
        let fixture = try Self.load(name)
        let decoder = ASTCDecoder(blockWidth: fixture.block.0, blockHeight: fixture.block.1)
        let pixels = decoder.decode(Data(fixture.blocks), width: fixture.width, height: fixture.height)
        #expect(pixels.count == fixture.expected.count)
        var worst = 0, at = -1
        for i in 0 ..< min(pixels.count, fixture.expected.count) {
            let difference = abs(Int(pixels[i]) - Int(fixture.expected[i]))
            if difference > worst { worst = difference; at = i }
        }
        #expect(worst == 0, "\(name): off by \(worst) at texel \(at / 4) channel \(at % 4)")
    }

    @Test func decodesARegion() throws {
        let fixture = try Self.load("6x6-thorough")
        let decoder = ASTCDecoder(blockWidth: 6, blockHeight: 6)
        let region = (x: 7, y: 11, width: 23, height: 17)
        let pixels = decoder.decode(Data(fixture.blocks), width: fixture.width, height: fixture.height, region: region)
        var same = true
        for row in 0 ..< region.height {
            for column in 0 ..< region.width {
                let from = ((region.y + row) * fixture.width + region.x + column) * 4
                let to = (row * region.width + column) * 4
                if pixels[to ..< to + 4].elementsEqual(fixture.expected[from ..< from + 4]) == false { same = false }
            }
        }
        #expect(same)
    }
}

/// How long a staged atlas page takes to decode whole, if one is staged
/// (`npm run art -- --android`): the cost a GPU without ASTC pays a page.
struct ASTCDecoderTimingTests {
    static let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Assets/atlas-000.ktx").standardizedFileURL

    @Test(.enabled(if: FileManager.default.fileExists(atPath: page.path)))
    func decodesAStagedPage() throws {
        let compressed = try CompressedPage(ktx: Data(contentsOf: Self.page))
        let started = Date()
        let pixels = compressed.decodeLevel0()
        let took = Date().timeIntervalSince(started)
        print("decoded \(compressed.width)x\(compressed.height) ASTC \(compressed.blockWidth)x\(compressed.blockHeight) in \(Int(took * 1000)) ms")
        #expect(pixels.count == compressed.width * compressed.height * 4)
    }
}
