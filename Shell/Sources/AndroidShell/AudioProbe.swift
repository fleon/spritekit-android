import Foundation
import PlatformShim
import ShellCore

/// `-AudioProbe`: plays the soundtrack and the sound effects on a schedule
/// and says in logcat what it did, so audio on a device can be checked
/// without the game above it.
///
/// It is here rather than in a scratch branch because it is the Android
/// stand-in for what `-AutoSolve` and friends do on Apple: the port has no
/// menus yet, so there is otherwise no way to ask for a track. Arguments
/// reach `ShellArguments` through `MainActivity.getArguments()`:
///
///     adb shell am start -n com.fleon.switchlings/.MainActivity \
///         --esa args "-AudioProbe"
///
/// What it proves, in order: a track starts and loops; sounds overlap and
/// vary their pitch; one track crossfades into another; the soundtrack fades
/// out and the decoders are released.
final class AudioProbe {
    /// Sounds the game plays most, and the two that overlap each other.
    private static let sounds = ["Tap", "Step", "Bump", "Home", "Win"]
    private static let volume: Float = 0.8
    private static let fade: TimeInterval = 1.5

    /// Each step: when it happens, and what it does.
    private struct Step {
        let at: TimeInterval
        let what: String
        let run: (AudioBackend) -> Void
    }

    private let audio: AudioBackend
    private var steps: [Step]
    private var start: TimeInterval?

    init?(audio: AudioBackend) {
        guard ShellArguments.has("-AudioProbe") else { return nil }
        self.audio = audio
        audio.prepareSounds(Self.sounds, poolSize: 4, volume: Self.volume)
        // Sunny Garden's loop starts 32 s in, so the probe sits past it: the
        // track it hears at 40 s is the loop, not the intro.
        // The loop check comes first and is over inside fifteen seconds:
        // a probe run shares a device with whatever else is on it, and the
        // frame loop — and so this schedule — stops while the app is in the
        // background.
        steps = [
            // The real loops are two minutes long, which is no use as a
            // check. A made-up five-second one exercises the same path —
            // decode to the end point, seek back to the start, carry on —
            // and says in the log where each wrap landed.
            Step(at: 0, what: "play MusicReef on a 5 s test loop") { audio in
                audio.playMusic("MusicReef", loop: MusicLoop(start: 2 * 48_000, end: 7 * 48_000),
                                volume: Self.volume, over: Self.fade)
            },
            Step(at: 14, what: "crossfade to MusicGarden, on its real loop") { audio in
                audio.playMusic("MusicGarden", loop: MusicLoop(start: 1_541_232, end: 6_503_587),
                                volume: Self.volume, over: Self.fade)
            },
            Step(at: 17, what: "sound Tap") { $0.play(sound: "Tap", rate: 1) },
            Step(at: 17.3, what: "sound Step") { $0.play(sound: "Step", rate: 0.95) },
            Step(at: 17.5, what: "sound Step (higher)") { $0.play(sound: "Step", rate: 1.08) },
            Step(at: 17.7, what: "sound Bump") { $0.play(sound: "Bump", rate: 1) },
            Step(at: 18.0, what: "sounds Home and Win together") { audio in
                audio.play(sound: "Home", rate: 1)
                audio.play(sound: "Win", rate: 1)
            },
            Step(at: 24, what: "crossfade to MusicMainframe") { audio in
                audio.playMusic("MusicMainframe", loop: MusicLoop(start: 1_484_928, end: 8_040_836),
                                volume: Self.volume, over: Self.fade)
            },
            Step(at: 32, what: "fade the soundtrack out") { $0.playMusic(nil, loop: nil, volume: 0, over: Self.fade) },
            Step(at: 36, what: "done") { _ in },
        ]
        Log.info("audio probe: \(steps.count) steps over \(Int(steps.last?.at ?? 0)) s")
    }

    /// Runs whatever is due. Called once a frame, so a step is at most a
    /// frame late.
    func tick(at now: TimeInterval) {
        let start = start ?? now
        self.start = start
        let elapsed = now - start
        while let next = steps.first, next.at <= elapsed {
            steps.removeFirst()
            Log.info("audio probe \(String(format: "%6.2f", elapsed))s: \(next.what)")
            next.run(audio)
        }
    }
}
