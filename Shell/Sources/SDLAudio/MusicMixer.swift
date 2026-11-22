import CAndroidShell
import CAndroidAudio
import Foundation
import PlatformServices
import PlatformShim
import ShellCore

/// The soundtrack: one or two tracks decoded and mixed on a thread of their
/// own, with sample-accurate gain ramps, into a single stream.
///
/// Why mix rather than lean on SDL's per-stream gain: a crossfade stepped at
/// 60 Hz from the main thread (which is what AVFoundation gets on Apple, and
/// what the game's `musicFadeDuration` assumes) is fine when the ramp is
/// applied inside the audio engine. Applied from outside it is a staircase,
/// audible as zipper noise on a long fade. Ramping per sample here costs a
/// multiply and is exact.
///
/// ## Which thread owns what
///
/// Three threads touch this, and each owns a different thing:
///
///  - **The game's thread** calls `play`. All it does is leave a command and
///    say which track is wanted now.
///  - **The opener** builds decoders. Opening one reads the APK and starts a
///    MediaCodec, which measured about 300 ms on the emulator — far too long
///    for the frame loop and too long for the mixer, which would underrun.
///    So it happens here, and the finished deck arrives as another command.
///  - **The mixer** is the only thread that ever touches a `Deck`. It takes
///    the commands at a block boundary and then has the decks to itself, so
///    there is no lock in the sample loop and no race on a gain ramp.
final class MusicMixer {
    /// Frames produced in one go. At 48 kHz that is 85 ms of audio, which is
    /// several decoder buffers and still a short sleep.
    private static let blockFrames = 4096
    /// Keep roughly this much audio queued ahead. Enough to ride out a
    /// scheduling hiccup on a loaded device, short enough that a crossfade
    /// asked for now is heard now.
    private static let queueTarget: TimeInterval = 0.25
    private static let idleSleepMilliseconds: UInt32 = 10
    private static let channels = 2

    /// What the other two threads ask the mixer to do.
    private enum Command {
        /// Take this deck on, fading it up.
        case add(Deck, volume: Float, fade: TimeInterval)
        /// Fade everything playing out.
        case fadeOutAll(fade: TimeInterval)
        /// Make sure the named track is heading for this volume (the game
        /// asked for the track that is already playing).
        case retarget(name: String, volume: Float, fade: TimeInterval)
    }

    /// One track being played or faded out. Only the mixer thread touches
    /// one once it has been handed over.
    private final class Deck {
        let name: String
        let decoder: OpaquePointer
        let rate: Int32
        let sourceChannels: Int32
        /// Where the decoder is in the track, in frames, and where it repeats.
        var cursor: MusicLoopCursor
        var gain: Float = 0
        var target: Float = 0
        /// Frames left in the ramp from `gain` to `target`.
        var rampFrames: Int = 0
        var rampStep: Float = 0
        /// Faded out and done: the mixer drops it.
        var isSpent: Bool { target == 0 && gain <= 0 }
        /// The loudest sample seen so far, and whether that has been said
        /// once. A decoder that returns buffers of zeroes looks exactly like
        /// one that works, right up to the silence, so the first block's
        /// peak goes in the log.
        var peak: Int16 = 0
        var hasReportedPeak = false

        init(name: String, decoder: OpaquePointer, rate: Int32, sourceChannels: Int32, loop: MusicLoop?) {
            self.name = name
            self.decoder = decoder
            self.rate = rate
            self.sourceChannels = sourceChannels
            cursor = MusicLoopCursor(loop: loop)
        }

        func milliseconds(_ frame: Int64) -> Int64 {
            frame * 1000 / Int64(rate)
        }

        func fade(to target: Float, over seconds: TimeInterval) {
            self.target = target
            let frames = max(1, Int(seconds * TimeInterval(rate)))
            rampFrames = frames
            rampStep = (target - gain) / Float(frames)
        }
    }

    private let stream: OpaquePointer
    private let deviceRate: Int32
    /// What the game's thread and the mixer's share, under a lock.
    private struct Shared {
        var commands: [Command] = []
        /// The track asked for last, so asking again is ignored rather than
        /// restarting it, and so a decoder that finished opening after a newer
        /// request can be thrown away.
        var current: String?
        var isStopping = false
        var hasStopped = false
    }

    private let shared = Locked(Shared())
    /// Signalled once the mixer thread has let go of its stream and decks.
    private let finished = DispatchSemaphore(value: 0)

    /// Mixer-thread state.
    private var decks: [Deck] = []
    private var mix: [Int32]
    private var out: [Int16]
    private var scratch: [Int16]

    private let opener = DispatchQueue(label: "spritekit.music-open", qos: .userInitiated)

    init?(device: SDL_AudioDeviceID, rate: Int32) {
        deviceRate = rate
        var source = SDL_AudioSpec(format: SKA_AUDIO_FORMAT, channels: Int32(Self.channels), freq: rate)
        var destination = source
        guard let stream = SDL_CreateAudioStream(&source, &destination) else { return nil }
        self.stream = stream
        SDL_BindAudioStream(device, stream)
        mix = [Int32](repeating: 0, count: Self.blockFrames * Self.channels)
        out = [Int16](repeating: 0, count: Self.blockFrames * Self.channels)
        scratch = [Int16](repeating: 0, count: Self.blockFrames * Self.channels)

        // Held strongly: `stop()` waits for this thread, so it must run even
        // if the mixer's last other reference goes before it starts (it
        // holds the mixer while it runs either way).
        let thread = Thread { self.run() }
        thread.name = "spritekit.music"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    deinit {
        stop()
    }

    /// Stops the mixer and waits for it: once this returns, no thread of the
    /// soundtrack touches SDL again, so the device can close and SDL can
    /// quit. A track still being opened is waited for and closed too.
    func stop() {
        let alreadyStopped = shared.withLock { shared in
            shared.isStopping = true
            defer { shared.hasStopped = true }
            return shared.hasStopped
        }
        guard !alreadyStopped else { return }
        opener.sync {}
        finished.wait()
    }

    /// Crossfades to `track` (nil fades the soundtrack out). Asking for the
    /// track already playing keeps it going. Returns at once: nothing here
    /// opens a file or waits on the mixer.
    func play(_ track: String?, loop: MusicLoop?, volume: Float, over fade: TimeInterval) {
        let isCurrent = shared.withLock { shared in
            if track == shared.current {
                if let track { shared.commands.append(.retarget(name: track, volume: volume, fade: fade)) }
                return true
            }
            shared.current = track
            shared.commands.append(.fadeOutAll(fade: fade))
            return false
        }
        guard !isCurrent else { return }

        guard let track else { return }
        opener.async { [weak self] in
            guard let self, let deck = self.open(track, loop: loop) else {
                if track != nil { Log.error("no soundtrack \(track) in the APK") }
                return
            }
            // Another call may have overtaken this one while the file opened.
            let wanted = self.shared.withLock { shared in
                let wanted = shared.current == track && !shared.isStopping
                if wanted { shared.commands.append(.add(deck, volume: volume, fade: fade)) }
                return wanted
            }
            if !wanted { ska_audio_close(deck.decoder) }
        }
    }

    private func open(_ track: String, loop: MusicLoop?) -> Deck? {
        guard let decoder = ska_audio_open_asset(AudioAssets.music(track)) else { return nil }
        let rate = ska_audio_sample_rate(decoder)
        let channels = ska_audio_channels(decoder)
        guard rate > 0, channels > 0 else {
            ska_audio_close(decoder)
            return nil
        }
        let deck = Deck(name: track, decoder: decoder, rate: rate, sourceChannels: channels, loop: loop)
        let loops = deck.cursor.loop.map { "frames \($0.start)–\($0.end) (\(deck.milliseconds($0.start))–\(deck.milliseconds($0.end)) ms)" }
        Log.info("soundtrack \(track): \(rate) Hz, \(channels) ch, loops \(loops ?? "never")")
        return deck
    }

    // MARK: - The mixer thread

    private func run() {
        while true {
            let (stopping, due) = shared.withLock { shared in
                defer { shared.commands.removeAll() }
                return (shared.isStopping, shared.commands)
            }
            if stopping { break }
            for command in due { apply(command) }

            let queuedBytes = SDL_GetAudioStreamQueued(stream)
            let queuedFrames = Int(queuedBytes) / (Self.channels * MemoryLayout<Int16>.size)
            if queuedFrames >= Int(Self.queueTarget * TimeInterval(deviceRate)) || !produceBlock() {
                SDL_Delay(Self.idleSleepMilliseconds)
            }
        }
        for deck in decks { ska_audio_close(deck.decoder) }
        decks = []
        SDL_DestroyAudioStream(stream)
        finished.signal()
    }

    private func apply(_ command: Command) {
        switch command {
        case let .add(deck, volume, fade):
            deck.fade(to: volume, over: fade)
            decks.append(deck)
        case let .fadeOutAll(fade):
            for deck in decks { deck.fade(to: 0, over: fade) }
        case let .retarget(name, volume, fade):
            for deck in decks where deck.name == name && deck.target != volume {
                deck.fade(to: volume, over: fade)
            }
        }
    }

    /// Mixes one block of every deck into the stream. Returns whether
    /// anything was pushed.
    private func produceBlock() -> Bool {
        guard !decks.isEmpty else { return false }
        for index in mix.indices { mix[index] = 0 }
        for deck in decks { fill(deck) }

        for deck in decks where deck.isSpent {
            Log.info("soundtrack \(deck.name) faded out")
            ska_audio_close(deck.decoder)
        }
        decks.removeAll(where: \.isSpent)

        for index in out.indices {
            out[index] = Int16(mix[index].clamped(to: Int32(Int16.min)...Int32(Int16.max)))
        }
        return out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return SDL_PutAudioStreamData(stream, base, Int32(raw.count))
        }
    }

    /// Decodes one block of `deck`, going back to the loop's start each time
    /// it reaches the loop's end, applies its gain ramp and adds it to the mix.
    private func fill(_ deck: Deck) {
        // Filled from a copy: reading adds to the mix, which reads the deck.
        var cursor = deck.cursor
        let produced = cursor.fill(Self.blockFrames, read: { offset, count in
            let got = scratch.withUnsafeMutableBufferPointer { buffer -> Int64 in
                guard let base = buffer.baseAddress else { return 0 }
                return ska_audio_read(deck.decoder, base, Int64(count), nil)
            }
            if got > 0 { add(deck, frames: Int(got), at: offset) }
            return Int(got)
        }, seek: { frame in
            ska_audio_seek_frame(deck.decoder, frame)
        })
        let looped = cursor.loops != deck.cursor.loops
        deck.cursor = cursor
        if looped, let loop = cursor.loop {
            Log.info("soundtrack \(deck.name): loop \(cursor.loops), back to frame \(loop.start) (\(deck.milliseconds(loop.start)) ms)")
        }
        // Nothing decoded at all: let the ramp run on so a dead track still
        // fades out of the mix instead of sticking at full gain for ever.
        if produced == 0 { advance(deck, frames: Self.blockFrames) }
    }

    /// Adds `frames` of the deck's scratch into the mix at `offset`, walking
    /// its gain ramp a sample at a time.
    private func add(_ deck: Deck, frames: Int, at offset: Int) {
        let sourceChannels = Int(deck.sourceChannels)
        if !deck.hasReportedPeak { notePeak(deck, frames: frames) }
        for frame in 0..<frames {
            let gain = step(deck)
            let source = frame * sourceChannels
            let left = Float(scratch[source])
            let right = sourceChannels > 1 ? Float(scratch[source + 1]) : left
            let target = (offset + frame) * Self.channels
            mix[target] += Int32(left * gain)
            mix[target + 1] += Int32(right * gain)
        }
    }

    private func notePeak(_ deck: Deck, frames: Int) {
        for index in 0..<(frames * Int(deck.sourceChannels)) {
            let sample = scratch[index]
            let magnitude = sample == Int16.min ? Int16.max : abs(sample)
            if magnitude > deck.peak { deck.peak = magnitude }
        }
        deck.hasReportedPeak = true
        let decibels = deck.peak == 0 ? -Float.infinity : 20 * log10f(Float(deck.peak) / Float(Int16.max))
        Log.info("soundtrack \(deck.name): decoded, peak \(deck.peak) (\(String(format: "%.1f", decibels)) dBFS)")
    }

    private func advance(_ deck: Deck, frames: Int) {
        for _ in 0..<frames { _ = step(deck) }
    }

    /// One frame of the ramp.
    private func step(_ deck: Deck) -> Float {
        if deck.rampFrames > 0 {
            deck.rampFrames -= 1
            deck.gain += deck.rampStep
            if deck.rampFrames == 0 { deck.gain = deck.target }
        }
        return max(0, deck.gain)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
