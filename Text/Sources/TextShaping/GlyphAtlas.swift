#if canImport(CTextShaping)
import CTextShaping
import Foundation
import SpriteKitShim

/// Where one glyph sits on an atlas page, and how to place it.
///
/// `bearing` is the offset from the pen's position on the baseline to the
/// top-left of the bitmap, in points, positive up — the renderer adds the
/// shaper's `xOffset`/`yOffset` to it. An empty glyph (a space) has a zero
/// `size` and no page.
public struct AtlasGlyph: Equatable, Sendable {
    public var page: Int
    /// In pixels on the page, origin top-left.
    public var rect: CGRect
    public var bearing: CGPoint
    public var size: CGSize
    /// On a colour page (`GlyphAtlas.colourPages`): premultiplied RGBA,
    /// drawn as it is rather than in the text's colour.
    public var isColour = false

    public var isEmpty: Bool { size.width <= 0 || size.height <= 0 }
}

/// A page of 8-bit coverage, or of premultiplied RGBA for colour glyphs.
/// The renderer uploads it as a single-channel or an RGBA texture; nothing
/// here touches GL.
public final class AtlasPage {
    public let width: Int
    public let height: Int
    /// 1 for coverage, 4 for colour.
    public let bytesPerPixel: Int
    public private(set) var pixels: [UInt8]
    /// What has changed since the renderer last uploaded, so it can upload a
    /// sub-rectangle rather than the whole page. Nil when nothing has.
    public private(set) var dirty: CGRect?
    /// Bumped on every write, so a renderer can tell a stale upload cheaply.
    public private(set) var generation: Int = 0

    // A shelf packer: rows filled left to right, a new row started when the
    // current one runs out. Glyphs of one size are all much of a height, so
    // the waste is small and the code is a tenth of a skyline packer's.
    private var shelfY = 0
    private var shelfX = 0
    private var shelfHeight = 0

    init(width: Int, height: Int, bytesPerPixel: Int = 1) {
        self.width = width
        self.height = height
        self.bytesPerPixel = bytesPerPixel
        pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    }

    public func clearDirty() { dirty = nil }

    func place(width glyphWidth: Int, height glyphHeight: Int, padding: Int) -> CGRect? {
        let w = glyphWidth + padding * 2
        let h = glyphHeight + padding * 2
        guard w <= width, h <= height else { return nil }

        if shelfX + w > width {
            shelfY += shelfHeight
            shelfX = 0
            shelfHeight = 0
        }
        guard shelfY + h <= height else { return nil }

        let rect = CGRect(x: shelfX + padding, y: shelfY + padding, width: glyphWidth, height: glyphHeight)
        shelfX += w
        shelfHeight = max(shelfHeight, h)
        return rect
    }

    /// Copies one FreeType bitmap row by row. `source` is 8-bit coverage.
    func write(_ source: UnsafePointer<UInt8>, pitch: Int, into rect: CGRect) {
        let x0 = Int(rect.minX)
        let y0 = Int(rect.minY)
        let w = Int(rect.width)
        let h = Int(rect.height)
        for row in 0..<h {
            let from = source + row * pitch
            let to = (y0 + row) * width + x0
            for column in 0..<w {
                pixels[to + column] = from[column]
            }
        }
        dirty = dirty.map { $0.union(rect) } ?? rect
        generation += 1
    }

    /// Copies a colour glyph's RGBA rows onto a colour page.
    func write(rgba source: [UInt8], into rect: CGRect) {
        let x0 = Int(rect.minX), y0 = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        for row in 0 ..< h {
            let from = row * w * 4, to = ((y0 + row) * width + x0) * 4
            pixels.replaceSubrange(to ..< to + w * 4, with: source[from ..< from + w * 4])
        }
        dirty = dirty.map { $0.union(rect) } ?? rect
        generation += 1
    }
}

/// Rasterised glyphs, packed into pages and kept.
///
/// Keyed by face name, size and glyph id — the glyph id, not the character,
/// because that is what shaping hands back and what a ligature or a Thai
/// reordered form actually is. Asking twice gives the same rect back; the
/// renderer can cache on it.
public final class GlyphAtlas: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public var font: String
        /// Sixty-fourths of a point, FreeType's own grain.
        public var size: Int
        public var glyph: UInt32

        public init(font: String, size: CGFloat, glyph: UInt32) {
            self.font = font
            self.size = Int((size * 64).rounded())
            self.glyph = glyph
        }
    }

    public static let shared = GlyphAtlas()

    public let pageSize: Int
    /// A transparent ring round each glyph, so bilinear sampling at the edge
    /// cannot bleed a neighbour in.
    public let padding = 1

    private let lock = NSLock()
    private let library: FontLibrary
    private var cache: [Key: AtlasGlyph] = [:]
    private var store: [AtlasPage] = []
    private var colourCache: [Key: AtlasGlyph] = [:]
    private var colourStore: [AtlasPage] = []

    public init(pageSize: Int = 1024, library: FontLibrary = .shared) {
        self.pageSize = pageSize
        self.library = library
    }

    public var pages: [AtlasPage] { lock.withLock { store } }
    /// The RGBA pages colour glyphs are on.
    public var colourPages: [AtlasPage] { lock.withLock { colourStore } }

    /// A colour glyph of `font`'s face (emoji) at `pixels` square, packed
    /// onto a colour page on a miss. Nil for a glyph with no colour image.
    /// Its `bearing` and `size` are in pixels; the caller places it, by
    /// the box the glyph was laid out with.
    public func colourGlyph(_ glyph: UInt32, font: FontKey, pixels: Int) -> AtlasGlyph? {
        let key = Key(font: font.name, size: CGFloat(pixels), glyph: glyph)
        if let cached = lock.withLock({ colourCache[key] }) { return cached }
        guard let image = library.face(font)?.colourImage(glyph, pixels: pixels) else { return nil }
        return lock.withLock {
            if let cached = colourCache[key] { return cached }
            let size = CGSize(width: image.width, height: image.height)
            var placed: (Int, CGRect)?
            for (index, page) in colourStore.enumerated() {
                if let rect = page.place(width: image.width, height: image.height, padding: padding) { placed = (index, rect); break }
            }
            if placed == nil {
                let page = AtlasPage(width: pageSize, height: pageSize, bytesPerPixel: 4)
                guard let rect = page.place(width: image.width, height: image.height, padding: padding) else { return nil }
                colourStore.append(page)
                placed = (colourStore.count - 1, rect)
            }
            guard let (index, rect) = placed else { return nil }
            colourStore[index].write(rgba: image.pixels, into: rect)
            let entry = AtlasGlyph(page: index, rect: rect, bearing: .zero, size: size, isColour: true)
            colourCache[key] = entry
            return entry
        }
    }

    public var count: Int { lock.withLock { cache.count } }

    /// Rasterises on a miss, hands back the cached rect after that.
    public func glyph(_ key: Key, font: FontKey) -> AtlasGlyph? {
        lock.withLock {
            if let cached = cache[key] { return cached }
            guard let made = rasterise(key, font: font) else { return nil }
            cache[key] = made
            return made
        }
    }

    /// Every glyph of a shaped line, in drawing order.
    public func glyphs(of runs: [ShapedRun], font: FontKey) -> [AtlasGlyph] {
        runs.flatMap { run in
            let runFont = run.face(in: font)
            return run.glyphs.compactMap {
                glyph(Key(font: runFont.name, size: runFont.size, glyph: $0.glyph), font: runFont)
            }
        }
    }

    public func flush() {
        lock.withLock {
            cache.removeAll()
            store.removeAll()
            colourCache.removeAll()
            colourStore.removeAll()
        }
    }

    // Called with the atlas's lock held. The face has its own lock, which
    // `renderGlyph` takes: FreeType's glyph slot is shared state, so two
    // threads rasterising from the same face would overwrite each other.
    private func rasterise(_ key: Key, font: FontKey) -> AtlasGlyph? {
        guard let face = library.face(font) else { return nil }

        return face.renderGlyph(key.glyph) { pixels, width, height, pitch, left, top in
            // The bearing is in whole pixels: FreeType has already rounded
            // the outline onto the pixel grid, and the shaper's sub-pixel
            // offsets ride on top of it.
            let bearing = CGPoint(x: CGFloat(left), y: CGFloat(top))

            guard width > 0, height > 0, let pixels else {
                // A space: real, cached, and nothing to draw.
                return AtlasGlyph(page: -1, rect: .zero, bearing: bearing, size: .zero)
            }

            let size = CGSize(width: CGFloat(width), height: CGFloat(height))
            for (index, page) in store.enumerated() {
                if let rect = page.place(width: width, height: height, padding: padding) {
                    page.write(pixels, pitch: pitch, into: rect)
                    return AtlasGlyph(page: index, rect: rect, bearing: bearing, size: size)
                }
            }

            let page = AtlasPage(width: pageSize, height: pageSize)
            guard let rect = page.place(width: width, height: height, padding: padding) else {
                // Bigger than a whole page: a font size no label should use.
                // Better nothing than a silently cropped glyph.
                return nil
            }
            store.append(page)
            page.write(pixels, pitch: pitch, into: rect)
            return AtlasGlyph(page: store.count - 1, rect: rect, bearing: bearing, size: size)
        } ?? nil
    }
}

#endif
