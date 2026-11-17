#if SPRITEKIT_SHIM
import Foundation

/// A texture.
///
/// The game builds these from asset names, raw image data, and sub-rectangles
/// of other textures (atlas slices). The
/// shim keeps the description; uploading to GL is the renderer's job, and
/// `glName` is where the renderer caches the uploaded handle.
///
/// A named texture resolves through `AssetIndex.shared`, which says which
/// packed page holds its pixels and where: so `size()` reports the art's own
/// size in points, as SpriteKit's does, and `textureRect` is the slice of
/// that page the renderer samples. With no index set — in a test that needs
/// no art — a named texture stays unresolved and reports a zero size.
public final class SKTexture: @unchecked Sendable {
    public enum Source {
        case named(String)
        /// Raw RGBA8 pixels, rows bottom first — exactly what SpriteKit's
        /// `SKTexture(data:size:)` takes. A game builds these itself: a noise
        /// lattice its shaders sample, say.
        case data(Data)
        /// An image file's bytes, still encoded: what `SKTexture(image:)`
        /// carries, since the shim's `UIImage` keeps a PNG undecoded and lets
        /// the renderer decode it once. A case of its own because sharing
        /// `.data` with raw pixels means one of them is always misread —
        /// either a loaded PNG as raw RGBA or raw noise as a PNG.
        case encoded(Data)
        /// A sub-rectangle of another texture, in unit coordinates.
        case slice(SKTexture, CGRect)
        /// A solid colour, for stand-ins and tests.
        case color(SKColor, CGSize)
        /// Pixels the game drew itself, through a `CGContext`: every surface
        /// a game draws for itself arrives this way.
        case image(RasterImage)
    }

    public let source: Source
    public var filteringMode: SKTextureFilteringMode = .linear
    /// Whether the renderer should build a mip chain for it. A loaded image
    /// page may ask for one; a slice of an atlas page cannot have one.
    public var usesMipmaps: Bool = false

    /// Set by the renderer once uploaded. 0 means "not resident".
    public var glName: UInt32 = 0

    private var declaredSize: CGSize?

    /// What the asset index knows about this texture's image, if it was
    /// made from an asset name and the index holds it.
    public let asset: AssetIndex.Entry?

    public convenience init(imageNamed name: String) {
        self.init(imageNamed: name, in: AssetIndex.shared)
    }

    /// A named texture resolved against `index` rather than the app's.
    ///
    /// For tests. `AssetIndex.shared` is process-wide and Swift Testing runs
    /// suites in parallel, so a test that swaps the global to get textures
    /// with pages changes what every other suite's `imageNamed:` resolves
    /// to, mid-run: one that did made `SpriteBatcherTests`' "A" and "B" land
    /// on one page and merge, and failed it about one run in three.
    public init(imageNamed name: String, in index: AssetIndex?) {
        source = .named(name)
        asset = index?.entry(name)
        if let page = asset?.page { Self.pageWanted?(page) }
    }

    /// Told each packed page a named texture is made on, so it can start
    /// decoding before the texture first draws (`PageDecodes.prefetch`):
    /// a scene made on the main thread, as a loading screen may be, draws the
    /// next frame. The renderer installs it.
    public nonisolated(unsafe) static var pageWanted: ((Int) -> Void)?

    /// An encoded image file (a PNG), decoded by the renderer on upload.
    /// `size` is in points.
    public init(encoded data: Data, size: CGSize) {
        source = .encoded(data)
        asset = nil
        declaredSize = size
    }

    public init(data: Data, size: CGSize) {
        source = .data(data)
        asset = nil
        declaredSize = size
    }

    /// A sub-rectangle of `texture`, in its unit coordinate space, as
    /// SpriteKit takes it: nesting composes, so a slice of a texture that is
    /// itself a slice of a packed page lands in the right place on the page.
    public init(rect: CGRect, in texture: SKTexture) {
        source = .slice(texture, rect)
        asset = nil
        let parent = texture.size()
        declaredSize = CGSize(width: parent.width * rect.width, height: parent.height * rect.height)
    }

    public init(color: SKColor, size: CGSize) {
        source = .color(color, size)
        asset = nil
        declaredSize = size
    }

    /// A texture from an image, either kind `UIImage` can be.
    ///
    /// One the game **drew** (through `UIGraphicsImageRenderer`) carries its
    /// pixels as `.image`. One it **loaded** from a file carries the file's
    /// undecoded bytes as `.encoded`, which the renderer decodes — not
    /// `.data`, which is SpriteKit's raw RGBA. Either way
    /// the image's scale is what makes a 3x rendering measure as its own
    /// points, as `SKTexture(image:)` does on Apple.
    public convenience init(image: UIImage) {
        // One of the packed art's own images draws from its page, as
        // `SKTexture(imageNamed:)` would, rather than decoded and uploaded again.
        if let asset = image.asset {
            self.init(imageNamed: asset.name)
            return
        }
        self.init(drawnOrLoaded: image)
    }

    private init(drawnOrLoaded image: UIImage) {
        source = image.cgImage.map { Source.image($0) } ?? .encoded(image.data)
        asset = nil
        declaredSize = image.size
    }

    /// SpriteKit's `SKTexture(cgImage:)`: a bitmap the game drew or blurred,
    /// a point a pixel, as
    /// SpriteKit measures one.
    public init(cgImage: RasterImage) {
        source = .image(cgImage)
        asset = nil
        declaredSize = nil
    }

    /// The image's size in points, as SpriteKit reports it: for a named
    /// texture, the art's own size from the asset index.
    public func size() -> CGSize {
        if let declaredSize { return declaredSize }
        switch source {
        case let .slice(parent, rect):
            let base = parent.size()
            return CGSize(width: base.width * rect.width, height: base.height * rect.height)
        case let .color(_, size):
            return size
        case .named:
            // Zero while no index is loaded, or when it holds no such asset,
            // in which case a sprite falls back on its own explicit size.
            return asset?.size ?? .zero
        case let .image(image):
            return CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        case .data, .encoded:
            return .zero
        }
    }

    /// The region of the page this texture covers, in that page's unit
    /// coordinates with a bottom-left origin — what the renderer turns into
    /// UVs. A named texture's is its rect on its packed page; a slice's is
    /// its own rect taken inside its parent's.
    public var textureRect: CGRect {
        switch source {
        case let .slice(parent, rect):
            let outer = parent.textureRect
            return CGRect(
                x: outer.minX + rect.minX * outer.width,
                y: outer.minY + rect.minY * outer.height,
                width: rect.width * outer.width,
                height: rect.height * outer.height
            )
        case .named:
            return asset?.textureRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        case .data, .encoded, .color, .image:
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    /// The texture actually holding the pixels (a slice defers to its parent).
    public var root: SKTexture {
        if case let .slice(parent, _) = source { return parent.root }
        return self
    }

    /// The pixels this texture carries itself, if it was drawn rather than
    /// packed — what the renderer uploads through `ResourceCache.pixelSource`.
    public var ownPixels: (width: Int, height: Int, pixels: Data)? {
        guard case let .image(image) = source else { return nil }
        return (image.width, image.height, Data(image.pixels))
    }

    /// The packed page this texture's pixels are on, as an index into
    /// `AssetIndex.pages` — the renderer's upload key. Nil for a texture
    /// that is not backed by the asset index.
    public var page: Int? { root.asset?.page }

    // MARK: Mutable textures

    /// The pixels of a mutable texture (`SKMutableTexture`), rows bottom
    /// first, and how many times they've changed: the renderer uploads them
    /// again when the count moves on from the one it last uploaded.
    public private(set) var mutablePixels: (width: Int, height: Int, pixels: Data)?
    public private(set) var revision = 0
    /// Set by the renderer: the `revision` it last uploaded.
    public var uploadedRevision = 0

    /// SpriteKit's `SKMutableTexture(size:)`: RGBA8 pixels the game writes
    /// itself (`modifyPixelData`), a point a pixel.
    public convenience init(size: CGSize) {
        let width = max(Int(size.width), 1), height = max(Int(size.height), 1)
        self.init(data: Data(count: width * height * 4), size: size)
        mutablePixels = (width, height, Data(count: width * height * 4))
    }

    /// Hands `block` the pixels to rewrite in place, as SpriteKit's
    /// `SKMutableTexture.modifyPixelData` does, and has the renderer upload
    /// them again.
    public func modifyPixelData(_ block: (UnsafeMutableRawPointer?, Int) -> Void) {
        guard var pixels = mutablePixels else { return }
        // Let go of the stored copy first, so the bytes change in place.
        mutablePixels = nil
        pixels.pixels.withUnsafeMutableBytes { block($0.baseAddress, $0.count) }
        mutablePixels = pixels
        revision += 1
    }
}

/// SpriteKit's mutable texture: the shim's `SKTexture` made with
/// `init(size:)`, which `modifyPixelData` rewrites.
public typealias SKMutableTexture = SKTexture

public enum SKTextureFilteringMode: Int, Sendable {
    case nearest, linear
}

#endif
