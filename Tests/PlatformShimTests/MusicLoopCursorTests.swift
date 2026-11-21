import Foundation
import PlatformServices
import Testing

/// A decoder whose frames are their own numbers, handing out at most
/// `chunk` frames a read, as a codec hands out a buffer at a time.
private final class CountingDecoder {
    let length: Int64
    let chunk: Int
    private(set) var frame: Int64 = 0

    init(length: Int64, chunk: Int = 1024) {
        self.length = length
        self.chunk = chunk
    }

    func read(into block: inout [Int64], at offset: Int, count: Int) -> Int {
        let got = Int(max(0, min(Int64(min(count, chunk)), length - frame)))
        for index in 0..<got { block[offset + index] = frame + Int64(index) }
        frame += Int64(got)
        return got
    }

    func seek(to frame: Int64) -> Bool {
        self.frame = frame
        return true
    }
}

/// Plays `frames` frames in blocks of up to `block`, as the mixer does, and
/// returns the decoder's frame numbers in the order they were heard.
private func play(_ cursor: inout MusicLoopCursor, _ decoder: CountingDecoder, frames: Int, block: Int = 4096) -> [Int64] {
    var heard: [Int64] = []
    var buffer = [Int64](repeating: -1, count: block)
    while heard.count < frames {
        let wanted = min(block, frames - heard.count)
        let filled = cursor.fill(wanted, read: { decoder.read(into: &buffer, at: $0, count: $1) }, seek: decoder.seek(to:))
        heard += buffer[0..<filled]
        if filled < wanted { break }
    }
    return heard
}

private func frames(_ range: Range<Int64>) -> [Int64] { Array(range) }

@Suite("Music loop cursor")
struct MusicLoopCursorTests {
    @Test("A track plays from its first frame to the loop's end once, then repeats the loop, frame for frame")
    func introThenLoop() {
        var cursor = MusicLoopCursor(loop: MusicLoop(start: 1_000, end: 5_000))
        let heard = play(&cursor, CountingDecoder(length: 6_000, chunk: 700), frames: 13_000)
        #expect(heard == frames(0..<5_000) + frames(1_000..<5_000) + frames(1_000..<5_000))
        #expect(cursor.loops == 2)
    }

    @Test("A read that lands exactly on the loop's end goes round, rather than playing on into the tail")
    func readEndingOnTheLoopEnd() {
        // Blocks of 4096 reach 8192 exactly: the frames after it are the
        // file's tail, which is there for the encoder and is never heard.
        var cursor = MusicLoopCursor(loop: MusicLoop(start: 2_048, end: 8_192))
        let heard = play(&cursor, CountingDecoder(length: 16_384), frames: 8_192 + 6_144 + 100)
        #expect(heard == frames(0..<8_192) + frames(2_048..<8_192) + frames(2_048..<2_148))
        #expect(!heard.contains { $0 >= 8_192 })
    }

    @Test("Where the decoder stands is counted from the frames read, whatever the reads' sizes")
    func countsFrames() {
        var cursor = MusicLoopCursor(loop: MusicLoop(start: 300, end: 1_000))
        _ = play(&cursor, CountingDecoder(length: 2_000, chunk: 333), frames: 999, block: 128)
        #expect(cursor.frame == 999)
        #expect(cursor.next(upTo: 128) == .read(1))
        cursor.didRead(1)
        #expect(cursor.next(upTo: 128) == .seek(300))
    }

    @Test("The whole track repeats from its first frame when the file runs out")
    func wholeTrack() {
        var cursor = MusicLoopCursor(loop: .wholeTrack)
        let heard = play(&cursor, CountingDecoder(length: 3_000), frames: 7_000)
        #expect(heard == frames(0..<3_000) + frames(0..<3_000) + frames(0..<1_000))
    }

    @Test("A loop that ends past the file goes round at the file's end")
    func loopEndPastTheFile() {
        var cursor = MusicLoopCursor(loop: MusicLoop(start: 1_000, end: 99_999))
        let heard = play(&cursor, CountingDecoder(length: 3_000), frames: 5_000)
        #expect(heard == frames(0..<3_000) + frames(1_000..<3_000))
    }

    @Test("A loop that doesn't start before it ends repeats the whole file, as Apple's backend does")
    func emptyLoop() {
        #expect(MusicLoopCursor(loop: MusicLoop(start: 5, end: 5)).loop == .wholeTrack)
        #expect(MusicLoopCursor(loop: MusicLoop(start: -1, end: 5)).loop == .wholeTrack)
    }

    @Test("A track that doesn't loop plays to its end once")
    func noLoop() {
        var cursor = MusicLoopCursor(loop: nil)
        let decoder = CountingDecoder(length: 3_000)
        #expect(play(&cursor, decoder, frames: 10_000) == frames(0..<3_000))
        #expect(play(&cursor, decoder, frames: 10_000).isEmpty)
        #expect(cursor.loops == 0)
    }

    @Test("A loop that starts past the file's end falls silent instead of seeking for ever")
    func loopStartPastTheFile() {
        var cursor = MusicLoopCursor(loop: MusicLoop(start: 10_000, end: 20_000))
        let decoder = CountingDecoder(length: 3_000)
        #expect(play(&cursor, decoder, frames: 10_000) == frames(0..<3_000))
        #expect(play(&cursor, decoder, frames: 10_000).isEmpty)
    }
}
