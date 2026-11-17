import Foundation

// The device half of the AVFoundation stand-ins, which `SolutionFilm` and
// `FilmSoundtrack` write a share film through: an H.264 encoder writing an
// MP4, an AAC encoder writing an M4A, a compressed-audio decoder, and a
// remux that copies tracks from files into one. On Android these are the
// NDK's MediaCodec, MediaMuxer and MediaExtractor (`Shell/Sources/
// CAndroidMedia`), as the soundtrack's decoder already is; everything
// above them — the AVFoundation names, the frame timing, the colour
// conversion, WAV files, the mix's buffers — is here and tested on the Mac.

/// How the encoder wants a frame's YUV laid out.
public struct YUVLayout: Equatable, Sendable {
    public enum Planes: Sendable {
        /// Y, then interleaved U and V (NV12): MediaCodec's
        /// `COLOR_FormatYUV420SemiPlanar`.
        case semiPlanar
        /// Y, then U, then V (I420): `COLOR_FormatYUV420Planar`.
        case planar
    }

    public var planes: Planes
    public var width: Int
    public var height: Int
    /// Bytes from one luma row to the next; chroma rows are half.
    public var stride: Int
    /// Rows of luma before the chroma starts.
    public var sliceHeight: Int

    public init(planes: Planes, width: Int, height: Int, stride: Int? = nil, sliceHeight: Int? = nil) {
        self.planes = planes
        self.width = width
        self.height = height
        self.stride = max(stride ?? width, width)
        self.sliceHeight = max(sliceHeight ?? height, height)
    }

    /// The bytes a frame takes.
    public var byteCount: Int { stride * sliceHeight + (stride / 2) * (sliceHeight / 2) * 2 }
}

/// An H.264 encoder writing frames to an MP4 as they come.
public protocol VideoEncoding: AnyObject {
    /// How `encode` wants its frames.
    var layout: YUVLayout { get }
    /// Encodes one frame, `presentationUs` into the video.
    func encode(_ frame: UnsafeRawBufferPointer, presentationUs: Int64) -> Bool
    /// Drains the encoder and closes the file. False if it couldn't.
    func finish() -> Bool
    /// Stops without finishing the file.
    func cancel()
}

/// A compressed audio file, decoded as it's read.
public protocol AudioDecoding: AnyObject {
    var sampleRate: Int { get }
    var channels: Int { get }
    var durationUs: Int64 { get }
    /// Up to `frames` frames of interleaved 16-bit PCM into `out`, and the
    /// presentation time of the first; 0 frames at the end.
    func read(into out: UnsafeMutablePointer<Int16>, frames: Int) -> (frames: Int, positionUs: Int64)
    /// Moves to `positionUs`, exactly.
    func seek(to positionUs: Int64) -> Bool
}

/// An AAC encoder writing an M4A.
public protocol AudioEncoding: AnyObject {
    /// Encodes `frames` frames of interleaved 16-bit PCM.
    func encode(_ samples: UnsafePointer<Int16>, frames: Int) -> Bool
    func finish() -> Bool
}

/// A track to copy into a remuxed file, up to `limitUs` of it.
public struct RemuxTrack: Equatable, Sendable {
    public var url: URL
    public var isVideo: Bool
    public var limitUs: Int64?

    public init(url: URL, isVideo: Bool, limitUs: Int64?) {
        self.url = url
        self.isVideo = isVideo
        self.limitUs = limitUs
    }
}

public protocol MediaBackend: AnyObject {
    func makeVideoEncoder(writingTo url: URL, width: Int, height: Int, framesPerSecond: Int, bitRate: Int) -> VideoEncoding?
    func makeAudioEncoder(writingTo url: URL, sampleRate: Int, channels: Int, bitRate: Int) -> AudioEncoding?
    func openAudio(_ url: URL) -> AudioDecoding?
    /// How long the file's first track of the kind runs, in microseconds.
    func durationUs(of url: URL, video: Bool) -> Int64?
    /// Copies each track's samples, as they are, into one MP4 at `output`.
    func remux(_ tracks: [RemuxTrack], into output: URL) -> Bool
}

/// The backend the stand-ins use: the shell installs the NDK's as it starts.
public enum MediaCodecs {
    public nonisolated(unsafe) static var backend: MediaBackend?
}

public struct MediaError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
