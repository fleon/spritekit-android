import CPixelRows
import Foundation

/// PNG's per-row filters undone, in C (`pixel_rows_unfilter`): a debug
/// build compiles Swift's per-byte loops without optimisation, and undoing
/// a 4078 x 5078 image's rows that way took 6.9 s on a Mac (10 s on a
/// Mali-G72 phone, the whole of a scene's preload), where the C takes
/// 0.26 s unoptimised.
public enum PNGRows {
    /// `raw` holds each row's filter byte then its `stride` bytes; returns
    /// the rows, or nil and the first row whose filter PNG doesn't define.
    public static func unfilter(_ raw: [UInt8], stride: Int, height: Int, channels: Int) -> (rows: [UInt8]?, badRow: Int?) {
        guard stride > 0, height > 0, channels > 0, raw.count >= (stride + 1) * height else { return (nil, 0) }
        var rows = [UInt8](repeating: 0, count: stride * height)
        let bad = raw.withUnsafeBufferPointer { source in
            rows.withUnsafeMutableBufferPointer { out -> Int in
                guard let from = source.baseAddress, let to = out.baseAddress else { return 0 }
                return pixel_rows_unfilter(from, to, stride, height, channels)
            }
        }
        return bad < 0 ? (rows, nil) : (nil, bad)
    }
}
