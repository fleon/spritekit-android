#if SPRITEKIT_SHIM
import Foundation

/// An image: one the game loaded from a file, or one it drew.
///
/// The game uses `UIImage` in exactly two shapes, and they want different
/// things from it:
///
/// - **Loaded** — `UIImage(contentsOfFile:)` on a rig's page, handed to
///   `SKTexture(image:)` and drawn. Nobody asks it for a pixel, so this keeps
///   the file's bytes and the size out of the PNG header, and leaves
///   decoding to the renderer, which has a decoder already and would
///   otherwise do the work twice. It is nil for a file that is not there, as
///   Apple's is, which is how `RigMeshNode.look(of:)` tells a lit rig from an
///   unlit one.
/// - **Drawn** — what `UIGraphicsImageRenderer` hands back. Every chunky
///   surface `SurfaceTexture` makes is one of these. Its pixels already exist,
///   premultiplied RGBA8 out of a `CGContext`, so it carries them as
///   `cgImage` and there is nothing for anyone to decode.
///
/// One type for both, since the game names one type; `SKTexture(image:)`
/// sends each the right way.
public final class UIImage: @unchecked Sendable {
    /// The file's bytes, undecoded, for an image loaded from a file. Empty
    /// for one that was drawn.
    public let data: Data
    /// The pixels, for an image that was drawn, or for one of the packed
    /// art's images (`UIImage(named:)`), decoded on first ask through
    /// `packed`. Nil for one loaded from a file, whose bytes the
    /// renderer decodes itself.
    public var cgImage: RasterImage? {
        if let drawn { return drawn }
        guard let asset else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let decoded { return decoded }
        decoded = UIImage.packed?(asset.name)
        return decoded
    }
    private let drawn: RasterImage?
    /// The packed art's image this is, for `UIImage(named:)`.
    public let asset: AssetIndex.Entry?
    private var decoded: RasterImage?
    private let lock = NSLock()

    /// In points: the pixel size over `scale`.
    public let size: CGSize
    /// Pixels per point.
    public let scale: CGFloat

    public init?(contentsOfFile path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let pixels = UIImage.pngSize(data) else { return nil }
        self.data = data
        drawn = nil
        asset = nil
        // The rig pages are 1x files, as `RigNode` says: their sizes are in
        // pixels, and the rig's own maths scales them.
        scale = 1
        size = pixels
    }

    /// A loose PNG the bundle answers for (a rig's page), else an image set
    /// from the packed art, as the asset catalog answers on Apple: measured
    /// in its points, its pixels cut from its page only when somebody asks
    /// for them (`cgImage`, through `packed`). `SceneLighting` asks this some
    /// five hundred times just to learn whether an asset has normals, so it
    /// must answer without decoding anything.
    public convenience init?(named name: String) {
        if let url = BundleResources.url(forResource: name, withExtension: "png") {
            self.init(contentsOfFile: url.path)
        } else if let entry = AssetIndex.shared?.entry(name) {
            self.init(asset: entry, scale: AssetIndex.shared?.scale ?? 1)
        } else {
            return nil
        }
    }

    private init(asset entry: AssetIndex.Entry, scale: CGFloat) {
        data = Data()
        drawn = nil
        asset = entry
        self.scale = scale > 0 ? scale : 1
        size = entry.size
    }

    /// An image set's pixels, premultiplied, cut from its atlas page; the
    /// shell installs it.
    public nonisolated(unsafe) static var packed: ((String) -> RasterImage?)?

    /// A PNG's bytes, decoded as a file's are (`decoder`). The only images
    /// the game makes from bytes are a shared level's maker photos, which
    /// iOS sends as JPEG; with no JPEG decoder here those come back nil, and
    /// `CreditNode` shows the maker's initial instead, as it does for a maker
    /// with no photo.
    public convenience init?(data: Data) {
        guard UIImage.pngSize(data) != nil, let pixels = UIImage.decoder?(data) else { return nil }
        self.init(cgImage: pixels, scale: 1)
    }

    /// No JPEG encoder here: a level shared from Android carries no maker
    /// photo (a settled decision: no Game Center, so no credit).
    public func jpegData(compressionQuality: CGFloat) -> Data? { nil }

    /// A drawn image. UIKit's carries its scale so a 3x rendering still
    /// measures as its points, and the game relies on that: `SurfaceTexture`
    /// draws a 120-point button at 3x and expects a 120-point texture back,
    /// not a 360-point one.
    public init(cgImage: RasterImage, scale: CGFloat = 1) {
        data = Data()
        drawn = cgImage
        asset = nil
        self.scale = scale > 0 ? scale : 1
        size = CGSize(
            width: CGFloat(cgImage.width) / self.scale,
            height: CGFloat(cgImage.height) / self.scale
        )
    }

    /// An empty image, for the paths that have to hand one back and have
    /// nothing to put in it.
    init(size: CGSize, scale: CGFloat) {
        data = Data()
        drawn = nil
        asset = nil
        self.scale = scale > 0 ? scale : 1
        self.size = size
    }

    /// The width and height out of a PNG's IHDR, which is always the first
    /// chunk: 8 bytes of signature, then length, type, width, height.
    /// The renderers' contexts, innermost last (UIKit's context stack). One
    /// thread draws images at a time in the game: the main one, or a build
    /// off it holding the build gate.
    nonisolated(unsafe) static var contexts: [BitmapContext] = []

    /// Decodes a PNG's bytes, which the shim can't inflate on its own; the
    /// shell installs its decoder. Without it, an image read from a file
    /// draws nothing.
    public nonisolated(unsafe) static var decoder: ((Data) -> RasterImage?)?

    /// Encodes pixels as a PNG; the shell installs one that compresses.
    /// Without it, `PNGEncoder`'s stored (uncompressed) deflate.
    public nonisolated(unsafe) static var encoder: ((RasterImage) -> Data?)?

    /// Its pixels, decoded from its file if it came from one.
    public var pixels: RasterImage? {
        cgImage ?? (data.isEmpty ? nil : UIImage.decoder?(data))
    }

    /// Draws it, stretched to `rect`, into the context being drawn.
    public func draw(in rect: CGRect) {
        guard let context = UIImage.contexts.last, let pixels else { return }
        // UIKit draws an image the right way up in its own y-down space;
        // CoreGraphics' `draw` puts the image's top on the rect's maxY.
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(pixels, in: rect)
        context.restoreGState()
    }

    /// The image as a PNG file.
    public func pngData() -> Data? {
        if cgImage == nil, !data.isEmpty, UIImage.pngSize(data) != nil { return data }
        guard let pixels else { return nil }
        return UIImage.encoder?(pixels) ?? PNGEncoder.encode(pixels)
    }

    static func pngSize(_ data: Data) -> CGSize? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24,
              Array(bytes[0 ..< 8]) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(bytes[12 ..< 16]) == Array("IHDR".utf8) else { return nil }
        func word(_ at: Int) -> Int {
            (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16) | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
        }
        let width = word(16), height = word(20)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}

/// UIKit's renderer format: `scale`, `opaque` and the colour range.
public final class UIGraphicsImageRendererFormat: @unchecked Sendable {
    /// Which colours the bitmap may hold. The shim keeps everything in the
    /// standard range, so this is recorded and otherwise has no effect — but
    /// it is recorded, because `SurfaceTexture` sets `.standard` when what it
    /// draws is data (a normal map) rather than a picture, and a later wide
    /// format must not quietly shift those values.
    public enum Range: Int, Sendable {
        case unspecified, automatic, extended, standard
    }

    public var scale: CGFloat
    public var opaque = false
    public var preferredRange = Range.automatic

    public init() {
        scale = UITraitCollection.current.displayScale
    }

    public static func `default`() -> UIGraphicsImageRendererFormat {
        UIGraphicsImageRendererFormat()
    }
}

/// What the drawing closure is handed. `cgContext` is the whole of it as far
/// as the game is concerned.
public final class UIGraphicsImageRendererContext: @unchecked Sendable {
    public let cgContext: BitmapContext
    public let format: UIGraphicsImageRendererFormat

    init(cgContext: BitmapContext, format: UIGraphicsImageRendererFormat) {
        self.cgContext = cgContext
        self.format = format
    }

    /// UIKit vends these conveniences on the context too; `SurfaceTexture`
    /// uses the `CGContext` directly, but `fill` and `stroke` are one line
    /// each and the next ring will want them.
    public func fill(_ rect: CGRect) { cgContext.fill(rect) }
    public func stroke(_ rect: CGRect) { cgContext.stroke(rect) }
    public func clip(to rect: CGRect) { cgContext.clip(to: rect) }
}

/// Draws into a bitmap of a given size in points and hands back a `UIImage`.
public final class UIGraphicsImageRenderer: @unchecked Sendable {
    public let size: CGSize
    public let format: UIGraphicsImageRendererFormat
    /// A renderer made from a rect draws with its origin moved to zero, as
    /// UIKit's does — a snapshot of a view's bounds starts at its own corner.
    private let origin: CGPoint

    public init(size: CGSize, format: UIGraphicsImageRendererFormat = .default()) {
        self.size = size
        self.format = format
        origin = .zero
    }

    public convenience init(bounds: CGRect, format: UIGraphicsImageRendererFormat = .default()) {
        self.init(size: bounds.size, format: format, origin: bounds.origin)
    }

    private init(size: CGSize, format: UIGraphicsImageRendererFormat, origin: CGPoint) {
        self.size = size
        self.format = format
        self.origin = origin
    }

    public func image(_ actions: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let scale = format.scale > 0 ? format.scale : 1
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return UIImage(size: size, scale: scale) }

        let context = BitmapContext(
            width: width, height: height, scale: scale, opaque: format.opaque
        )
        if origin != .zero { context.translateBy(x: -origin.x, y: -origin.y) }
        // UIKit's drawing calls (`UIImage.draw(in:)`) draw into this while
        // the actions run, and into what was current before once they end.
        UIImage.contexts.append(context)
        actions(UIGraphicsImageRendererContext(cgContext: context, format: format))
        UIImage.contexts.removeLast()

        guard let image = context.makeImage() else { return UIImage(size: size, scale: scale) }
        return UIImage(cgImage: image, scale: scale)
    }
}

/// Only `displayScale` is here, which is the one thing the game asks a trait
/// collection for: `SurfaceTexture.renderScale` reads it to decide how many
/// pixels a point of a button is worth.
///
/// The shell sets it once the drawable size is known. Left alone it is 1,
/// which draws a correct but soft texture rather than a wrong one.
public final class UITraitCollection: @unchecked Sendable {
    public var displayScale: CGFloat

    public init(displayScale: CGFloat = 1) {
        self.displayScale = displayScale
    }

    nonisolated(unsafe) public static var current = UITraitCollection()
}
#endif
