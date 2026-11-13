#if SPRITEKIT_SHIM
import Foundation

/// An image the game loads from a file or an asset name.
///
/// The game uses this in one shape only: load a PNG, hand it to
/// `SKTexture(image:)`, draw it. It never asks for a pixel, never draws into
/// one, and never resizes one — `SurfaceTexture`'s drawing goes through
/// `CGContext`, which is the rasteriser's business, not this type's.
///
/// So this keeps the file's bytes and the size it reads out of the PNG
/// header, and leaves decoding to the renderer, which has a decoder already
/// and would otherwise do the work twice. `UIImage(contentsOfFile:)` is nil
/// for a file that is not there, as Apple's is, which is what
/// `RigMeshNode.look(of:)` relies on to tell a lit rig from an unlit one.
public final class UIImage: @unchecked Sendable {
    /// The file's bytes, undecoded.
    public let data: Data
    /// In points: the PNG's pixel size over `scale`.
    public let size: CGSize
    public let scale: CGFloat

    public init?(contentsOfFile path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let pixels = UIImage.pngSize(data) else { return nil }
        self.data = data
        // The rig pages are 1x files, as `RigNode` says: their sizes are in
        // pixels, and the rig's own maths scales them.
        scale = 1
        size = pixels
    }

    public convenience init?(named name: String) {
        guard let url = BundleResources.url(forResource: name, withExtension: "png") else { return nil }
        self.init(contentsOfFile: url.path)
    }

    /// The width and height out of a PNG's IHDR, which is always the first
    /// chunk: 8 bytes of signature, then length, type, width, height.
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

public extension SKTexture {
    /// A texture from a loaded image. The bytes travel as the texture's own
    /// `.data` source; `ResourceCache.pixelSource` decodes and uploads them.
    convenience init(image: UIImage) {
        self.init(data: image.data, size: image.size)
    }
}
#endif
