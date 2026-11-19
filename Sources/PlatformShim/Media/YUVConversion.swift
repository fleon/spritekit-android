import Foundation

/// A rendered frame (32-bit BGRA, as the film's pixel buffers hold it) into
/// the YUV 4:2:0 an H.264 encoder takes.
///
/// BT.709 in video range, which is what an HD H.264 from AVFoundation is
/// tagged with and what the encoder is told (`color-standard` and
/// `color-range`), so a film from Android plays in the same colours as one
/// from iOS. Chroma is the mean of each 2×2 block. Fixed point, sixteen
/// fractional bits: a 1080 × 1920 frame is two million pixels sixty times a
/// second, on the film's own thread.
public enum YUVConversion {
    // The coefficients, × 65536, with video range's 219/255 (luma) and
    // 224/255 (chroma) folded in.
    private static let yR = 11966, yG = 40254, yB = 4064
    private static let uR = -6597, uG = -22187, uB = 28784
    private static let vR = 28784, vG = -26148, vB = -2636
    private static let half = 1 << 15

    /// Converts `width` × `height` BGRA pixels at `source` (`bytesPerRow`
    /// apart, top row first) into `destination`, laid out as `layout` says.
    /// Odd sizes lose their last column and row of chroma detail, as 4:2:0
    /// does anyway.
    public static func convert(bgra source: UnsafeRawPointer, bytesPerRow: Int, into destination: UnsafeMutableRawPointer, layout: YUVLayout) {
        convert(source, rowStep: bytesPerRow, red: 2, blue: 0, into: destination, layout: layout)
    }

    /// The same from pixels as a GL renderer reads them back: RGBA, rows
    /// bottom first, `rows` of them (`CVPixelBuffer.isHeldAsRendered`).
    public static func convert(rendered source: UnsafeRawPointer, bytesPerRow: Int, rows: Int, into destination: UnsafeMutableRawPointer, layout: YUVLayout) {
        convert(source + (rows - 1) * bytesPerRow, rowStep: -bytesPerRow, red: 0, blue: 2, into: destination, layout: layout)
    }

    /// From `top`, the top row, each row `rowStep` bytes on from the one
    /// above, red and blue at those byte offsets in each pixel.
    private static func convert(_ top: UnsafeRawPointer, rowStep: Int, red: Int, blue: Int, into destination: UnsafeMutableRawPointer, layout: YUVLayout) {
        let width = layout.width, height = layout.height, stride = layout.stride
        let luma = destination.assumingMemoryBound(to: UInt8.self)
        let chromaStart = luma + stride * layout.sliceHeight
        let pixels = top.assumingMemoryBound(to: UInt8.self)

        for y in 0 ..< height {
            let row = pixels + y * rowStep
            let out = luma + y * stride
            for x in 0 ..< width {
                let p = row + x * 4
                let b = Int(p[blue]), g = Int(p[1]), r = Int(p[red])
                out[x] = UInt8(truncatingIfNeeded: ((yR * r + yG * g + yB * b + half) >> 16) + 16)
            }
        }

        let chromaWidth = width / 2, chromaHeight = height / 2
        let chromaStride = stride / 2
        for cy in 0 ..< chromaHeight {
            let upper = pixels + cy * 2 * rowStep
            let lower = upper + rowStep
            for cx in 0 ..< chromaWidth {
                let a = upper + cx * 8, c = lower + cx * 8
                let b = Int(a[blue]) + Int(a[blue + 4]) + Int(c[blue]) + Int(c[blue + 4])
                let g = Int(a[1]) + Int(a[5]) + Int(c[1]) + Int(c[5])
                let r = Int(a[red]) + Int(a[red + 4]) + Int(c[red]) + Int(c[red + 4])
                // Four pixels summed: two more bits to shift away.
                let u = UInt8(clamping: ((uR * r + uG * g + uB * b + (half << 2)) >> 18) + 128)
                let v = UInt8(clamping: ((vR * r + vG * g + vB * b + (half << 2)) >> 18) + 128)
                switch layout.planes {
                case .semiPlanar:
                    let out = chromaStart + cy * stride + cx * 2
                    out[0] = u
                    out[1] = v
                case .planar:
                    chromaStart[cy * chromaStride + cx] = u
                    chromaStart[(layout.sliceHeight / 2) * chromaStride + cy * chromaStride + cx] = v
                }
            }
        }
    }
}
