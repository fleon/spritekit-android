import Foundation
import SpriteKitShim

// CoreMedia's time, and AVFoundation's asset writer, as a game writes a
// video of its own scenes: H.264 at the film's size and bit rate, each frame
// a BGRA pixel buffer appended at its presentation time. A game's
// `import AVFoundation` resolves to the module of that name in `Modules`,
// which re-exports these.
//
// Appending queues the frame on the input's own queue, where it's converted
// to the encoder's YUV and handed to MediaCodec, which writes what it has
// encoded to the MP4 as it goes. So the film renders its next frame while
// the last encodes; the input stops being ready for more while two wait, as
// AVFoundation's does when it falls behind, and finishing or cancelling
// waits for what's queued.

public typealias CMTimeValue = Int64
public typealias CMTimeScale = Int32
public typealias CMPersistentTrackID = Int32
public let kCMPersistentTrackID_Invalid: CMPersistentTrackID = 0

public struct CMTime: Equatable, Comparable, Sendable {
    public var value: CMTimeValue
    public var timescale: CMTimeScale

    public init(value: CMTimeValue, timescale: CMTimeScale) {
        self.value = value
        self.timescale = timescale
    }

    public init(seconds: Double, preferredTimescale: CMTimeScale) {
        self.init(value: CMTimeValue((seconds * Double(preferredTimescale)).rounded()), timescale: preferredTimescale)
    }

    public static let zero = CMTime(value: 0, timescale: 1)

    public var seconds: Double { timescale == 0 ? 0 : Double(value) / Double(timescale) }
    /// In microseconds, as MediaCodec counts.
    public var microseconds: Int64 { timescale == 0 ? 0 : value * 1_000_000 / Int64(timescale) }

    public static func == (lhs: CMTime, rhs: CMTime) -> Bool {
        Int64(lhs.value) * Int64(rhs.timescale) == Int64(rhs.value) * Int64(lhs.timescale)
    }

    public static func < (lhs: CMTime, rhs: CMTime) -> Bool {
        Int64(lhs.value) * Int64(rhs.timescale) < Int64(rhs.value) * Int64(lhs.timescale)
    }
}

public func CMTimeMinimum(_ time1: CMTime, _ time2: CMTime) -> CMTime { min(time1, time2) }
public func CMTimeGetSeconds(_ time: CMTime) -> Double { time.seconds }

public struct CMTimeRange: Equatable, Sendable {
    public var start: CMTime
    public var duration: CMTime

    public init(start: CMTime, duration: CMTime) {
        self.start = start
        self.duration = duration
    }
}

public struct AVMediaType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let video = AVMediaType(rawValue: "vide")
    public static let audio = AVMediaType(rawValue: "soun")
}

public struct AVFileType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let mp4 = AVFileType(rawValue: "public.mpeg-4")
    public static let m4a = AVFileType(rawValue: "com.apple.m4a-audio")
    public static let mov = AVFileType(rawValue: "com.apple.quicktime-movie")
}

public struct AVVideoCodecType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let h264 = AVVideoCodecType(rawValue: "avc1")
    public static let hevc = AVVideoCodecType(rawValue: "hvc1")
}

public let AVVideoCodecKey = "AVVideoCodecKey"
public let AVVideoWidthKey = "AVVideoWidthKey"
public let AVVideoHeightKey = "AVVideoHeightKey"
public let AVVideoCompressionPropertiesKey = "AVVideoCompressionPropertiesKey"
public let AVVideoAverageBitRateKey = "AverageBitRate"
public let AVVideoExpectedSourceFrameRateKey = "ExpectedFrameRate"

public final class AVAssetWriter: @unchecked Sendable {
    public enum Status: Int, Sendable {
        case unknown, writing, completed, failed, cancelled
    }

    public let outputURL: URL
    public let outputFileType: AVFileType
    public private(set) var inputs: [AVAssetWriterInput] = []
    public private(set) var status: Status = .unknown
    public private(set) var error: Error?

    public init(outputURL: URL, fileType: AVFileType) throws {
        guard fileType == .mp4 || fileType == .mov else { throw MediaError("only MP4 is written here, not \(fileType.rawValue)") }
        guard MediaCodecs.backend != nil else { throw MediaError("there is no media backend to encode with") }
        self.outputURL = outputURL
        self.outputFileType = fileType
    }

    public func canAdd(_ input: AVAssetWriterInput) -> Bool {
        status == .unknown && input.mediaType == .video && inputs.isEmpty
            && input.outputSettings?[AVVideoCodecKey] as? AVVideoCodecType == .h264
    }

    public func add(_ input: AVAssetWriterInput) {
        guard canAdd(input) else { return }
        inputs.append(input)
        input.writer = self
    }

    /// Checks the one video input can be encoded. The encoder itself opens
    /// with the first frame, whose time's scale is the film's frame rate
    /// (`CMTime(value: frame, timescale: fps)`), which MediaCodec's rate
    /// control wants and the settings don't carry.
    public func startWriting() -> Bool {
        guard status == .unknown, let input = inputs.first else { return fail("nothing to write") }
        guard let backend = MediaCodecs.backend else { return fail("no media backend") }
        let settings = input.outputSettings ?? [:]
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        guard let width = settings[AVVideoWidthKey] as? Int, let height = settings[AVVideoHeightKey] as? Int, width > 0, height > 0 else {
            return fail("a video's size is missing from its settings")
        }
        let bitRate = compression[AVVideoAverageBitRateKey] as? Int ?? 8_000_000
        let stated = compression[AVVideoExpectedSourceFrameRateKey] as? Int
        let url = outputURL
        try? FileManager.default.removeItem(at: url)
        input.open = { timescale in
            let rate = stated ?? (1 ... 240 ~= Int(timescale) ? Int(timescale) : 30)
            return backend.makeVideoEncoder(writingTo: url, width: width, height: height, framesPerSecond: rate, bitRate: bitRate)
        }
        status = .writing
        return true
    }

    public func startSession(atSourceTime startTime: CMTime) {
        inputs.first?.sessionStart = startTime
    }

    public func cancelWriting() {
        guard status == .writing else { return }
        status = .cancelled
        let url = outputURL
        // After the frames still encoding, which see the status and stop.
        inputs.first?.encoding.sync { [self] in
            inputs.first?.encoder?.cancel()
            inputs.first?.encoder = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Drains the encoder and closes the file off the caller's thread, then
    /// calls `handler`, as AVFoundation does.
    public func finishWriting(completionHandler handler: @escaping @Sendable () -> Void) {
        guard let input = inputs.first else {
            if status != .failed { _ = fail("finished without writing") }
            return DispatchQueue.global().async(execute: handler)
        }
        // On the input's queue, after the frames it's still encoding.
        input.encoding.async { [self] in
            guard status == .writing, let encoder = input.encoder else {
                if status != .failed { _ = fail("finished without writing") }
                return handler()
            }
            if encoder.finish() {
                status = .completed
            } else {
                _ = fail("the encoder could not finish the file")
            }
            inputs.first?.encoder = nil
            handler()
        }
    }

    fileprivate func fail(_ message: String) -> Bool {
        error = MediaError(message)
        status = .failed
        return false
    }
}

public final class AVAssetWriterInput: @unchecked Sendable {
    public let mediaType: AVMediaType
    public let outputSettings: [String: Any]?
    public var expectsMediaDataInRealTime = false
    fileprivate weak var writer: AVAssetWriter?
    fileprivate var encoder: VideoEncoding?
    /// Opens the encoder, given the first frame's timescale.
    fileprivate var open: ((CMTimeScale) -> VideoEncoding?)?
    fileprivate var sessionStart = CMTime.zero
    private var finished = false
    /// Frames are converted and encoded here, in order, so the film renders
    /// its next frame meanwhile; the writer finishes and cancels here too.
    fileprivate let encoding = DispatchQueue(label: "AVAssetWriterInput.encoding", qos: .userInitiated)
    private let lock = NSLock()
    /// Frames appended and not yet encoded.
    private var queued = 0
    /// How many frames may wait to be encoded: one encoding while the next
    /// is converted, and the film rendering the one after.
    private static let depth = 2
    /// Where each frame's YUV is converted, on the encoding queue.
    private var scratch: [UInt8] = []

    public init(mediaType: AVMediaType, outputSettings: [String: Any]?) {
        self.mediaType = mediaType
        self.outputSettings = outputSettings
    }

    /// While writing, and fewer than `depth` frames wait to be encoded.
    public var isReadyForMoreMediaData: Bool {
        !finished && writer?.status == .writing && lock.withLock { queued < Self.depth }
    }

    public func markAsFinished() {
        finished = true
    }

    /// Queues `buffer` to be encoded, keeping it until it has been: the
    /// pool hands it out again only once nothing else holds it.
    fileprivate func append(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard isReadyForMoreMediaData else { return false }
        lock.withLock { queued += 1 }
        encoding.async { [self] in
            _ = encode(buffer, at: time)
            lock.withLock { queued -= 1 }
        }
        return true
    }

    private func encode(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard writer?.status == .writing else { return false }
        if encoder == nil, let open {
            encoder = open(time.timescale)
            self.open = nil
            if encoder == nil { return writer?.fail("no H.264 encoder for the video") ?? false }
        }
        guard let encoder else { return false }
        let layout = encoder.layout
        guard buffer.width >= layout.width, buffer.height >= layout.height, buffer.pixelFormat == kCVPixelFormatType_32BGRA else {
            return writer?.fail("a frame doesn't match the video") ?? false
        }
        if scratch.count != layout.byteCount { scratch = [UInt8](repeating: 0, count: layout.byteCount) }
        let microseconds = max(0, time.microseconds - sessionStart.microseconds)
        let encoded = scratch.withUnsafeMutableBytes { yuv -> Bool in
            if buffer.isHeldAsRendered {
                YUVConversion.convert(rendered: buffer.baseAddress, bytesPerRow: buffer.bytesPerRow, rows: buffer.height, into: yuv.baseAddress!, layout: layout)
            } else {
                YUVConversion.convert(bgra: buffer.baseAddress, bytesPerRow: buffer.bytesPerRow, into: yuv.baseAddress!, layout: layout)
            }
            return encoder.encode(UnsafeRawBufferPointer(yuv), presentationUs: microseconds)
        }
        return encoded || (writer?.fail("the encoder refused a frame") ?? false)
    }
}

public final class AVAssetWriterInputPixelBufferAdaptor: @unchecked Sendable {
    public let assetWriterInput: AVAssetWriterInput
    public let sourcePixelBufferAttributes: [String: Any]?
    private var pool: CVPixelBufferPool?

    public init(assetWriterInput input: AVAssetWriterInput, sourcePixelBufferAttributes attributes: [String: Any]?) {
        assetWriterInput = input
        sourcePixelBufferAttributes = attributes
    }

    /// Buffers of the attributes' size, once the writer has started.
    public var pixelBufferPool: CVPixelBufferPool? {
        guard assetWriterInput.isReadyForMoreMediaData else { return nil }
        if let pool { return pool }
        let attributes = sourcePixelBufferAttributes ?? [:]
        guard let width = attributes[kCVPixelBufferWidthKey] as? Int, let height = attributes[kCVPixelBufferHeightKey] as? Int else { return nil }
        let made = CVPixelBufferPool(width: width, height: height, pixelFormat: attributes[kCVPixelBufferPixelFormatTypeKey] as? OSType ?? kCVPixelFormatType_32BGRA)
        pool = made
        return made
    }

    public func append(_ pixelBuffer: CVPixelBuffer, withPresentationTime presentationTime: CMTime) -> Bool {
        assetWriterInput.append(pixelBuffer, at: presentationTime)
    }
}
