import Foundation

/// Where a track repeats, in frames at the file's own sample rate.
///
/// The numbers are the game's own, made beside the files themselves: a
/// track plays from its first frame once, then repeats `start ..< end` for
/// ever. When the frames before `end` already crossfade into the frames
/// before `start`, a backend that lands a few
/// milliseconds either side of the seam is inaudible rather than a click —
/// which is what makes a decoder without sample-exact priming compensation
/// honest here.
public struct MusicLoop: Equatable, Sendable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    /// The whole file, again and again: what `AVAudioPlayer`'s
    /// `numberOfLoops = -1` does for a track with no loop points. Its end is past any file's (a day at 192 kHz), so the
    /// mixer reaches the file's own end first and goes back to its start.
    public static let wholeTrack = MusicLoop(start: 0, end: 192_000 * 86_400)
}

/// What a game's audio code stands on once it is off AVFoundation.
///
/// The split is deliberate: every decision about *what* should be heard —
/// whether music is switched on, which track belongs to the screen in
/// front, whether the app is in the background — stays in the game,
/// unchanged from the Apple build. A backend only does as it is told, so the
/// one on a device (SDL3, in `Shell/Sources/SDLAudio`) and the one in a test
/// (`RecordingAudioBackend`) are interchangeable.
///
/// Every call arrives on the main thread.
public protocol AudioBackend: AnyObject {
    /// Loads each sound and keeps `poolSize` voices of it, so quick repeats
    /// overlap instead of cutting one another off. Names are resource names
    /// without an extension.
    func prepareSounds(_ names: [String], poolSize: Int, volume: Float)

    /// Plays one sound. `rate` is 1 as recorded; a game may vary it a
    /// little so repeats don't sound alike.
    func play(sound name: String, rate: Float)

    /// Crossfades to `track`, or fades the soundtrack out for nil. Asking for
    /// the track already playing must keep it going rather than restart it.
    func playMusic(_ track: String?, loop: MusicLoop?, volume: Float, over fade: TimeInterval)

    /// The app went away: silence the hardware but remember where the track is.
    func suspend()

    /// The app came back: pick the track up where `suspend()` left it.
    func resume()

    /// How long a prepared sound plays, as `AVAudioPlayer.duration` tells a
    /// game that times something to it; nil for a sound not prepared.
    func duration(ofSound name: String) -> TimeInterval?

    /// Plays one sound on a voice of its own that `stop(_:over:)` can
    /// silence, repeating it for ever when `looping`. Nil when the backend
    /// can't hand one out; it then plays the sound once, as `play(sound:rate:)`.
    func play(sound name: String, rate: Float, looping: Bool) -> AudioVoice?

    /// Fades a voice from `play(sound:rate:looping:)` out and lets it go.
    func stop(_ voice: AudioVoice, over fade: TimeInterval)
}

/// A sound playing on a voice of its own, to stop later.
public struct AudioVoice: Hashable, Sendable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}

public extension AudioBackend {
    func duration(ofSound name: String) -> TimeInterval? { nil }

    func play(sound name: String, rate: Float, looping: Bool) -> AudioVoice? {
        play(sound: name, rate: rate)
        return nil
    }

    func stop(_ voice: AudioVoice, over fade: TimeInterval) {}
}

/// A backend that hears everything and does nothing: what the game runs on
/// before one is installed, so no caller has to check for nil.
public final class NullAudioBackend: AudioBackend {
    public init() {}

    public func prepareSounds(_ names: [String], poolSize: Int, volume: Float) {}
    public func play(sound name: String, rate: Float) {}
    public func playMusic(_ track: String?, loop: MusicLoop?, volume: Float, over fade: TimeInterval) {}
    public func suspend() {}
    public func resume() {}
}

/// Notes every call instead of making a sound, so the policy above it can be
/// tested on the host.
public final class RecordingAudioBackend: AudioBackend {
    public enum Call: Equatable, Sendable {
        case prepare(names: [String], poolSize: Int, volume: Float)
        case sound(name: String, rate: Float)
        case music(track: String?, loop: MusicLoop?, volume: Float, fade: TimeInterval)
        case voice(name: String, rate: Float, looping: Bool)
        case stop(AudioVoice, fade: TimeInterval)
        case suspend
        case resume
    }

    public private(set) var calls: [Call] = []
    /// How long each sound plays, for a test that times something to one.
    public var durations: [String: TimeInterval] = [:]
    private var voices = 0

    public init() {}

    /// The track last asked for, after every call so far.
    public var track: String? {
        for call in calls.reversed() {
            if case let .music(track, _, _, _) = call { return track }
        }
        return nil
    }

    public func clear() { calls.removeAll() }

    public func prepareSounds(_ names: [String], poolSize: Int, volume: Float) {
        calls.append(.prepare(names: names, poolSize: poolSize, volume: volume))
    }

    public func play(sound name: String, rate: Float) {
        calls.append(.sound(name: name, rate: rate))
    }

    public func playMusic(_ track: String?, loop: MusicLoop?, volume: Float, over fade: TimeInterval) {
        calls.append(.music(track: track, loop: loop, volume: volume, fade: fade))
    }

    public func duration(ofSound name: String) -> TimeInterval? {
        durations[name]
    }

    public func play(sound name: String, rate: Float, looping: Bool) -> AudioVoice? {
        calls.append(.voice(name: name, rate: rate, looping: looping))
        voices += 1
        return AudioVoice(id: voices)
    }

    public func stop(_ voice: AudioVoice, over fade: TimeInterval) {
        calls.append(.stop(voice, fade: fade))
    }

    public func suspend() { calls.append(.suspend) }
    public func resume() { calls.append(.resume) }
}
