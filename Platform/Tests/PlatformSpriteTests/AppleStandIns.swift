import SpriteKitShim

#if SPRITEKIT_SHIM
typealias Bitmap = RasterImage
#else
typealias Bitmap = CGImage
#endif

/// An RGBA8 bitmap of `pixels`, row 0 the top, for `SKTexture(cgImage:)`: the
/// shim's `RasterImage`, or a real `CGImage` against Apple's frameworks.
func bitmap(width: Int, height: Int, pixels: [UInt8]) -> Bitmap {
    #if SPRITEKIT_SHIM
    return RasterImage(width: width, height: height, pixels: pixels)
    #else
    let provider = CGDataProvider(data: Data(pixels) as CFData)
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let provider, let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ) else { fatalError("no bitmap") }
    return image
    #endif
}

#if !SPRITEKIT_SHIM
/// The shim's `PathElement` and `CGPath.pathElements` (SpriteKitShim's
/// `PathElements.swift`, which reads a real `CGPath` the same way), for the
/// tests that inspect a path against Apple's CoreGraphics.
enum PathElement: Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case quadCurve(to: CGPoint, control: CGPoint)
    case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
    case close
}

extension CGPath {
    var pathElements: [PathElement] {
        var out: [PathElement] = []
        applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint: out.append(.move(points[0]))
            case .addLineToPoint: out.append(.line(points[0]))
            case .addQuadCurveToPoint: out.append(.quadCurve(to: points[1], control: points[0]))
            case .addCurveToPoint:
                out.append(.curve(to: points[2], control1: points[0], control2: points[1]))
            case .closeSubpath: out.append(.close)
            @unknown default: break
            }
        }
        return out
    }
}
#endif
