#if SPRITEKIT_SHIM
import Foundation

/// A texture.
///
/// The game builds these from asset names, raw image data, and sub-rectangles
/// of other textures (the atlas slices the rigs and the board art use). The
/// shim keeps the description; uploading to GL is the renderer's job, and
/// `glName` is where the renderer caches the uploaded handle.
public final class SKTexture: @unchecked Sendable {
    public enum Source {
        case named(String)
        case data(Data)
        /// A sub-rectangle of another texture, in unit coordinates.
        case slice(SKTexture, CGRect)
        /// A solid colour, for stand-ins and tests.
        case color(SKColor, CGSize)
    }

    public let source: Source
    public var filteringMode: SKTextureFilteringMode = .linear

    /// Set by the renderer once uploaded. 0 means "not resident".
    public var glName: UInt32 = 0

    private var declaredSize: CGSize?

    public init(imageNamed name: String) {
        source = .named(name)
    }

    public init(data: Data, size: CGSize) {
        source = .data(data)
        declaredSize = size
    }

    public init(rect: CGRect, in texture: SKTexture) {
        source = .slice(texture, rect)
        let parent = texture.size()
        declaredSize = CGSize(width: parent.width * rect.width, height: parent.height * rect.height)
    }

    public init(color: SKColor, size: CGSize) {
        source = .color(color, size)
        declaredSize = size
    }

    public func size() -> CGSize {
        if let declaredSize { return declaredSize }
        switch source {
        case let .slice(parent, rect):
            let base = parent.size()
            return CGSize(width: base.width * rect.width, height: base.height * rect.height)
        case let .color(_, size):
            return size
        case .named, .data:
            // Resolved by the asset loader once it reads the file; until then
            // the node's explicit size is used.
            return .zero
        }
    }

    /// The region of the underlying image this texture covers, in unit
    /// coordinates — what the renderer turns into UVs.
    public var textureRect: CGRect {
        if case let .slice(_, rect) = source { return rect }
        return CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// The texture actually holding the pixels (a slice defers to its parent).
    public var root: SKTexture {
        if case let .slice(parent, _) = source { return parent.root }
        return self
    }
}

public enum SKTextureFilteringMode: Int, Sendable {
    case nearest, linear
}

#endif
