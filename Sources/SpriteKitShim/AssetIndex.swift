#if SPRITEKIT_SHIM
import Foundation

/// Where the art lives on Android.
///
/// A game's art packer packs the @3x image sets of its asset catalog into a
/// few atlas pages plus one
/// `index.json`; this reads that index and turns an asset name — the name
/// the game passes `SKTexture(imageNamed:)` — into the page holding its
/// pixels, the rect it occupies there, its size in points, and the 9-slice
/// cap insets, content insets and anchors the game may also know the image
/// by.
///
/// The index carries no pixels. Loading and uploading a page is the
/// renderer's job: it asks for `url(ofPage:)` and caches the handle on
/// `SKTexture.glName`.
///
/// Set `AssetIndex.shared` once, as the app starts, before any scene builds.
/// Until it is set, `SKTexture(imageNamed:)` resolves nothing and reports a
/// zero size, exactly as it did before the index existed.
public final class AssetIndex: Sendable {
    /// One asset: a named image and everything the renderer and the game's
    /// layout need to know about it without opening a file.
    public struct Entry: Equatable, Sendable {
        public let name: String
        /// Which page holds the pixels, as an index into `pages`.
        public let page: Int
        /// Where they sit on that page, in pixels, with (0, 0) at its top
        /// left — the exporter's own convention.
        public let rect: CGRect
        /// The art's size in points: its pixels over the index's scale.
        public let size: CGSize
        /// The corners and edges a 9-slice keeps, in points.
        public let capInsets: UIEdgeInsets?
        /// Where the image's inner area begins, in points.
        public let contentInsets: UIEdgeInsets?
        /// How far the image reaches past what it lies on, in the game's own
        /// units: carried for the game, not read here.
        public let anchor: UIEdgeInsets?
        /// The same rect in the page's unit coordinates with a bottom-left
        /// origin, which is what `SKTexture.textureRect` reports and what
        /// the renderer turns into UVs.
        public let textureRect: CGRect
    }

    /// One PNG the renderer uploads as one GL texture.
    public struct Page: Equatable, Sendable {
        /// Relative to the index's own directory.
        public let file: String
        /// In pixels.
        public let size: CGSize
        /// Whether the page holds a single whole image rather than an atlas,
        /// so it may be sampled with repeat wrapping and mipped — which the
        /// tiling ground textures need and an atlas slice cannot have.
        public let repeats: Bool
        /// Whether the page ships as ASTC (a KTX file, `CompressedPage`)
        /// rather than a PNG.
        public var compressed: Bool = false
        /// Mip levels the page carries (1: none).
        public var levels: Int = 1
    }

    /// The pixels-per-point the art was exported at (3).
    public let scale: CGFloat
    public let pages: [Page]
    /// Where `index.json` was read from, so page files can be found beside
    /// it. Nil when the index was decoded from data alone.
    public let directory: URL?

    private let entries: [String: Entry]

    // MARK: Loading

    /// Reads an index from `index.json`'s bytes. `directory` is where its
    /// pages sit; pass it whenever the renderer will load them.
    public init(json data: Data, directory: URL? = nil) throws {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard wire.version == AssetIndex.version else {
            throw Failure.version(found: wire.version, expected: AssetIndex.version)
        }
        guard wire.scale > 0 else { throw Failure.malformed("scale is \(wire.scale)") }
        self.scale = CGFloat(wire.scale)
        self.directory = directory
        pages = wire.pages.map {
            Page(
                file: $0.file, size: CGSize(width: $0.width, height: $0.height), repeats: $0.repeats ?? false,
                compressed: $0.format == "astc", levels: max(1, $0.levels ?? 1)
            )
        }

        var built: [String: Entry] = [:]
        built.reserveCapacity(wire.assets.count)
        for (name, asset) in wire.assets {
            guard asset.rect.count == 4, asset.size.count == 2 else {
                throw Failure.malformed("\(name) has a \(asset.rect.count)-number rect and a \(asset.size.count)-number size")
            }
            guard pages.indices.contains(asset.page) else {
                throw Failure.malformed("\(name) names page \(asset.page) of \(pages.count)")
            }
            let page = pages[asset.page]
            let rect = CGRect(
                x: CGFloat(asset.rect[0]), y: CGFloat(asset.rect[1]),
                width: CGFloat(asset.rect[2]), height: CGFloat(asset.rect[3])
            )
            guard rect.minX >= 0, rect.minY >= 0,
                  rect.maxX <= page.size.width, rect.maxY <= page.size.height else {
                throw Failure.malformed("\(name) runs off \(page.file)")
            }
            built[name] = Entry(
                name: name,
                page: asset.page,
                rect: rect,
                size: CGSize(width: asset.size[0], height: asset.size[1]),
                capInsets: AssetIndex.insets(asset.caps),
                contentInsets: AssetIndex.insets(asset.content),
                anchor: AssetIndex.insets(asset.anchor),
                textureRect: CGRect(
                    x: rect.minX / page.size.width,
                    // The index counts down from the top; texture coordinates
                    // count up from the bottom.
                    y: (page.size.height - rect.maxY) / page.size.height,
                    width: rect.width / page.size.width,
                    height: rect.height / page.size.height
                )
            )
        }
        entries = built
    }

    /// Reads `index.json` at `url`, taking its folder as the pages' folder.
    public convenience init(contentsOf url: URL) throws {
        try self.init(json: Data(contentsOf: url), directory: url.deletingLastPathComponent())
    }

    /// Reads `index.json` inside `directory`.
    public convenience init(directory: URL) throws {
        try self.init(contentsOf: directory.appendingPathComponent(AssetIndex.fileName))
    }

    // MARK: Reading

    /// What the index knows about `name`, or nil if it holds no such asset.
    public func entry(_ name: String) -> Entry? { entries[name] }

    public subscript(name: String) -> Entry? { entries[name] }

    /// Every asset name, in order.
    public var names: [String] { entries.keys.sorted() }

    public var count: Int { entries.count }

    /// Where a page's PNG is, once the index knows its directory.
    public func url(ofPage page: Int) -> URL? {
        guard let directory, pages.indices.contains(page) else { return nil }
        return pages[page].file.split(separator: "/").reduce(directory) { $0.appendingPathComponent(String($1)) }
    }

    // MARK: The one the game uses

    /// The index every `SKTexture(imageNamed:)` resolves against. The app
    /// sets it as it starts; it is nil in tests that do not need art.
    public static var shared: AssetIndex? {
        get { Shared.lock.withLock { Shared.index } }
        set { Shared.lock.withLock { Shared.index = newValue } }
    }

    private enum Shared {
        static let lock = NSLock()
        nonisolated(unsafe) static var index: AssetIndex?
    }

    // MARK: Details

    /// The index format this reads. `android-art.js` writes the same number.
    public static let version = 2
    public static let fileName = "index.json"

    public enum Failure: Error, Equatable {
        case version(found: Int, expected: Int)
        case malformed(String)
    }

    private static func insets(_ edges: [Double]?) -> UIEdgeInsets? {
        guard let edges, edges.count == 4 else { return nil }
        return UIEdgeInsets(top: edges[0], left: edges[1], bottom: edges[2], right: edges[3])
    }

    /// index.json as it is written.
    private struct Wire: Decodable {
        struct Page: Decodable {
            let file: String
            let width: Double
            let height: Double
            let repeats: Bool?
            let format: String?
            let levels: Int?
        }

        struct Asset: Decodable {
            let page: Int
            let rect: [Double]
            let size: [Double]
            let caps: [Double]?
            let content: [Double]?
            let anchor: [Double]?
        }

        let version: Int
        let scale: Double
        let pages: [Page]
        let assets: [String: Asset]
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

#endif
