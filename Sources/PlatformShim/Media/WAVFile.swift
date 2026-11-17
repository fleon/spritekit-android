import Foundation

/// A WAV file's PCM, as sound effects commonly ship (16-bit; 24-bit, 32-bit
/// and float read too). Nil for anything
/// that isn't a RIFF WAVE with a `fmt ` and a `data` chunk.
public struct WAVFile: Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    public let isFloat: Bool
    private let samples: Data

    public init?(_ data: Data) {
        guard data.count >= 12, Self.tag(data, 0) == "RIFF", Self.tag(data, 8) == "WAVE" else { return nil }
        var offset = 12
        var format: (tag: Int, channels: Int, rate: Int, bits: Int)?
        var body: Data?
        while offset + 8 <= data.count {
            let id = Self.tag(data, offset)
            let size = Int(Self.uint32(data, offset + 4))
            let start = offset + 8
            let end = min(data.count, start + size)
            if id == "fmt ", end - start >= 16 {
                var tag = Int(Self.uint16(data, start))
                // WAVE_FORMAT_EXTENSIBLE: the real tag opens the sub-format.
                if tag == 0xFFFE, end - start >= 26 { tag = Int(Self.uint16(data, start + 24)) }
                format = (tag, Int(Self.uint16(data, start + 2)), Int(Self.uint32(data, start + 4)), Int(Self.uint16(data, start + 14)))
            } else if id == "data" {
                body = data.subdata(in: start ..< end)
            }
            offset = start + size + (size & 1)
        }
        guard let format, let body, format.channels > 0, format.rate > 0 else { return nil }
        let pcm = format.tag == 1 && [8, 16, 24, 32].contains(format.bits)
        let float = format.tag == 3 && format.bits == 32
        guard pcm || float else { return nil }
        sampleRate = format.rate
        channels = format.channels
        bitsPerSample = format.bits
        isFloat = float
        samples = body
    }

    public var frameCount: Int { samples.count / (bitsPerSample / 8 * channels) }

    /// Hands `sink` each sample of `frames` frames from `start`, as a float
    /// from -1 to 1 with its frame (counted from `start`) and channel.
    /// Returns the frames read.
    public func read(from start: Int, frames: Int, into sink: (Int, Int, Float) -> Void) -> Int {
        let count = max(0, min(frames, frameCount - start))
        let width = bitsPerSample / 8
        samples.withUnsafeBytes { raw in
            for frame in 0 ..< count {
                for channel in 0 ..< channels {
                    let at = ((start + frame) * channels + channel) * width
                    sink(frame, channel, sample(raw, at))
                }
            }
        }
        return count
    }

    private func sample(_ raw: UnsafeRawBufferPointer, _ at: Int) -> Float {
        switch (bitsPerSample, isFloat) {
        case (32, true):
            return Float(bitPattern: UInt32(raw[at]) | UInt32(raw[at + 1]) << 8 | UInt32(raw[at + 2]) << 16 | UInt32(raw[at + 3]) << 24)
        case (8, _):
            return (Float(raw[at]) - 128) / 128
        case (16, _):
            return Float(Int16(bitPattern: UInt16(raw[at]) | UInt16(raw[at + 1]) << 8)) / 32768
        case (24, _):
            let value = Int32(bitPattern: UInt32(raw[at]) << 8 | UInt32(raw[at + 1]) << 16 | UInt32(raw[at + 2]) << 24) >> 8
            return Float(value) / 8_388_608
        default:
            let value = Int32(bitPattern: UInt32(raw[at]) | UInt32(raw[at + 1]) << 8 | UInt32(raw[at + 2]) << 16 | UInt32(raw[at + 3]) << 24)
            return Float(value) / 2_147_483_648
        }
    }

    private static func tag(_ data: Data, _ offset: Int) -> String {
        guard offset + 4 <= data.count else { return "" }
        return String(decoding: data[data.startIndex + offset ..< data.startIndex + offset + 4], as: UTF8.self)
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + offset + $1]) << (8 * $1) }
    }
}
