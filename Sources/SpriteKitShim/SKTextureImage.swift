#if SPRITEKIT_SHIM
import Foundation

public extension SKTexture {
    /// SpriteKit's `cgImage()`: the texture's pixels, top row first. The
    /// collection fits each mechanic's sample by what its snapshot draws
    /// (`MechanicSampleNode.opaqueBounds`). Empty when the pixels cannot be
    /// had (a named texture with no index, a file with no decoder).
    /// Reads back a texture that lives only on the GPU (a snapshot the
    /// renderer baked, `SKView.texture(from:)`); the renderer sets it.
    nonisolated(unsafe) static var readBack: ((SKTexture) -> RasterImage?)?

    func cgImage() -> RasterImage {
        pixels() ?? RasterImage(width: 0, height: 0, pixels: [])
    }

    private func pixels() -> RasterImage? {
        if glName != 0, case .color = source, let read = SKTexture.readBack?(self) { return read }
        switch source {
        case let .image(image):
            return image
        case let .named(name):
            return UIImage.packed?(name)
        case let .encoded(data):
            return UIImage.decoder?(data)
        case let .data(data):
            let size = self.size()
            let width = Int(size.width), height = Int(size.height)
            guard width > 0, height > 0, data.count >= width * height * 4 else { return nil }
            // SpriteKit's raw data runs bottom row first.
            var rows = [UInt8](repeating: 0, count: width * height * 4)
            let stride = width * 4
            data.withUnsafeBytes { raw in
                for row in 0 ..< height {
                    let from = (height - 1 - row) * stride
                    for i in 0 ..< stride { rows[row * stride + i] = raw[from + i] }
                }
            }
            return RasterImage(width: width, height: height, pixels: rows)
        case let .slice(parent, unit):
            guard let whole = parent.pixels() else { return nil }
            // Unit rects count up from the bottom, rows down from the top.
            let x0 = Int((unit.minX * CGFloat(whole.width)).rounded())
            let x1 = Int((unit.maxX * CGFloat(whole.width)).rounded())
            let y0 = Int(((1 - unit.maxY) * CGFloat(whole.height)).rounded())
            let y1 = Int(((1 - unit.minY) * CGFloat(whole.height)).rounded())
            let width = max(0, min(x1, whole.width) - max(x0, 0))
            let height = max(0, min(y1, whole.height) - max(y0, 0))
            guard width > 0, height > 0 else { return nil }
            var out = [UInt8](repeating: 0, count: width * height * 4)
            for row in 0 ..< height {
                let from = ((max(y0, 0) + row) * whole.width + max(x0, 0)) * 4
                out.replaceSubrange(row * width * 4 ..< (row + 1) * width * 4, with: whole.pixels[from ..< from + width * 4])
            }
            return RasterImage(width: width, height: height, pixels: out)
        case let .color(colour, size):
            let width = max(1, Int(size.width)), height = max(1, Int(size.height))
            let a = colour.alpha
            let px: [UInt8] = [colour.red * a, colour.green * a, colour.blue * a, a].map { UInt8(max(0, min(1, $0)) * 255) }
            return RasterImage(width: width, height: height, pixels: Array([[UInt8]](repeating: px, count: width * height).joined()))
        }
    }
}
#endif
