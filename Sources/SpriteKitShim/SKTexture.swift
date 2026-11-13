#if SPRITEKIT_SHIM
import Foundation

/// A texture.
///
/// The game builds these from asset names, raw image data, and sub-rectangles
/// of other textures (the atlas slices the rigs and the board art use). The
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
        case data(Data)
        /// A sub-rectangle of another texture, in unit coordinates.
        case slice(SKTexture, CGRect)
        /// A solid colour, for stand-ins and tests.
        case color(SKColor, CGSize)
        /// Pixels the game drew itself, through a `CGContext`: every chunky
        /// surface `SurfaceTexture` makes arrives this way.
        case image(RasterImage)
    }

    public let source: Source
    public var filteringMode: SKTextureFilteringMode = .linear
    /// Whether the renderer should build a mip chain for it. The rigs' pages
    /// ask for one; a slice of an atlas page cannot have one.
    public var usesMipmaps: Bool = false

    /// Set by the renderer once uploaded. 0 means "not resident".
    public var glName: UInt32 = 0

    private var declaredSize: CGSize?

    /// What the asset index knows about this texture's image, if it was
    /// made from an asset name and the index holds it.
    public let asset: AssetIndex.Entry?

    public init(imageNamed name: String) {
        source = .named(name)
        asset = AssetIndex.shared?.entry(name)
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
    /// One the game **drew** (through `UIGraphicsImageRenderer`, as every
    /// chunky surface is) carries its pixels as `.image`. One it **loaded**
    /// from a file (a rig's page) carries the file's undecoded bytes as
    /// `.data`, which the renderer decodes. Either way the image's scale is
    /// what makes a 3x rendering measure as its own points, as
    /// `SKTexture(image:)` does on Apple.
    public init(image: UIImage) {
        source = image.cgImage.map { Source.image($0) } ?? .data(image.data)
        asset = nil
        declaredSize = image.size
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
        case .data:
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
        case .data, .color, .image:
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
}

public enum SKTextureFilteringMode: Int, Sendable {
    case nearest, linear
}

#endif
