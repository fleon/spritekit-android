import Foundation
import PlatformShim

/// `Source/Utils/AudioManager.swift` on Android.
///
/// Every decision this class makes is the Apple file's, unchanged: which
/// sounds exist, which track belongs to which world, that music waits while
/// the app is away, that the switches are synced settings read from user
/// defaults. What has gone is AVFoundation — the session, the engine, the
/// player nodes, the fade timer and the frame-accurate deck bookkeeping —
/// and in its place is one call into `AudioBackend`, which on a device is
/// SDL3 plus Android's own MediaCodec (`Android/Shell/Sources/SDLAudio`).
///
/// The public surface is the same name for name, so the 50-odd call sites —
/// `playSound(.bump)`, `playMusic(world.theme.music)`,
/// `AudioManager.isMusicEnabled` — are untouched.
///
/// Two differences, both deliberate and both invisible to a caller:
///
///  - **Crossfades happen inside the mixer**, a sample at a time, rather
///    than on a 60 Hz timer stepping a player node's volume. The game asks
///    for the same `DesignSystem.musicFadeDuration`; it simply gets a
///    cleaner ramp.
///  - **There is no "another app is playing music" hint.** iOS has
///    `secondaryAudioShouldBeSilencedHint`; Android's audio focus is a Java
///    API SDL does not surface, so the soundtrack does not step aside yet.
///    `updateMusic()` is where it would go.
final class AudioManager {
    enum Sound: String, CaseIterable {
        case tap = "Tap"
        case step = "Step"
        case ledge = "Ledge"
        case swap = "Swap"
        case bump = "Bump"
        case bonk = "Bonk"
        case hedge = "Hedge"
        case nope = "Nope"
        case home = "Home"
        case whoosh = "Whoosh"
        case warp = "Warp"
        case boing = "Boing"
        case crumble = "Crumble"
        case door = "Door"
        case unlock = "Unlock"
        case wake = "Wake"
        case seal = "Seal"
        case undo = "Undo"
        case win = "Win"

        /// Footsteps vary their pitch slightly, like the prototype's random step.
        var rateVariation: ClosedRange<Float>? {
            self == .step || self == .ledge ? DesignSystem.stepRateVariation : nil
        }
    }

    /// Soundtrack loops, converted from the OST masters by `npm run music`.
    enum Music: String {
        case title = "MusicTitle"
        case garden = "MusicGarden"
        case farm = "MusicFarm"
        case toys = "MusicToys"
        case meadow = "MusicMeadow"
        case reef = "MusicReef"
        case kitchen = "MusicKitchen"
        case ruins = "MusicRuins"
        case glass = "MusicGlass"
        case sky = "MusicSky"
        case castle = "MusicCastle"
        case mainframe = "MusicMainframe"
    }

    static let shared = AudioManager()

    /// Where the sound comes out. The shell sets this as it starts; left
    /// alone the game is silent rather than broken, which is also what
    /// happens on a device that gives no audio.
    static var backend: AudioBackend = NullAudioBackend()

    private enum Key {
        static let soundEnabled = "settings.soundEnabled"
        static let musicEnabled = "settings.musicEnabled"
    }

    /// What the player's devices keep the same.
    static let syncedKeys: [String: ICloudSyncManager.Merge] = [Key.soundEnabled: .latest, Key.musicEnabled: .latest]

    static var isSoundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.soundEnabled) as? Bool ?? true }
        set { ICloudSyncManager.shared.set(newValue, forKey: Key.soundEnabled) }
    }

    static var isMusicEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.musicEnabled) as? Bool ?? true }
        set {
            ICloudSyncManager.shared.set(newValue, forKey: Key.musicEnabled)
            shared.updateMusic()
        }
    }

    /// Another device switched the music on or off.
    static func savedDataDidSync(_ keys: Set<String>) {
        if keys.contains(Key.musicEnabled) { shared.updateMusic() }
    }

    private var requestedMusic: Music?
    private var playingMusic: Music?
    /// The app is in the background: music waits for `resumeMusic()`.
    private var isInBackground = false

    private init() {}

    /// Called once at launch: loads every sound into the backend.
    ///
    /// There is no audio session to configure. Android's equivalent — asking
    /// for audio focus so the player's own music is respected — is a Java
    /// API; SDL opens the device without it, which is the "mix with others"
    /// behaviour the Apple build asks for anyway.
    static func loadSettings() {
        shared.preload()
    }

    /// A sound's file in the APK.
    static func url(of sound: Sound) -> URL? {
        Bundle.main.url(forResource: sound.rawValue, withExtension: "wav")
    }

    /// A soundtrack's file in the APK.
    static func url(of track: Music) -> URL? {
        Bundle.main.url(forResource: track.rawValue, withExtension: "m4a")
    }

    /// Crossfades to `track`, or fades out for nil. Asking for the track
    /// that's already playing keeps it going.
    func playMusic(_ track: Music?) {
        requestedMusic = track
        updateMusic()
    }

    /// Restarts a paused soundtrack (the app came back to the foreground).
    func resumeMusic() {
        isInBackground = false
        Self.backend.resume()
        updateMusic()
    }

    /// The app went away. The shell calls `suspend()` on the backend itself
    /// as Android takes the window; this is the game's half, so the track it
    /// asked for is remembered and nothing new starts meanwhile.
    func pauseMusic() {
        isInBackground = true
        Self.backend.suspend()
    }

    private func updateMusic() {
        let wanted = Self.isMusicEnabled && !isInBackground ? requestedMusic : nil
        guard wanted != playingMusic else { return }
        playingMusic = wanted
        Self.backend.playMusic(
            wanted?.rawValue,
            loop: wanted.flatMap(Self.loop(of:)),
            volume: DesignSystem.musicVolume,
            over: DesignSystem.musicFadeDuration
        )
    }

    /// Where a track repeats. `MusicLoops` is generated beside the files
    /// themselves by `npm run music`, so both platforms read one table.
    private static func loop(of track: Music) -> MusicLoop? {
        guard let frames = MusicLoops.frames[track.rawValue], frames.start < frames.end else { return nil }
        return MusicLoop(start: frames.start, end: frames.end)
    }

    func play(_ sound: Sound) {
        guard Self.isSoundEnabled else { return }
        let rate = sound.rateVariation.map { Float.random(in: $0) } ?? 1
        Self.backend.play(sound: sound.rawValue, rate: rate)
    }

    private func preload() {
        Self.backend.prepareSounds(
            Sound.allCases.map(\.rawValue),
            poolSize: DesignSystem.soundPlayerPoolSize,
            volume: DesignSystem.soundVolume
        )
    }
}

func playSound(_ sound: AudioManager.Sound) {
    // Recordings mix the game's sounds in afterwards, from these.
    Markers.note("sound \(sound.rawValue)")
    AudioManager.shared.play(sound)
}

func playMusic(_ track: AudioManager.Music?) {
    AudioManager.shared.playMusic(track)
}

extension WorldTheme {
    /// Each world's soundtrack loop.
    var music: AudioManager.Music {
        switch self {
        case .garden: return .garden
        case .farm: return .farm
        case .toys: return .toys
        case .meadow: return .meadow
        case .reef: return .reef
        case .kitchen: return .kitchen
        case .ruins: return .ruins
        case .glass: return .glass
        case .sky: return .sky
        case .castle: return .castle
        case .mainframe: return .mainframe
        }
    }
}
