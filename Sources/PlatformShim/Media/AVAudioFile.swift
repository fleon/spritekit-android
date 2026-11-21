import Foundation

// AVFAudio, as a game mixes a film's soundtrack: its music read from its
// AAC, round its loop, and its sounds read from their WAVs, each into float
// buffers a channel apiece, then written out as AAC a second at a time.
//
// Reading a WAV is plain Swift (`WAVFile`). AAC goes through the media
// backend's decoder, which counts frames as the runtime's own soundtrack
// player does, so `framePosition` means what a game's loop points
// (`MusicLoop`) mean; and the writer encodes through its AAC encoder,
// closing the file when the last reference to it goes, as AVAudioFile does.

public typealias AVAudioFrameCount = UInt32
public typealias AVAudioFramePosition = Int64
public typealias AVAudioChannelCount = UInt32
public typealias AudioFormatID = UInt32

public let kAudioFormatLinearPCM: AudioFormatID = 0x6C70_636D // 'lpcm'
public let kAudioFormatMPEG4AAC: AudioFormatID = 0x6161_6320 // 'aac '

public let AVFormatIDKey = "AVFormatIDKey"
public let AVSampleRateKey = "AVSampleRateKey"
public let AVNumberOfChannelsKey = "AVNumberOfChannelsKey"
public let AVEncoderBitRateKey = "AVEncoderBitRateKey"

public enum AVAudioCommonFormat: Int, Sendable {
    case otherFormat, pcmFormatFloat32, pcmFormatFloat64, pcmFormatInt16, pcmFormatInt32
}

/// Always deinterleaved 32-bit float here: the only format the film mixes in.
public final class AVAudioFormat: @unchecked Sendable {
    public let sampleRate: Double
    public let channelCount: AVAudioChannelCount
    public let commonFormat: AVAudioCommonFormat = .pcmFormatFloat32
    public let isInterleaved = false

    public init?(standardFormatWithSampleRate sampleRate: Double, channels: AVAudioChannelCount) {
        guard sampleRate > 0, channels > 0 else { return nil }
        self.sampleRate = sampleRate
        channelCount = channels
    }
}

public final class AVAudioPCMBuffer: @unchecked Sendable {
    public let format: AVAudioFormat
    public let frameCapacity: AVAudioFrameCount
    public var frameLength: AVAudioFrameCount = 0 {
        didSet { frameLength = min(frameLength, frameCapacity) }
    }

    private let channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    public init?(pcmFormat format: AVAudioFormat, frameCapacity: AVAudioFrameCount) {
        self.format = format
        self.frameCapacity = frameCapacity
        let count = Int(format.channelCount)
        channels = .allocate(capacity: count)
        for channel in 0 ..< count {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: max(1, Int(frameCapacity)))
            samples.initialize(repeating: 0, count: max(1, Int(frameCapacity)))
            (channels + channel).initialize(to: samples)
        }
    }

    deinit {
        for channel in 0 ..< Int(format.channelCount) { channels[channel].deallocate() }
        channels.deallocate()
    }

    public var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? { UnsafePointer(channels) }
}

public final class AVAudioFile: @unchecked Sendable {
    public let url: URL
    public let processingFormat: AVAudioFormat
    public var fileFormat: AVAudioFormat { processingFormat }
    /// Frames in the file: read from it, or written so far.
    public private(set) var length: AVAudioFramePosition = 0
    /// Where the next read starts (or where the next write lands).
    public var framePosition: AVAudioFramePosition = 0

    private enum Source {
        case wav(WAVFile)
        case decoder(AudioDecoding)
        case encoder(AudioEncoding)
    }

    private let source: Source
    /// Where the decoder stands, in frames, so a read that follows the last
    /// one doesn't seek.
    private var decoderPosition: AVAudioFramePosition = 0
    private var scratch: [Int16] = []

    public init(forReading fileURL: URL) throws {
        url = fileURL
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        if let wav = WAVFile(data) {
            source = .wav(wav)
            processingFormat = AVAudioFormat(standardFormatWithSampleRate: Double(wav.sampleRate), channels: AVAudioChannelCount(wav.channels))!
            length = AVAudioFramePosition(wav.frameCount)
            return
        }
        guard let decoder = MediaCodecs.backend?.openAudio(fileURL),
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(decoder.sampleRate), channels: AVAudioChannelCount(decoder.channels)) else {
            throw MediaError("\(fileURL.lastPathComponent) could not be decoded")
        }
        source = .decoder(decoder)
        processingFormat = format
        length = decoder.durationUs * AVAudioFramePosition(decoder.sampleRate) / 1_000_000
    }

    public init(forWriting fileURL: URL, settings: [String: Any], commonFormat: AVAudioCommonFormat, interleaved: Bool) throws {
        url = fileURL
        guard settings[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC else { throw MediaError("only AAC is written here") }
        let rate = settings[AVSampleRateKey] as? Double ?? (settings[AVSampleRateKey] as? Int).map(Double.init) ?? 48_000
        let channels = settings[AVNumberOfChannelsKey] as? AVAudioChannelCount ?? (settings[AVNumberOfChannelsKey] as? Int).map { AVAudioChannelCount($0) } ?? 2
        let bitRate = settings[AVEncoderBitRateKey] as? Int ?? 128_000
        guard commonFormat == .pcmFormatFloat32, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels) else {
            throw MediaError("the soundtrack is mixed in 32-bit float")
        }
        try? FileManager.default.removeItem(at: fileURL)
        guard let encoder = MediaCodecs.backend?.makeAudioEncoder(writingTo: fileURL, sampleRate: Int(rate), channels: Int(channels), bitRate: bitRate) else {
            throw MediaError("no AAC encoder")
        }
        processingFormat = format
        source = .encoder(encoder)
    }

    deinit {
        if case let .encoder(encoder) = source { _ = encoder.finish() }
    }

    public func read(into buffer: AVAudioPCMBuffer) throws {
        try read(into: buffer, frameCount: buffer.frameCapacity)
    }

    /// Reads up to `frames` frames from `framePosition` on, every channel;
    /// none once the file runs out.
    public func read(into buffer: AVAudioPCMBuffer, frameCount frames: AVAudioFrameCount) throws {
        guard let out = buffer.floatChannelData else { throw MediaError("no buffer to read into") }
        let wanted = Int(min(frames, buffer.frameCapacity))
        let outChannels = Int(buffer.format.channelCount)
        let channels = Int(processingFormat.channelCount)
        var got = 0
        switch source {
        case let .wav(wav):
            got = wav.read(from: Int(framePosition), frames: wanted) { frame, channel, value in
                if channel < outChannels { out[channel][frame] = value }
            }
        case let .decoder(decoder):
            if decoderPosition != framePosition {
                let us = framePosition * 1_000_000 / AVAudioFramePosition(decoder.sampleRate)
                guard decoder.seek(to: us) else { throw MediaError("couldn't seek \(url.lastPathComponent)") }
                decoderPosition = framePosition
            }
            if scratch.count < wanted * channels { scratch = [Int16](repeating: 0, count: wanted * channels) }
            while got < wanted {
                let (count, _) = scratch.withUnsafeMutableBufferPointer { samples in
                    decoder.read(into: samples.baseAddress! + got * channels, frames: wanted - got)
                }
                if count <= 0 { break }
                got += count
            }
            for frame in 0 ..< got {
                for channel in 0 ..< min(channels, outChannels) {
                    out[channel][frame] = Float(scratch[frame * channels + channel]) / 32768
                }
            }
            decoderPosition += AVAudioFramePosition(got)
        case .encoder:
            throw MediaError("\(url.lastPathComponent) is open for writing")
        }
        buffer.frameLength = AVAudioFrameCount(got)
        framePosition += AVAudioFramePosition(got)
    }

    public func write(from buffer: AVAudioPCMBuffer) throws {
        guard case let .encoder(encoder) = source else { throw MediaError("\(url.lastPathComponent) is open for reading") }
        guard let input = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(processingFormat.channelCount)
        let inChannels = Int(buffer.format.channelCount)
        if scratch.count < frames * channels { scratch = [Int16](repeating: 0, count: frames * channels) }
        for frame in 0 ..< frames {
            for channel in 0 ..< channels {
                let value = input[min(channel, inChannels - 1)][frame]
                scratch[frame * channels + channel] = Int16(max(-1, min(1, value)) * 32767)
            }
        }
        let written = scratch.withUnsafeBufferPointer { encoder.encode($0.baseAddress!, frames: frames) }
        guard written else { throw MediaError("the AAC encoder refused the soundtrack") }
        length += AVAudioFramePosition(frames)
        framePosition = length
    }
}
