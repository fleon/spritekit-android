#if !SPRITEKIT_SHIM
import AVFoundation
import Foundation

/// One player node and the track it plays: the file plays from `origin` to
/// the loop's end, then the loop section repeats; a track with no loop plays
/// to its end once. Segments stream from the file and are queued two loops
/// ahead, topped up as the player consumes them.
final class MusicDeck {
    struct Fade {
        var from: Float
        var to: Float
        var start: TimeInterval
        var duration: TimeInterval
    }

    private static let loopsAhead = 2

    let node = AVAudioPlayerNode()
    private(set) var loop: Range<AVAudioFramePosition>?
    var isPlaying = false
    var fade: Fade?
    /// Where to pick up when the engine restarts after a stop.
    var resumeFrame: AVAudioFramePosition?
    private var file: AVAudioFile?
    /// The file frame at the player's sample time 0.
    private var origin: AVAudioFramePosition = 0
    /// Bumped whenever the queue is reset, so callbacks for old segments are ignored.
    private var generation = 0
    private var queuedLoops = 0
    /// The last (player sample time, host time) read while the engine ran.
    private var lastTime: (sample: AVAudioFramePosition, host: UInt64)?

    var isIdle: Bool { file == nil }

    /// Where a track that was stopped before anyone knew where it was starts again.
    var restartFrame: AVAudioFramePosition { loop?.lowerBound ?? 0 }

    private var end: AVAudioFramePosition { loop?.upperBound ?? file?.length ?? 0 }

    func load(_ file: AVAudioFile, loop: Range<AVAudioFramePosition>?) {
        self.file = file
        self.loop = loop
        queue(from: 0)
    }

    /// Clears the player and queues the file from `frame`.
    func queue(from frame: AVAudioFramePosition) {
        generation += 1
        node.stop()
        lastTime = nil
        queuedLoops = 0
        if let loop {
            origin = loop.contains(frame) || frame < loop.lowerBound ? max(0, frame) : loop.lowerBound
        } else {
            origin = min(max(0, frame), end)
        }
        schedule(origin..<end, isLoop: false)
        topUp()
    }

    func release() {
        generation += 1
        node.stop()
        file = nil
        isPlaying = false
        fade = nil
        resumeFrame = nil
    }

    /// Records the player's time while the engine runs, so its position can
    /// be worked out after the system stops the engine.
    func noteTime() {
        guard let nodeTime = node.lastRenderTime, nodeTime.isHostTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return }
        lastTime = (playerTime.sampleTime, nodeTime.hostTime)
    }

    /// The file frame playing at `hostTime`, extrapolated from the last
    /// recorded player time.
    func frame(at hostTime: UInt64) -> AVAudioFramePosition {
        noteTime()
        guard let lastTime, let file else { return origin }
        let elapsed = max(0, AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: lastTime.host))
        let played = max(0, lastTime.sample + AVAudioFramePosition(elapsed * file.processingFormat.sampleRate))
        let intro = end - origin
        guard played >= intro else { return origin + played }
        guard let loop else { return end }
        return loop.lowerBound + (played - intro) % max(1, loop.upperBound - loop.lowerBound)
    }

    private func topUp() {
        guard file != nil, let loop, !loop.isEmpty else { return }
        while queuedLoops < Self.loopsAhead { schedule(loop, isLoop: true) }
    }

    private func schedule(_ frames: Range<AVAudioFramePosition>, isLoop: Bool) {
        guard let file, !frames.isEmpty else { return }
        if isLoop { queuedLoops += 1 }
        let generation = generation
        node.scheduleSegment(file, startingFrame: frames.lowerBound, frameCount: AVAudioFrameCount(frames.count), at: nil,
                             completionCallbackType: .dataConsumed) { @Sendable [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consumed(isLoop: isLoop, generation: generation) }
            }
        }
    }

    private func consumed(isLoop: Bool, generation: Int) {
        guard generation == self.generation, file != nil else { return }
        if isLoop { queuedLoops -= 1 }
        noteTime()
        topUp()
    }
}
#endif
