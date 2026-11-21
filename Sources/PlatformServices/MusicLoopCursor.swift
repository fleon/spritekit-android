import Foundation

/// Where a backend that decodes a track itself stands in it, in frames: the
/// track plays from its first frame once, then repeats its loop, as
/// `AVAudioPlayerNode` plays the segments Apple's backend schedules.
///
/// It counts the frames it is told were read rather than asking the decoder
/// where it is: a decoder's presentation times need not say which frame a
/// buffer holds (an AAC decoder that trims the encoder's priming keeps the
/// stamps of the packets the frames came from).
public struct MusicLoopCursor: Equatable, Sendable {
    /// What to do next.
    public enum Step: Equatable, Sendable {
        /// Read up to this many frames.
        case read(Int)
        /// Seek to this frame, then carry on.
        case seek(Int64)
        /// The track has played to its end and doesn't repeat.
        case end
    }

    /// The section that repeats, or nil for a track that plays once. A loop
    /// that doesn't start before it ends repeats the whole file, as Apple's
    /// backend does with one.
    public let loop: MusicLoop?
    /// The frame the next read starts at.
    public private(set) var frame: Int64 = 0
    /// How many times it has gone back to the loop's start.
    public private(set) var loops = 0

    public init(loop: MusicLoop?) {
        if let loop, !(0 <= loop.start && loop.start < loop.end) {
            self.loop = .wholeTrack
        } else {
            self.loop = loop
        }
    }

    /// What to do before reading at most `limit` more frames: read up to the
    /// loop's end and no further, then go back to its start.
    public func next(upTo limit: Int) -> Step {
        guard let loop else { return .read(limit) }
        guard frame < loop.end else { return .seek(loop.start) }
        return .read(Int(min(Int64(limit), loop.end - frame)))
    }

    /// What to do when the decoder runs out before the loop's end: go round
    /// from the loop's start (the whole file's end, for `wholeTrack`), or
    /// stop for a track that doesn't repeat.
    public var atEndOfFile: Step {
        loop.map { .seek($0.start) } ?? .end
    }

    /// `frames` frames were read from `frame` on.
    public mutating func didRead(_ frames: Int) {
        frame += Int64(max(0, frames))
    }

    /// The decoder is now at `frame`, after a `.seek` step.
    public mutating func didSeek(to frame: Int64) {
        self.frame = frame
        loops += 1
    }

    /// Fills a block of up to `frames` frames, going back to the loop's
    /// start each time it reaches the loop's end. `read(offset, count)`
    /// decodes up to `count` frames into the block at `offset` and returns
    /// how many it did, 0 at the end of the file; `seek(frame)` moves the
    /// decoder to `frame` exactly. Returns the frames filled: fewer than
    /// asked only at the end of a track that doesn't repeat, or when the
    /// decoder fails or the loop starts past the file's end.
    public mutating func fill(_ frames: Int, read: (_ offset: Int, _ count: Int) -> Int, seek: (_ frame: Int64) -> Bool) -> Int {
        var filled = 0
        // Seeks since the last frame read: a second in a row means there is
        // nothing to read where the loop starts.
        var seeks = 0
        while filled < frames {
            var step = next(upTo: frames - filled)
            if case let .read(count) = step {
                let got = min(read(filled, count), count)
                if got > 0 {
                    didRead(got)
                    filled += got
                    seeks = 0
                    continue
                }
                step = atEndOfFile
            }
            guard case let .seek(frame) = step, seeks < 2, seek(frame) else { break }
            didSeek(to: frame)
            seeks += 1
        }
        return filled
    }
}
