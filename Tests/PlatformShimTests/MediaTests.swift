import Foundation
import Testing
@testable import PlatformShim
import SpriteKitShim

// The AVFoundation stand-ins a film is written through, against a
// backend that records what it is handed. The device half — MediaCodec,
// MediaMuxer, MediaExtractor — is the shell's; everything above it is here.

private final class RecordingBackend: MediaBackend {
    final class Video: VideoEncoding {
        let layout: YUVLayout
        let rate: Int
        let bitRate: Int
        var frames: [(us: Int64, bytes: [UInt8])] = []
        var finished = false
        var cancelled = false
        init(layout: YUVLayout, rate: Int, bitRate: Int) {
            self.layout = layout
            self.rate = rate
            self.bitRate = bitRate
        }
        var gate: DispatchSemaphore?
        func encode(_ frame: UnsafeRawBufferPointer, presentationUs: Int64) -> Bool {
            gate?.wait()
            frames.append((presentationUs, Array(frame)))
            return true
        }
        func finish() -> Bool { finished = true; return true }
        func cancel() { cancelled = true }
    }

    final class Encoder: AudioEncoding {
        var samples: [Int16] = []
        var finished = false
        func encode(_ samples: UnsafePointer<Int16>, frames: Int) -> Bool {
            self.samples += UnsafeBufferPointer(start: samples, count: frames * 2)
            return true
        }
        func finish() -> Bool { finished = true; return true }
    }

    /// A stereo "AAC" whose left sample is its frame number and right its
    /// negative, so where a read landed shows in what it read.
    final class Decoder: AudioDecoding {
        let sampleRate = 1000
        let channels = 2
        let durationUs: Int64 = 10_000_000
        var position = 0
        var seeks: [Int64] = []
        func read(into out: UnsafeMutablePointer<Int16>, frames: Int) -> (frames: Int, positionUs: Int64) {
            let count = min(frames, 10_000 - position, 300)
            for i in 0 ..< count {
                out[i * 2] = Int16(position + i)
                out[i * 2 + 1] = -Int16(position + i)
            }
            defer { position += count }
            return (count, Int64(position) * 1000)
        }
        func seek(to positionUs: Int64) -> Bool {
            seeks.append(positionUs)
            position = Int(positionUs / 1000)
            return true
        }
    }

    var videos: [Video] = []
    var encoders: [Encoder] = []
    var decoders: [Decoder] = []
    var remuxed: [([RemuxTrack], URL)] = []
    var planes = YUVLayout.Planes.semiPlanar
    /// Handed to each video encoder: it waits on it before each frame.
    var videoGate: DispatchSemaphore?

    func makeVideoEncoder(writingTo url: URL, width: Int, height: Int, framesPerSecond: Int, bitRate: Int) -> VideoEncoding? {
        let video = Video(layout: YUVLayout(planes: planes, width: width, height: height), rate: framesPerSecond, bitRate: bitRate)
        video.gate = videoGate
        videos.append(video)
        return video
    }
    func makeAudioEncoder(writingTo url: URL, sampleRate: Int, channels: Int, bitRate: Int) -> AudioEncoding? {
        let encoder = Encoder()
        encoders.append(encoder)
        return encoder
    }
    func openAudio(_ url: URL) -> AudioDecoding? {
        let decoder = Decoder()
        decoders.append(decoder)
        return decoder
    }
    func durationUs(of url: URL, video: Bool) -> Int64? {
        url.pathExtension == "mp4" ? (video ? 4_000_000 : nil) : (video ? nil : 5_000_000)
    }
    func remux(_ tracks: [RemuxTrack], into output: URL) -> Bool {
        remuxed.append((tracks, output))
        return true
    }
}

private func temporary(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("media-tests-\(UUID().uuidString)-\(name)")
}

@Suite("Film media", .serialized)
struct MediaTests {
    @Test("BT.709 video range: white, black and the primaries")
    func colours() {
        func yuv(_ b: UInt8, _ g: UInt8, _ r: UInt8) -> (UInt8, UInt8, UInt8) {
            let pixels: [UInt8] = Array([[b, g, r, 255]].joined()) + [b, g, r, 255] + [b, g, r, 255] + [b, g, r, 255]
            var out = [UInt8](repeating: 0, count: 6)
            let layout = YUVLayout(planes: .semiPlanar, width: 2, height: 2)
            pixels.withUnsafeBytes { source in
                out.withUnsafeMutableBytes { YUVConversion.convert(bgra: source.baseAddress!, bytesPerRow: 8, into: $0.baseAddress!, layout: layout) }
            }
            return (out[0], out[4], out[5])
        }
        #expect(yuv(255, 255, 255) == (235, 128, 128))
        #expect(yuv(0, 0, 0) == (16, 128, 128))
        // Red, green and blue as BT.709 puts them, to the nearest step.
        let red = yuv(0, 0, 255), green = yuv(0, 255, 0), blue = yuv(255, 0, 0)
        #expect(abs(Int(red.0) - 63) <= 1 && abs(Int(red.1) - 102) <= 1 && abs(Int(red.2) - 240) <= 1)
        #expect(abs(Int(green.0) - 173) <= 1 && abs(Int(green.1) - 42) <= 1 && abs(Int(green.2) - 26) <= 1)
        #expect(abs(Int(blue.0) - 32) <= 1 && abs(Int(blue.1) - 240) <= 1 && abs(Int(blue.2) - 118) <= 1)
    }

    @Test("Pixels as GL reads them back (RGBA, rows bottom first) convert as the same frame in BGRA does")
    func renderedOrder() {
        let width = 4, height = 4
        // A top-first BGRA frame of distinct pixels, and the same as GL would have it.
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        var rendered = bgra
        for y in 0 ..< height {
            for x in 0 ..< width {
                let r = UInt8(x * 60), g = UInt8(y * 60), b = UInt8(200 - x * 20 - y * 10)
                let i = (y * width + x) * 4, j = ((height - 1 - y) * width + x) * 4
                bgra[i ..< i + 4] = [b, g, r, 255]
                rendered[j ..< j + 4] = [r, g, b, 255]
            }
        }
        let layout = YUVLayout(planes: .semiPlanar, width: width, height: height)
        var fromBGRA = [UInt8](repeating: 0, count: layout.byteCount), fromRendered = fromBGRA
        bgra.withUnsafeBytes { source in
            fromBGRA.withUnsafeMutableBytes { YUVConversion.convert(bgra: source.baseAddress!, bytesPerRow: width * 4, into: $0.baseAddress!, layout: layout) }
        }
        rendered.withUnsafeBytes { source in
            fromRendered.withUnsafeMutableBytes { YUVConversion.convert(rendered: source.baseAddress!, bytesPerRow: width * 4, rows: height, into: $0.baseAddress!, layout: layout) }
        }
        #expect(fromRendered == fromBGRA)

        // Locking the buffer puts it in its own order for anything else.
        let buffer = CVPixelBuffer(width: width, height: height)
        rendered.withUnsafeBytes { buffer.baseAddress.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        buffer.isHeldAsRendered = true
        _ = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        #expect(!buffer.isHeldAsRendered)
        #expect(Array(UnsafeRawBufferPointer(start: buffer.baseAddress, count: buffer.byteCount)) == bgra)
    }

    @Test("Planar output puts U and V in planes of their own, after the luma's slice")
    func planar() {
        let layout = YUVLayout(planes: .planar, width: 4, height: 2, stride: 8, sliceHeight: 4)
        #expect(layout.byteCount == 8 * 4 + 4 * 2 * 2)
        let pixels = [UInt8](repeating: 255, count: 4 * 2 * 4)
        var out = [UInt8](repeating: 0, count: layout.byteCount)
        pixels.withUnsafeBytes { source in
            out.withUnsafeMutableBytes { YUVConversion.convert(bgra: source.baseAddress!, bytesPerRow: 16, into: $0.baseAddress!, layout: layout) }
        }
        #expect(out[0 ..< 4].allSatisfy { $0 == 235 })
        #expect(out[4 ..< 8].allSatisfy { $0 == 0 })
        #expect(out[32] == 128 && out[33] == 128)
        #expect(out[32 + 8] == 128)
    }

    @Test("The writer encodes each appended frame at its time, at the frame rate its timescale gives")
    func writer() throws {
        let backend = RecordingBackend()
        MediaCodecs.backend = backend
        defer { MediaCodecs.backend = nil }
        let writer = try AVAssetWriter(outputURL: temporary("film.mp4"), fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 4,
            AVVideoHeightKey: 2,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: 4,
            kCVPixelBufferHeightKey: 2,
        ])
        #expect(writer.canAdd(input))
        writer.add(input)
        #expect(adaptor.pixelBufferPool == nil)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        #expect(input.isReadyForMoreMediaData)
        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0 ..< 3 {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try #require(buffer)
            pixels.baseAddress.initializeMemory(as: UInt8.self, repeating: 255, count: pixels.byteCount)
            // As a film does: on once the input is ready for more.
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 60)))
        }
        input.markAsFinished()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed)
        let video = try #require(backend.videos.first)
        #expect(video.rate == 60)
        #expect(video.bitRate == 12_000_000)
        #expect(video.frames.map(\.us) == [0, 16_666, 33_333])
        #expect(video.frames[0].bytes.prefix(8).allSatisfy { $0 == 235 })
        #expect(video.finished)
    }

    @Test("Frames encode off the caller's thread in order, two at most waiting, and finishing waits for them")
    func writerQueues() throws {
        let backend = RecordingBackend()
        MediaCodecs.backend = backend
        defer { MediaCodecs.backend = nil }
        let writer = try AVAssetWriter(outputURL: temporary("queued.mp4"), fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 2, AVVideoHeightKey: 2])
        writer.add(input)
        #expect(writer.startWriting())
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        // The encoder holds each frame until let go.
        let gate = DispatchSemaphore(value: 0)
        backend.videoGate = gate
        #expect(adaptor.append(CVPixelBuffer(width: 2, height: 2), withPresentationTime: CMTime(value: 0, timescale: 30)))
        #expect(adaptor.append(CVPixelBuffer(width: 2, height: 2), withPresentationTime: CMTime(value: 1, timescale: 30)))
        #expect(!input.isReadyForMoreMediaData)
        #expect(!adaptor.append(CVPixelBuffer(width: 2, height: 2), withPresentationTime: CMTime(value: 2, timescale: 30)))
        gate.signal()
        gate.signal()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed)
        #expect(backend.videos.first?.frames.map(\.us) == [0, 33_333])
        #expect(backend.videos.first?.finished == true)
    }

    @Test("A writer with no backend can't be made, and a cancelled one drops its encoder")
    func writerFailures() throws {
        MediaCodecs.backend = nil
        #expect(throws: MediaError.self) { try AVAssetWriter(outputURL: temporary("x.mp4"), fileType: .mp4) }
        let backend = RecordingBackend()
        MediaCodecs.backend = backend
        defer { MediaCodecs.backend = nil }
        let writer = try AVAssetWriter(outputURL: temporary("y.mp4"), fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 2, AVVideoHeightKey: 2])
        writer.add(input)
        #expect(writer.startWriting())
        let buffer = CVPixelBuffer(width: 2, height: 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: 0, timescale: 30)))
        // The frame encodes off this thread; once it has, the encoder is open.
        while backend.videos.first?.frames.isEmpty ?? true { Thread.sleep(forTimeInterval: 0.001) }
        writer.cancelWriting()
        #expect(writer.status == .cancelled)
        #expect(backend.videos.first?.cancelled == true)
        #expect(!input.isReadyForMoreMediaData)
        #expect(!adaptor.append(buffer, withPresentationTime: CMTime(value: 1, timescale: 30)))
        #expect(backend.videos.first?.frames.count == 1)
    }

    @Test("A WAV reads as float channels")
    func wav() throws {
        var data = Data("RIFF".utf8)
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let samples: [Int16] = [16384, -16384, 0, 32767]
        data += le32(36 + 8)
        data += Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(2) + le32(44_100) + le32(44_100 * 4) + le16(4) + le16(16)
        data += Data("data".utf8) + le32(8)
        for sample in samples { data += le16(UInt16(bitPattern: sample)) }
        let url = temporary("sound.wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == 44_100)
        #expect(file.processingFormat.channelCount == 2)
        #expect(file.length == 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        #expect(buffer.frameLength == 2)
        let channels = try #require(buffer.floatChannelData)
        #expect(channels[0][0] == 0.5 && channels[1][0] == -0.5)
        #expect(channels[0][1] == 0 && abs(channels[1][1] - 1) < 0.0001)
    }

    @Test("Compressed audio reads on from where it was, and seeks when the position is moved")
    func decodedReads() throws {
        let backend = RecordingBackend()
        MediaCodecs.backend = backend
        defer { MediaCodecs.backend = nil }
        let url = temporary("music.m4a")
        try Data([0, 1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 10_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1000))
        try file.read(into: buffer, frameCount: 1000)
        #expect(buffer.frameLength == 1000)
        #expect(file.framePosition == 1000)
        let channels = try #require(buffer.floatChannelData)
        #expect(channels[0][999] == Float(999) / 32768)
        #expect(channels[1][999] == Float(-999) / 32768)
        try file.read(into: buffer, frameCount: 10)
        #expect(backend.decoders.first?.seeks == [])
        file.framePosition = 4000
        try file.read(into: buffer, frameCount: 10)
        #expect(backend.decoders.first?.seeks == [4_000_000])
        #expect(channels[0][0] == Float(4000) / 32768)
    }

    @Test("The soundtrack is written as 16-bit to the encoder, and the file closes when it goes")
    func audioWriting() throws {
        let backend = RecordingBackend()
        MediaCodecs.backend = backend
        defer { MediaCodecs.backend = nil }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let channels = try #require(buffer.floatChannelData)
        channels[0][0] = 1; channels[1][0] = -1; channels[0][1] = 0.5; channels[1][1] = 2
        do {
            let file = try AVAudioFile(forWriting: temporary("mix.m4a"), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: AVAudioChannelCount(2),
                AVEncoderBitRateKey: 160_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            #expect(file.length == 2)
            #expect(backend.encoders.first?.finished == false)
        }
        let encoder = try #require(backend.encoders.first)
        #expect(encoder.finished)
        #expect(encoder.samples == [32767, -32767, 16383, 32767])
    }

    @Test("A passthrough export copies the composition's tracks, each as long as was inserted")
    func export() async throws {
        let backend = RecordingBackend()
        MediaCodecs.backend = backend
        defer { MediaCodecs.backend = nil }
        let video = AVURLAsset(url: URL(fileURLWithPath: "/tmp/silent.mp4"))
        let audio = AVURLAsset(url: URL(fileURLWithPath: "/tmp/mix.m4a"))
        let composition = AVMutableComposition()
        let videoTrack = try #require(try await video.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await audio.loadTracks(withMediaType: .audio).first)
        let duration = try await video.load(.duration)
        let audioDuration = try await audio.load(.duration)
        #expect(duration == CMTime(value: 4, timescale: 1))
        let picture = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let sound = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try picture.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        try sound.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration)), of: audioTrack, at: .zero)
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        let output = temporary("joined.mp4")
        session.outputURL = output
        session.outputFileType = .mp4
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { done.resume() }
        }
        #expect(session.status == .completed)
        #expect(backend.remuxed.first?.0 == [
            RemuxTrack(url: URL(fileURLWithPath: "/tmp/silent.mp4"), isVideo: true, limitUs: 4_000_000),
            RemuxTrack(url: URL(fileURLWithPath: "/tmp/mix.m4a"), isVideo: false, limitUs: 4_000_000),
        ])
        #expect(backend.remuxed.first?.1 == output)
    }
}

@Suite("Share requests")
struct ShareRequestTests {
    @Test("The game's items sort into the file and the words, the link after the line")
    func sorts() {
        let film = URL(fileURLWithPath: "/data/user/0/app/cache/Level 1.mp4")
        let link = URL(string: "https://apps.apple.com/us/app/example/id1234567890")!
        let request = ShareRequest(items: ["I cleared level 1!", link, film])
        #expect(request.files == [film])
        #expect(request.text == "I cleared level 1! https://apps.apple.com/us/app/example/id1234567890")
        #expect(ShareRequest.mimeType(of: film) == "video/mp4")
        #expect(ShareRequest.mimeType(of: URL(fileURLWithPath: "/x/a.png")) == "image/png")
        #expect(ShareRequest(items: [film]).text == nil)
    }

    @Test("An App Store link becomes the Google Play page; other links stay")
    func linksPlay() {
        AppIdentity.current = .example
        let film = URL(fileURLWithPath: "/data/user/0/app/cache/Level 1.png")
        let appStore = URL(string: "https://apps.apple.com/us/app/example/id1234567890")!
        let play = PlayStorePage.url(language: "ja")
        #expect(play.absoluteString == "https://play.google.com/store/apps/details?id=com.example.game&hl=ja")
        let request = ShareRequest(items: ["I won.", appStore, film], storePage: play)
        #expect(request.text == "I won. \(play.absoluteString)")
        #expect(request.files == [film])
        let code = URL(string: "https://example.com/l/K7Q2MX")!
        #expect(ShareRequest(items: ["Its code is K7Q-2MX.", code], storePage: play).text == "Its code is K7Q-2MX. \(code.absoluteString)")
    }

    @Test("Play's language names: script subtags become regions, Mexico's Spanish Latin America's")
    func playLanguages() {
        AppIdentity.current = .example
        #expect(PlayStorePage.url().absoluteString == "https://play.google.com/store/apps/details?id=com.example.game")
        #expect(PlayStorePage.url(language: "zh-Hans").query == "id=com.example.game&hl=zh-CN")
        #expect(PlayStorePage.url(language: "zh-Hant").query == "id=com.example.game&hl=zh-TW")
        #expect(PlayStorePage.url(language: "es-MX").query == "id=com.example.game&hl=es-419")
        #expect(PlayStorePage.url(language: "pt-BR").query == "id=com.example.game&hl=pt-BR")
        #expect(PlayStorePage.isAppStorePage(URL(string: "https://itunes.apple.com/app/id1")!))
        #expect(!PlayStorePage.isAppStorePage(URL(string: "https://example.com/l/ABC123")!))
    }
}

extension AppIdentity {
    /// The app the store-page tests stand in for. Every test that sets the
    /// identity sets this one, so tests running at once agree on it.
    static let example = AppIdentity(name: "Example", bundleIdentifier: "com.example.game", key: "example")
}
