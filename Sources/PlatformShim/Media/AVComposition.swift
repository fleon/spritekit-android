import Foundation

// AVFoundation's assets and compositions, as far as `FilmSoundtrack` joins a
// silent film to its soundtrack: each file's first track of a kind and how
// long it runs, a composition holding the two from their starts, and a
// passthrough export that copies their samples as they are into one MP4.
// On Android the copy is MediaExtractor into MediaMuxer (`remux`).

public class AVAsset: @unchecked Sendable {
    public init() {}

    /// The file it reads, for the media backend.
    public var url: URL? { nil }

    public func loadTracks(withMediaType mediaType: AVMediaType) async throws -> [AVAssetTrack] { [] }

    public func load<Value>(_ property: AVAsyncProperty<AVAsset, Value>) async throws -> Value {
        try property.get(self)
    }

    fileprivate func duration() throws -> CMTime { .zero }
}

/// What `load(_:)` loads: `.duration`, the one the film asks for.
public struct AVAsyncProperty<Root, Value>: @unchecked Sendable {
    fileprivate let get: (Root) throws -> Value
}

public extension AVAsyncProperty where Root == AVAsset, Value == CMTime {
    static var duration: AVAsyncProperty<AVAsset, CMTime> {
        AVAsyncProperty { try $0.duration() }
    }
}

public final class AVURLAsset: AVAsset, @unchecked Sendable {
    private let fileURL: URL

    public init(url: URL, options: [String: Any]? = nil) {
        fileURL = url
    }

    public override var url: URL? { fileURL }

    public override func loadTracks(withMediaType mediaType: AVMediaType) async throws -> [AVAssetTrack] {
        guard let backend = MediaCodecs.backend else { throw MediaError("no media backend") }
        guard let us = backend.durationUs(of: fileURL, video: mediaType == .video) else { return [] }
        return [AVAssetTrack(url: fileURL, mediaType: mediaType, durationUs: us)]
    }

    /// The longest of its tracks, as AVFoundation reports an asset's.
    fileprivate override func duration() throws -> CMTime {
        guard let backend = MediaCodecs.backend else { throw MediaError("no media backend") }
        let us = [true, false].compactMap { backend.durationUs(of: fileURL, video: $0) }.max()
        guard let us else { throw MediaError("\(fileURL.lastPathComponent) has no tracks") }
        return CMTime(value: us, timescale: 1_000_000)
    }
}

public class AVAssetTrack: @unchecked Sendable {
    public let mediaType: AVMediaType
    let url: URL
    let durationUs: Int64

    init(url: URL, mediaType: AVMediaType, durationUs: Int64) {
        self.url = url
        self.mediaType = mediaType
        self.durationUs = durationUs
    }
}

public final class AVMutableCompositionTrack: @unchecked Sendable {
    public let mediaType: AVMediaType
    /// What's been put in it: one source track, from its start, and how much.
    fileprivate var segment: (track: AVAssetTrack, duration: CMTime)?

    init(mediaType: AVMediaType) {
        self.mediaType = mediaType
    }

    /// Takes `timeRange` of `track` at `startTime`. Passthrough copies a
    /// file's samples whole from its start, so that's all that's taken:
    /// one range, from the start, at the start.
    public func insertTimeRange(_ timeRange: CMTimeRange, of track: AVAssetTrack, at startTime: CMTime) throws {
        guard segment == nil, timeRange.start == .zero, startTime == .zero, track.mediaType == mediaType else {
            throw MediaError("a composition here holds one range per track, from the start")
        }
        segment = (track, timeRange.duration)
    }
}

public final class AVMutableComposition: AVAsset, @unchecked Sendable {
    public private(set) var tracks: [AVMutableCompositionTrack] = []

    public override init() {}

    public func addMutableTrack(withMediaType mediaType: AVMediaType, preferredTrackID: CMPersistentTrackID) -> AVMutableCompositionTrack? {
        let track = AVMutableCompositionTrack(mediaType: mediaType)
        tracks.append(track)
        return track
    }

    fileprivate override func duration() throws -> CMTime {
        tracks.compactMap { $0.segment?.duration }.max() ?? .zero
    }

    /// What a passthrough export copies.
    var remuxTracks: [RemuxTrack] {
        tracks.compactMap { track in
            track.segment.map { RemuxTrack(url: $0.track.url, isVideo: track.mediaType == .video, limitUs: $0.duration.microseconds) }
        }
    }
}

public let AVAssetExportPresetPassthrough = "AVAssetExportPresetPassthrough"

public final class AVAssetExportSession: @unchecked Sendable {
    public enum Status: Int, Sendable {
        case unknown, waiting, exporting, completed, failed, cancelled
    }

    public let asset: AVAsset
    public let presetName: String
    public var outputURL: URL?
    public var outputFileType: AVFileType?
    public private(set) var status: Status = .unknown
    public private(set) var error: Error?

    /// Passthrough of a composition only: that's all a film needs, and the
    /// one export MediaMuxer can do without re-encoding.
    public init?(asset: AVAsset, presetName: String) {
        guard presetName == AVAssetExportPresetPassthrough, asset is AVMutableComposition else { return nil }
        self.asset = asset
        self.presetName = presetName
    }

    public func exportAsynchronously(completionHandler handler: @escaping @Sendable () -> Void) {
        status = .exporting
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { handler() }
            guard let output = outputURL, outputFileType == nil || outputFileType == .mp4 || outputFileType == .m4a,
                  let composition = asset as? AVMutableComposition, let backend = MediaCodecs.backend else {
                error = MediaError("nothing to export to")
                status = .failed
                return
            }
            let tracks = composition.remuxTracks
            guard !tracks.isEmpty, backend.remux(tracks, into: output) else {
                error = MediaError("the tracks could not be copied into \(output.lastPathComponent)")
                status = .failed
                return
            }
            status = .completed
        }
    }
}
