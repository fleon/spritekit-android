import Foundation

/// A packed page as it reaches its upload: RGBA8 pixels, or the ASTC levels
/// a compressed page ships (`CompressedPage`).
public struct PageImage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// RGBA8, premultiplied, when the page isn't compressed (empty when it is).
    public let pixels: Data
    public let compressed: CompressedPage?
    /// Mip levels the upload makes from `pixels` (`RenderDevice.generateMipmaps`):
    /// a compressed page decoded on the CPU for a GPU without ASTC keeps
    /// the levels it shipped with. 1 is none.
    public let mipLevels: Int

    public init(width: Int, height: Int, pixels: Data, mipLevels: Int = 1) {
        self.width = width
        self.height = height
        self.pixels = pixels
        compressed = nil
        self.mipLevels = mipLevels
    }

    public init(_ compressed: CompressedPage) {
        width = compressed.width
        height = compressed.height
        pixels = Data()
        self.compressed = compressed
        mipLevels = compressed.levels.count
    }

    /// What it holds in memory while it waits for its upload.
    public var byteCount: Int { compressed?.byteCount ?? pixels.count }

    /// RGBA8 in place of ASTC levels, for a GPU that can't sample them:
    /// level 0 decoded on the CPU, its mip levels left for the upload to
    /// make (rows stay bottom first, as the page shipped).
    public func decodedForRGBA8() -> PageImage {
        guard let compressed else { return self }
        return PageImage(width: width, height: height, pixels: compressed.decodeLevel0(), mipLevels: compressed.levels.count)
    }
}

/// A page shipped as ASTC blocks with its mip levels, read from the KTX
/// 1.1 file `Tools/Art/ASTC/compress.js` writes: premultiplied, rows bottom
/// first as GL takes them, so its levels upload as they are
/// (`RenderDevice.createTexture(compressed:levels:)`).
public struct CompressedPage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let blockWidth: Int
    public let blockHeight: Int
    /// GL's internal format, `GL_COMPRESSED_RGBA_ASTC_<w>x<h>_KHR`.
    public let format: UInt32
    /// Level 0 first, each its blocks row by row from the bottom.
    public let levels: [Data]

    public enum Failure: Error, Equatable {
        case notKTX
        case notASTC(UInt32)
        case truncated
    }

    /// The ASTC formats, by block size: `GL_COMPRESSED_RGBA_ASTC_4x4_KHR` (0x93B0) on.
    static let blockSizes: [UInt32: (Int, Int)] = [
        0x93B0: (4, 4), 0x93B1: (5, 4), 0x93B2: (5, 5), 0x93B3: (6, 5), 0x93B4: (6, 6), 0x93B5: (8, 5),
        0x93B6: (8, 6), 0x93B7: (8, 8), 0x93B8: (10, 5), 0x93B9: (10, 6), 0x93BA: (10, 8), 0x93BB: (10, 10),
        0x93BC: (12, 10), 0x93BD: (12, 12),
    ]

    private static let identifier: [UInt8] = [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A]

    public init(ktx data: Data) throws {
        guard data.count >= 64, Array(data.prefix(12)) == Self.identifier else { throw Failure.notKTX }
        let base = data.startIndex
        func field(_ index: Int) -> Int {
            let at = base + 12 + index * 4
            return Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24
        }
        guard field(0) == 0x0403_0201 else { throw Failure.notKTX }
        let format = UInt32(field(4))
        guard let block = Self.blockSizes[format] else { throw Failure.notASTC(format) }
        width = field(6)
        height = field(7)
        blockWidth = block.0
        blockHeight = block.1
        self.format = format
        var levels: [Data] = []
        var at = 64 + field(12)
        for _ in 0 ..< max(1, field(11)) {
            guard at + 4 <= data.count else { throw Failure.truncated }
            let size = Int(data[base + at]) | Int(data[base + at + 1]) << 8 | Int(data[base + at + 2]) << 16 | Int(data[base + at + 3]) << 24
            guard at + 4 + size <= data.count else { throw Failure.truncated }
            levels.append(data.subdata(in: base + at + 4 ..< base + at + 4 + size))
            at += 4 + size + (4 - size % 4) % 4
        }
        self.levels = levels
    }

    public init(width: Int, height: Int, blockWidth: Int, blockHeight: Int, format: UInt32, levels: [Data]) {
        self.width = width
        self.height = height
        self.blockWidth = blockWidth
        self.blockHeight = blockHeight
        self.format = format
        self.levels = levels
    }

    public var byteCount: Int { levels.reduce(0) { $0 + $1.count } }

    /// A level's size in texels: each halves the last, rounded down, at least 1.
    public func size(ofLevel level: Int) -> (width: Int, height: Int) {
        (max(1, width >> level), max(1, height >> level))
    }

    /// Bytes a level's blocks take.
    public static func byteCount(width: Int, height: Int, blockWidth: Int, blockHeight: Int) -> Int {
        ((width + blockWidth - 1) / blockWidth) * ((height + blockHeight - 1) / blockHeight) * 16
    }

    /// Level 0's region at (`x`, `y`) — texels counted as GL counts them,
    /// from the bottom left — as a page of its own with no mip levels, its
    /// blocks copied as they are: only where the region's bottom left falls
    /// on a block boundary (the packer puts every atlas image there), else
    /// nil. Blocks running past the region's right or top hold the image's
    /// extruded gutter, which GL never samples.
    public func cut(x: Int, y: Int, width: Int, height: Int) -> CompressedPage? {
        guard width > 0, height > 0, x >= 0, y >= 0, x % blockWidth == 0, y % blockHeight == 0,
              x + width <= self.width, y + height <= self.height, let level = levels.first else { return nil }
        let across = (self.width + blockWidth - 1) / blockWidth
        let columns = (width + blockWidth - 1) / blockWidth
        let rows = (height + blockHeight - 1) / blockHeight
        let first = x / blockWidth, bottom = y / blockHeight
        var out = Data(count: columns * rows * 16)
        out.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            level.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for row in 0 ..< rows {
                    let from = ((bottom + row) * across + first) * 16
                    target.baseAddress!.advanced(by: row * columns * 16)
                        .copyMemory(from: source.baseAddress!.advanced(by: from), byteCount: columns * 16)
                }
            }
        }
        return CompressedPage(width: width, height: height, blockWidth: blockWidth, blockHeight: blockHeight, format: format, levels: [out])
    }

    /// Level 0's region decoded to RGBA8 on the CPU, rows bottom first
    /// (`y` from the bottom, as GL counts).
    public func decode(x: Int, y: Int, width: Int, height: Int) -> [UInt8] {
        guard let level = levels.first else { return [] }
        return ASTCDecoder(blockWidth: blockWidth, blockHeight: blockHeight)
            .decode(level, width: self.width, height: self.height, region: (x, y, width, height))
    }

    /// The whole of level 0 decoded to RGBA8, rows bottom first.
    public func decodeLevel0() -> Data {
        Data(decode(x: 0, y: 0, width: width, height: height))
    }
}
