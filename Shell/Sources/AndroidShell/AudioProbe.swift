import Foundation
import PlatformShim
import ShellCore

/// `-AudioProbe`: plays music tracks and sound effects on a schedule and
/// says in logcat what it did, so audio on a device can be checked without
/// the game above it.
///
/// It is the Android stand-in for driving a game's audio from its own
/// launch arguments on Apple: a game ported before its menus work has
/// otherwise no way to ask for a track. Arguments reach `ShellArguments`
/// through `MainActivity.getArguments()`; the tracks and sounds are the
/// game's own, named with `;` between them (`--esa` splits on commas), a
/// track optionally with its loop in frames:
///
///     adb shell am start -n <package>/.MainActivity --esa args \
///         "-AudioProbe,-AudioProbeMusic,MusicA;MusicB@96000-480000;MusicC,-AudioProbeSounds,Tap;Step;Bump;Home;Win"
///
/// What it proves, in order: a track starts and loops; sounds overlap and
/// vary their pitch; one track crossfades into another; the soundtrack fades
/// out and the decoders are released. Steps whose track or sound isn't named
/// are left out.
final class AudioProbe {
    private static let volume: Float = 0.8
    private static let fade: TimeInterval = 1.5

    /// Each step: when it happens, and what it does.
    private struct Step {
        let at: TimeInterval
        let what: String
        let run: (AudioBackend) -> Void
    }

    /// A track to play, and its loop if one was given.
    private struct Track {
        let name: String
        let loop: MusicLoop?

        /// `name` or `name@start-end`, the loop in frames.
        init(_ text: Substring) {
            let parts = text.split(separator: "@", maxSplits: 1)
            name = String(parts.first ?? "")
            let bounds = parts.count > 1 ? parts[1].split(separator: "-").compactMap { Int64($0) } : []
            loop = bounds.count == 2 ? MusicLoop(start: bounds[0], end: bounds[1]) : nil
        }
    }

    private let audio: AudioBackend
    private var steps: [Step]
    private var start: TimeInterval?

    init?(audio: AudioBackend) {
        guard ShellArguments.has("-AudioProbe") else { return nil }
        self.audio = audio
        let tracks = Self.list("-AudioProbeMusic").map(Track.init).filter { !$0.name.isEmpty }
        let sounds = Self.list("-AudioProbeSounds").map(String.init)
        if !sounds.isEmpty {
            audio.prepareSounds(sounds, poolSize: 4, volume: Self.volume)
        }
        // The loop check comes first and is over inside fifteen seconds:
        // a probe run shares a device with whatever else is on it, and the
        // frame loop — and so this schedule — stops while the app is in the
        // background.
        var steps: [Step] = []
        if let first = tracks.first {
            // A real loop is usually minutes long, which is no use as a
            // check. A made-up five-second one exercises the same path —
            // decode to the end point, seek back to the start, carry on —
            // and says in the log where each wrap landed.
            steps.append(Step(at: 0, what: "play \(first.name) on a 5 s test loop") { audio in
                audio.playMusic(first.name, loop: MusicLoop(start: 2 * 48_000, end: 7 * 48_000),
                                volume: Self.volume, over: Self.fade)
            })
        }
        if tracks.count > 1 {
            let second = tracks[1]
            steps.append(Step(at: 14, what: "crossfade to \(second.name)\(second.loop == nil ? "" : ", on its loop")") { audio in
                audio.playMusic(second.name, loop: second.loop, volume: Self.volume, over: Self.fade)
            })
        }
        // The first sound once, the second twice at two pitches, the third
        // once, and the rest together.
        let plays: [(at: TimeInterval, sound: Int, rate: Float)] = [(17, 0, 1), (17.3, 1, 0.95), (17.5, 1, 1.08), (17.7, 2, 1)]
        for play in plays where sounds.indices.contains(play.sound) {
            let sound = sounds[play.sound]
            steps.append(Step(at: play.at, what: "sound \(sound)\(play.rate == 1 ? "" : " at \(play.rate)")") {
                $0.play(sound: sound, rate: play.rate)
            })
        }
        if sounds.count > 3 {
            let together = Array(sounds[3...])
            steps.append(Step(at: 18, what: "sounds \(together.joined(separator: " and ")) together") { audio in
                for sound in together { audio.play(sound: sound, rate: 1) }
            })
        }
        if tracks.count > 2 {
            let third = tracks[2]
            steps.append(Step(at: 24, what: "crossfade to \(third.name)\(third.loop == nil ? "" : ", on its loop")") { audio in
                audio.playMusic(third.name, loop: third.loop, volume: Self.volume, over: Self.fade)
            })
        }
        steps.append(Step(at: 32, what: "fade the soundtrack out") { $0.playMusic(nil, loop: nil, volume: 0, over: Self.fade) })
        steps.append(Step(at: 36, what: "done") { _ in })
        self.steps = steps
        Log.info("audio probe: \(tracks.count) tracks, \(sounds.count) sounds, \(steps.count) steps over \(Int(steps.last?.at ?? 0)) s")
    }

    /// The `;`-separated values after `name`.
    private static func list(_ name: String) -> [Substring] {
        (ShellArguments.value(after: name) ?? "").split(separator: ";")
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
