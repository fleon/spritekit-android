import CAndroidAudio
import CAndroidMedia
import Foundation
import PlatformShim

/// The AVFoundation stand-ins' device half on Android: the NDK's MediaCodec,
/// MediaMuxer and MediaExtractor, through `CAndroidMedia`, and the
/// soundtrack's own AAC decoder (`CAndroidAudio`) for reading music.
public final class NDKMediaBackend: MediaBackend {
    public init() {}

    /// Installs it for `AVAssetWriter`, `AVAudioFile` and the export.
    public static func install() {
        MediaCodecs.backend = NDKMediaBackend()
    }

    public func makeVideoEncoder(writingTo url: URL, width: Int, height: Int, framesPerSecond: Int, bitRate: Int) -> VideoEncoding? {
        guard let encoder = ska_video_open(url.path, Int32(width), Int32(height), Int32(framesPerSecond), Int32(bitRate)) else { return nil }
        return VideoEncoder(encoder, width: width, height: height)
    }

    public func makeAudioEncoder(writingTo url: URL, sampleRate: Int, channels: Int, bitRate: Int) -> AudioEncoding? {
        ska_aac_open(url.path, Int32(sampleRate), Int32(channels), Int32(bitRate)).map(AudioEncoder.init)
    }

    public func openAudio(_ url: URL) -> AudioDecoding? {
        ska_audio_open_path(url.path).map(AudioDecoder.init)
    }

    public func durationUs(of url: URL, video: Bool) -> Int64? {
        let duration = sw_media_duration_us(url.path, video)
        return duration >= 0 ? duration : nil
    }

    public func remux(_ tracks: [RemuxTrack], into output: URL) -> Bool {
        let paths = tracks.map { strdup($0.url.path) }
        defer { paths.forEach { free($0) } }
        let video = tracks.map(\.isVideo)
        let limits = tracks.map { $0.limitUs ?? 0 }
        let constPaths = paths.map { UnsafePointer($0) }
        return constPaths.withUnsafeBufferPointer { p in
            video.withUnsafeBufferPointer { v in
                limits.withUnsafeBufferPointer { l in
                    sw_media_remux(output.path, p.baseAddress, v.baseAddress, l.baseAddress, Int32(tracks.count))
                }
            }
        }
    }
}

private final class VideoEncoder: VideoEncoding {
    private var encoder: OpaquePointer?
    let layout: YUVLayout

    init(_ encoder: OpaquePointer, width: Int, height: Int) {
        self.encoder = encoder
        layout = YUVLayout(
            planes: ska_video_color_format(encoder) == 19 ? .planar : .semiPlanar,
            width: width,
            height: height,
            stride: Int(ska_video_stride(encoder)),
            sliceHeight: Int(ska_video_slice_height(encoder))
        )
    }

    deinit { cancel() }

    func encode(_ frame: UnsafeRawBufferPointer, presentationUs: Int64) -> Bool {
        guard let encoder, let base = frame.baseAddress else { return false }
        return ska_video_encode(encoder, base.assumingMemoryBound(to: UInt8.self), frame.count, presentationUs)
    }

    func finish() -> Bool {
        guard let encoder else { return false }
        self.encoder = nil
        return ska_video_finish(encoder)
    }

    func cancel() {
        guard let encoder else { return }
        self.encoder = nil
        ska_video_cancel(encoder)
    }
}

private final class AudioEncoder: AudioEncoding {
    private var encoder: OpaquePointer?

    init(_ encoder: OpaquePointer) {
        self.encoder = encoder
    }

    deinit { _ = finish() }

    func encode(_ samples: UnsafePointer<Int16>, frames: Int) -> Bool {
        guard let encoder else { return false }
        return ska_aac_encode(encoder, samples, Int64(frames))
    }

    func finish() -> Bool {
        guard let encoder else { return false }
        self.encoder = nil
        return ska_aac_finish(encoder)
    }
}

private final class AudioDecoder: AudioDecoding {
    private let decoder: OpaquePointer
    let sampleRate: Int
    let channels: Int
    let durationUs: Int64

    init(_ decoder: OpaquePointer) {
        self.decoder = decoder
        sampleRate = Int(ska_audio_sample_rate(decoder))
        channels = Int(ska_audio_channels(decoder))
        durationUs = ska_audio_duration_us(decoder)
    }

    deinit { ska_audio_close(decoder) }

    func read(into out: UnsafeMutablePointer<Int16>, frames: Int) -> (frames: Int, positionUs: Int64) {
        var position: Int64 = 0
        let count = ska_audio_read(decoder, out, Int64(frames), &position)
        return (Int(count), position)
    }

    func seek(to positionUs: Int64) -> Bool {
        ska_audio_seek(decoder, positionUs)
    }
}
