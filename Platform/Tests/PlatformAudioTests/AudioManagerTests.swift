import Foundation
import Testing
@testable import PlatformAudio

/// A clock that only moves when a test moves it.
private final class ManualClock {
    var now: TimeInterval = 0
    private var due: [(at: TimeInterval, work: () -> Void)] = []

    var clock: AudioClock {
        AudioClock(now: { [unowned self] in now }, after: { [unowned self] delay, work in due.append((now + delay, work)) })
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        while let index = due.indices.filter({ due[$0].at <= now }).min(by: { due[$0].at < due[$1].at }) {
            due.remove(at: index).work()
        }
    }
}

/// Settings kept in memory, so tests don't touch user defaults.
private final class MemorySettings {
    var values: [String: Bool] = [:]

    var settings: AudioConfiguration.Settings {
        AudioConfiguration.Settings(read: { [unowned self] in values[$0] }, write: { [unowned self] in values[$1] = $0 })
    }
}

private enum Sound: String, CaseIterable {
    case tap = "Tap"
    case step = "Step"
    case jingle = "Jingle"
}

private enum Track: String {
    case menu = "Menu"
    case play = "Play"
}

@MainActor
private struct Harness {
    let backend = RecordingAudioBackend()
    let time = ManualClock()
    let store = MemorySettings()
    let audio: AudioManager

    init(_ adjust: (inout AudioConfiguration) -> Void = { _ in }) {
        audio = AudioManager(backend: backend, clock: time.clock)
        var configuration = AudioConfiguration(
            sounds: AudioConfiguration.sounds(Sound.self) { sound in
                switch sound {
                case .step: AudioConfiguration.Sound(sound.rawValue, poolSize: 6, rateVariation: 0.9...1.1)
                case .jingle: AudioConfiguration.Sound(sound.rawValue, poolSize: 1, volume: 0.5)
                case .tap: nil
                }
            },
            poolSize: 3,
            soundVolume: 0.8,
            musicVolume: 0.4,
            duckedMusicVolume: 0.05,
            crossfadeDuration: 2,
            musicFadeDuration: 0.25,
            musicLoops: ["Play": MusicLoop(start: 100, end: 900)],
            settings: store.settings
        )
        adjust(&configuration)
        audio.configure(configuration)
    }

    var music: [RecordingAudioBackend.Call] {
        backend.calls.filter { if case .music = $0 { true } else { false } }
    }
}

@MainActor
struct SoundTests {
    @Test func soundsLoadInPoolsBySizeAndVolume() {
        let harness = Harness()
        #expect(harness.backend.calls == [
            .prepare(names: ["Tap"], poolSize: 3, volume: 0.8),
            .prepare(names: ["Step"], poolSize: 6, volume: 0.8),
            .prepare(names: ["Jingle"], poolSize: 1, volume: 0.5),
        ])
    }

    @Test func unlistedSoundsLoadOnFirstPlayWithTheDefaults() {
        let harness = Harness()
        harness.backend.clear()
        harness.audio.play("Chime")
        harness.audio.play("Chime")
        #expect(harness.backend.calls == [
            .prepare(names: ["Chime"], poolSize: 3, volume: 0.8),
            .sound(name: "Chime", rate: 1),
            .sound(name: "Chime", rate: 1),
        ])
    }

    @Test func ratesVaryOnlyWhereAsked() {
        let harness = Harness()
        harness.backend.clear()
        for _ in 0..<20 { harness.audio.play(Sound.step) }
        harness.audio.play(Sound.tap)
        let rates = harness.backend.calls.compactMap { call -> Float? in
            if case let .sound("Step", rate) = call { rate } else { nil }
        }
        #expect(rates.count == 20)
        #expect(rates.allSatisfy { (0.9...1.1).contains($0) })
        #expect(Set(rates).count > 1)
        #expect(harness.backend.calls.last == .sound(name: "Tap", rate: 1))
    }

    @Test func switchedOffSoundsAreStillReportedButNotPlayed() {
        var heard: [String] = []
        let harness = Harness { $0.onSound = { heard.append($0) } }
        harness.backend.clear()
        harness.audio.soundEnabled = false
        #expect(harness.store.values["settings.soundEnabled"] == false)
        #expect(harness.audio.play(Sound.tap) == nil)
        #expect(harness.backend.calls.isEmpty)
        #expect(heard == ["Tap"])
    }

    @Test func durationsFollowTheRateAndSkipIfPlayingWaitsForThem() {
        let harness = Harness()
        harness.backend.durations["Jingle"] = 2
        harness.backend.clear()
        #expect(harness.audio.play(Sound.jingle, skipIfPlaying: true) == 2)
        harness.time.advance(by: 1)
        #expect(harness.audio.play(Sound.jingle, skipIfPlaying: true) == nil)
        #expect(harness.audio.play(Sound.jingle) == 2)
        harness.time.advance(by: 2.5)
        #expect(harness.audio.play(Sound.jingle, skipIfPlaying: true) == 2)
        #expect(harness.backend.calls.count == 3)
    }

    @Test func variantsPickAFileAndTakeTheirSoundsOptions() {
        let harness = Harness { $0.variantName = { "\($0)-\($1)" } }
        harness.backend.clear()
        for _ in 0..<20 { harness.audio.play("Step", variants: 2) }
        let names = Set(harness.backend.calls.compactMap { call -> String? in
            if case let .sound(name, _) = call { name } else { nil }
        })
        #expect(names == ["Step-1", "Step-2"])
        #expect(harness.backend.calls.contains(.prepare(names: ["Step-1"], poolSize: 6, volume: 0.8)))
    }
}

@MainActor
struct EffectTests {
    @Test func oneShotsFinishAfterTheirDuration() {
        let harness = Harness()
        harness.backend.durations["Tap"] = 0.5
        var finished = 0
        let id = harness.audio.playEffect("Tap") { finished += 1 }
        #expect(id != nil)
        harness.time.advance(by: 0.4)
        #expect(finished == 0)
        harness.time.advance(by: 0.2)
        #expect(finished == 1)
        // Stopping one that has finished does nothing.
        harness.backend.clear()
        harness.audio.stopEffect(id ?? 0)
        #expect(harness.backend.calls.isEmpty)
    }

    @Test func stoppedEffectsFadeAndNeverFinish() {
        let harness = Harness()
        harness.backend.durations["Tap"] = 1
        var finished = false
        let id = harness.audio.playEffect("Tap") { finished = true }
        harness.audio.stopEffect(id ?? 0, fadeDuration: 0.3)
        harness.time.advance(by: 2)
        #expect(!finished)
        #expect(harness.backend.calls.suffix(2) == [
            .voice(name: "Tap", rate: 1, looping: false),
            .stop(AudioVoice(id: 1), fade: 0.3),
        ])
    }

    @Test func loopingEffectsStopTogetherAndWhenSoundGoesOff() {
        let harness = Harness()
        let first = harness.audio.playEffect("Tap", repeats: true)
        harness.audio.playEffect("Step", repeats: true)
        harness.audio.playEffect("Jingle")
        harness.audio.stopLoopingEffects()
        #expect(harness.backend.calls.suffix(2) == [.stop(AudioVoice(id: 1), fade: 0), .stop(AudioVoice(id: 2), fade: 0)])
        harness.audio.playEffect("Tap", repeats: true)
        harness.backend.clear()
        harness.audio.soundEnabled = false
        #expect(harness.backend.calls == [.stop(AudioVoice(id: 4), fade: 0)])
        #expect(harness.audio.playEffect("Tap") == nil)
        #expect(first == 1)
    }
}

@MainActor
struct MusicTests {
    @Test func tracksCrossfadeAndRepeatingOneKeepsItGoing() {
        let harness = Harness()
        harness.audio.playMusic(Track.menu)
        harness.audio.playMusic(Track.menu)
        harness.audio.playMusic(Track.play)
        harness.audio.playMusic(nil as Track?)
        #expect(harness.music == [
            .music(track: "Menu", loop: .wholeTrack, volume: 0.4, fade: 2),
            .music(track: "Play", loop: MusicLoop(start: 100, end: 900), volume: 0.4, fade: 2),
            .music(track: nil, loop: nil, volume: 0.4, fade: 2),
        ])
    }

    @Test func aTrackThatDoesNotLoopPlaysOnce() {
        let harness = Harness()
        harness.audio.playMusic("Menu", loop: false)
        #expect(harness.backend.track == "Menu")
        #expect(harness.music.last == .music(track: "Menu", loop: nil, volume: 0.4, fade: 2))
    }

    @Test func switchingMusicOffAndOnFadesAndRemembersTheTrack() {
        let harness = Harness()
        harness.audio.playMusic(Track.menu)
        harness.audio.musicEnabled = false
        harness.audio.playMusic(Track.play)
        #expect(harness.backend.track == nil)
        harness.audio.musicEnabled = true
        #expect(harness.music.suffix(2) == [
            .music(track: nil, loop: nil, volume: 0.4, fade: 0.25),
            .music(track: "Play", loop: MusicLoop(start: 100, end: 900), volume: 0.4, fade: 0.25),
        ])
    }

    @Test func anotherDevicesSwitchIsFollowed() {
        let harness = Harness()
        harness.audio.playMusic(Track.menu)
        harness.store.values["settings.musicEnabled"] = false
        harness.audio.savedDataDidSync(["settings.musicEnabled"])
        #expect(harness.backend.track == nil)
    }

    @Test func pauseAndResumeKeepTheTrack() {
        let harness = Harness()
        harness.audio.playMusic(Track.menu)
        harness.audio.pauseMusic()
        #expect(harness.backend.track == nil)
        harness.audio.resumeMusic()
        #expect(harness.backend.track == "Menu")
        harness.audio.stopMusic()
        harness.audio.resumeMusic()
        #expect(harness.backend.track == nil)
    }

    @Test func jinglesDuckTheMusicUntilJustBeforeTheyEnd() {
        let harness = Harness()
        harness.audio.playMusic(Track.menu)
        harness.audio.duckMusicForJingle()
        harness.audio.restoreMusicAfterJingle(duration: 3)
        harness.time.advance(by: 1.9)
        #expect(harness.music.last == .music(track: "Menu", loop: .wholeTrack, volume: 0.05, fade: 0.25))
        harness.time.advance(by: 0.2)
        #expect(harness.music.last == .music(track: "Menu", loop: .wholeTrack, volume: 0.4, fade: 0.25))
    }

    @Test func aLaterJingleKeepsTheMusicDucked() {
        let harness = Harness()
        harness.audio.playMusic(Track.menu)
        harness.audio.duckMusicForJingle()
        harness.audio.restoreMusicAfterJingle(duration: 1)
        harness.audio.duckMusicForJingle()
        harness.time.advance(by: 1)
        #expect(harness.music.last?.volume == 0.05)
        harness.audio.restoreMusicAfterJingle(duration: 1)
        harness.time.advance(by: 0)
        #expect(harness.music.last?.volume == 0.4)
    }

    @Test func interruptionsSuspendAndResumeWithoutTouchingTheTrack() {
        let harness = Harness()
        harness.audio.playMusic(Track.menu)
        harness.audio.audioFocusDidChange(interrupted: true)
        #expect(harness.backend.track == "Menu")
        harness.audio.audioFocusDidChange(interrupted: true)
        harness.audio.audioFocusDidChange(interrupted: false)
        #expect(harness.backend.track == "Menu")
        #expect(harness.backend.calls.filter { $0 == .suspend || $0 == .resume } == [.suspend, .resume])
    }

    @Test func theMusicSwitchIsPostedWhenItChanges() {
        let harness = Harness()
        var posts = 0
        let observer = NotificationCenter.default.addObserver(forName: AudioManager.musicEnabledDidChange, object: harness.audio, queue: nil) { _ in
            posts += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        harness.audio.musicEnabled = false
        harness.audio.savedDataDidSync([harness.audio.configuration.settings.soundKey])
        harness.audio.savedDataDidSync([harness.audio.configuration.settings.musicKey])
        #expect(posts == 2)
        // A new configuration may read the switch under another key.
        harness.audio.configure(harness.audio.configuration)
        #expect(posts == 3)
    }

    @Test func aNewBackendGetsTheSoundsAndTheTrack() {
        let harness = Harness()
        harness.audio.play("Chime")
        harness.audio.playMusic(Track.play)
        let shell = RecordingAudioBackend()
        harness.audio.use(shell)
        #expect(shell.calls == [
            .prepare(names: ["Tap", "Chime"], poolSize: 3, volume: 0.8),
            .prepare(names: ["Step"], poolSize: 6, volume: 0.8),
            .prepare(names: ["Jingle"], poolSize: 1, volume: 0.5),
            .music(track: "Play", loop: MusicLoop(start: 100, end: 900), volume: 0.4, fade: 0),
        ])
    }

    @Test func variantsOfATrackTakeItsLoop() {
        let harness = Harness { $0.musicLoops = ["Play": MusicLoop(start: 1, end: 2)] }
        harness.audio.playMusic("Play", variants: 1)
        #expect(harness.music.last == .music(track: "Play 1", loop: MusicLoop(start: 1, end: 2), volume: 0.4, fade: 2))
    }
}

private extension RecordingAudioBackend.Call {
    var volume: Float? {
        if case let .music(_, _, volume, _) = self { volume } else { nil }
    }
}

@MainActor
@Suite(.serialized)
struct ShortcutTests {
    @Test func shortcutsPlayOnTheSharedManagerWhileTheirSettingIsOn() {
        let store = MemorySettings()
        let backend = RecordingAudioBackend()
        AudioManager.configure(AudioConfiguration(sounds: AudioConfiguration.sounds(Sound.self), settings: store.settings))
        AudioManager.shared.use(backend)
        backend.clear()

        playSound(Sound.tap)
        playSound("Step")
        playMusic(Track.menu)
        #expect(backend.calls.contains(.sound(name: "Tap", rate: 1)))
        #expect(backend.calls.contains(.sound(name: "Step", rate: 1)))
        #expect(backend.track == "Menu")

        backend.clear()
        AudioManager.isSoundEnabled = false
        #expect(playSound(Sound.tap) == nil)
        #expect(!backend.calls.contains { if case .sound = $0 { true } else { false } })
        stopMusic()
        #expect(backend.track == nil)

        AudioManager.shared.use(NullAudioBackend())
        AudioManager.configure(AudioConfiguration(sounds: [], settings: .init(read: { _ in nil }, write: { _, _ in })))
    }
}
