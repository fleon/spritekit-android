import Foundation
import PlatformCore

/// Plays a game's sound effects and its soundtrack, on whichever
/// `AudioBackend` the platform gives: `AppleAudioBackend` on iPhone, iPad,
/// Apple TV and the Mac, the shell's on Android (handed over with `use(_:)`).
///
/// Every decision about what should be heard is made here, the same on
/// every platform: whether sound and music are switched on, which track the
/// screen asked for, whether a jingle has the music ducked. The soundtrack
/// follows the game's own music switch alone: other apps' audio never
/// silences it (it mixes in on Apple platforms; on Android the game takes
/// audio focus while its music is on). A backend only plays what it's told.
///
/// Sounds play from small pools of voices, so quick repeats overlap; one
/// played with `playEffect` gets a voice of its own that can loop and be
/// stopped. Asking for the track already playing keeps it going; asking for
/// another crossfades to it.
public final class AudioManager {
    public static let shared = AudioManager()

    /// Posted when the music switch may have changed: set here, synced from
    /// another device, or read under a new configuration.
    public static let musicEnabledDidChange = Notification.Name("AudioManager.musicEnabledDidChange")

    public private(set) var configuration = AudioConfiguration()
    public private(set) var backend: AudioBackend
    private let clock: AudioClock
    private var rates = Random("sound-rates")
    private var variants = Random("sound-variants")

    // Sounds
    private var prepared: Set<String> = []
    /// When each sound asked to `skipIfPlaying` is done playing.
    private var busyUntil: [String: TimeInterval] = [:]
    private struct Effect {
        var voice: AudioVoice?
        var repeats: Bool
    }
    private var effects: [Int: Effect] = [:]
    private var nextEffect = 0

    // Music
    private struct Track: Equatable {
        var file: String
        var loop: MusicLoop?
    }
    private var requested: Track?
    private var isPaused = false
    private var isDucked = false
    private var ducks = 0
    private var isInterrupted = false
    /// What the backend was last told: its track and volume.
    private var sentTrack: String?
    private var sentVolume: Float = 0

    public init(backend: AudioBackend = NullAudioBackend(), clock: AudioClock = .system) {
        self.backend = backend
        self.clock = clock
    }

    // MARK: Setup

    /// Called once at launch: takes the game's configuration and loads its
    /// sounds. On Apple platforms it also starts the audio itself
    /// (`AppleAudioBackend`); on Android the shell hands its backend over
    /// with `use(_:)` once its device opens, and until then nothing is heard.
    public static func configure(_ configuration: AudioConfiguration) {
        shared.configure(configuration)
    }

    public func configure(_ configuration: AudioConfiguration) {
        self.configuration = configuration
        // The switch may read otherwise under the game's own key or store,
        // and whoever asked before (Android's audio focus) hears it again.
        defer { NotificationCenter.default.post(name: Self.musicEnabledDidChange, object: self) }
        #if !SPRITEKIT_SHIM
        if backend is NullAudioBackend {
            use(AppleAudioBackend(soundExtensions: configuration.soundExtensions, musicExtensions: configuration.musicExtensions))
            return
        }
        #endif
        prepared = []
        prepare(configuration.sounds.map(\.name))
        updateMusic(fade: 0)
    }

    /// Plays through `backend` from now on: loads every sound loaded so far
    /// into it and starts the track the game asked for meanwhile.
    public func use(_ backend: AudioBackend) {
        self.backend = backend
        let names = configuration.sounds.map(\.name) + prepared.subtracting(configuration.sounds.map(\.name)).sorted()
        prepared = []
        prepare(names)
        sentTrack = nil
        sentVolume = 0
        updateMusic(fade: 0)
    }

    /// A call or an alarm took the audio (`interrupted`: everything waits),
    /// or gave it back. Android's audio focus arrives here; on Apple
    /// platforms the backend looks after interruptions itself.
    public func audioFocusDidChange(interrupted: Bool) {
        guard interrupted != isInterrupted else { return }
        isInterrupted = interrupted
        if interrupted { backend.suspend() } else { backend.resume() }
    }

    // MARK: Settings

    /// The settings' keys, for a game that syncs them.
    public static var settingsKeys: [String] {
        [shared.configuration.settings.soundKey, shared.configuration.settings.musicKey]
    }

    public static var isSoundEnabled: Bool {
        get { shared.soundEnabled }
        set { shared.soundEnabled = newValue }
    }

    public static var isMusicEnabled: Bool {
        get { shared.musicEnabled }
        set { shared.musicEnabled = newValue }
    }

    public var soundEnabled: Bool {
        get { configuration.settings.read(configuration.settings.soundKey) ?? true }
        set {
            configuration.settings.write(newValue, configuration.settings.soundKey)
            if !newValue { stopLoopingEffects() }
        }
    }

    public var musicEnabled: Bool {
        get { configuration.settings.read(configuration.settings.musicKey) ?? true }
        set {
            configuration.settings.write(newValue, configuration.settings.musicKey)
            updateMusic(fade: configuration.musicFadeDuration)
            NotificationCenter.default.post(name: Self.musicEnabledDidChange, object: self)
        }
    }

    /// Another device changed saved settings: the music follows its switch.
    public static func savedDataDidSync(_ keys: Set<String>) {
        shared.savedDataDidSync(keys)
    }

    public func savedDataDidSync(_ keys: Set<String>) {
        if keys.contains(configuration.settings.soundKey), !soundEnabled { stopLoopingEffects() }
        if keys.contains(configuration.settings.musicKey) {
            updateMusic(fade: configuration.musicFadeDuration)
            NotificationCenter.default.post(name: Self.musicEnabledDidChange, object: self)
        }
    }

    // MARK: Files

    /// A sound's file in the app's bundle.
    public static func url(ofSound name: String, in bundle: Bundle = .main) -> URL? {
        url(of: name, extensions: shared.configuration.soundExtensions, in: bundle)
    }

    /// A track's file in the app's bundle.
    public static func url(ofMusic name: String, in bundle: Bundle = .main) -> URL? {
        url(of: name, extensions: shared.configuration.musicExtensions, in: bundle)
    }

    static func url(of name: String, extensions: [String], in bundle: Bundle) -> URL? {
        for fileExtension in extensions {
            if let url = bundle.url(forResource: name, withExtension: fileExtension) { return url }
        }
        return nil
    }

    // MARK: Sounds

    /// Plays a sound on the next voice of its pool. Returns how long it
    /// plays, when the backend knows; nil when nothing played. A sound asked
    /// to `skipIfPlaying` doesn't play over its own last play. `variants`
    /// picks one of that many files at random (`AudioConfiguration.variantName`).
    @discardableResult
    public func play(_ name: String, skipIfPlaying: Bool = false, variants count: Int? = nil) -> TimeInterval? {
        let file = resolve(name, variants: count)
        configuration.onSound?(file)
        guard soundEnabled else { return nil }
        let now = clock.now()
        if skipIfPlaying, let busy = busyUntil[file], now < busy { return nil }
        prepare([file], like: name)
        let rate = rate(of: file, like: name)
        backend.play(sound: file, rate: rate)
        guard let duration = backend.duration(ofSound: file) else { return nil }
        let heard = duration / TimeInterval(rate)
        busyUntil[file] = now + heard
        return heard
    }

    @discardableResult
    public func play<S: RawRepresentable>(_ sound: S, skipIfPlaying: Bool = false) -> TimeInterval? where S.RawValue == String {
        play(sound.rawValue, skipIfPlaying: skipIfPlaying)
    }

    /// Plays a sound on a voice of its own: once, calling `onFinish` as it
    /// ends, or for ever when it `repeats`. Returns an id for `stopEffect`,
    /// or nil while sound is off.
    @discardableResult
    public func playEffect(_ name: String, repeats: Bool = false, variants count: Int? = nil, onFinish: (() -> Void)? = nil) -> Int? {
        let file = resolve(name, variants: count)
        configuration.onSound?(file)
        guard soundEnabled else { return nil }
        prepare([file], like: name)
        let rate = rate(of: file, like: name)
        nextEffect += 1
        let id = nextEffect
        effects[id] = Effect(voice: backend.play(sound: file, rate: rate, looping: repeats), repeats: repeats)
        if !repeats {
            let heard = backend.duration(ofSound: file).map { $0 / TimeInterval(rate) } ?? 0
            clock.after(heard) { [weak self] in
                guard self?.effects.removeValue(forKey: id) != nil else { return }
                onFinish?()
            }
        }
        return id
    }

    /// Stops an effect from `playEffect`, fading it out over `fadeDuration`;
    /// its `onFinish` isn't called.
    public func stopEffect(_ id: Int, fadeDuration: TimeInterval = 0) {
        guard let effect = effects.removeValue(forKey: id) else { return }
        if let voice = effect.voice { backend.stop(voice, over: fadeDuration) }
    }

    /// Stops every effect that repeats (a scene change, or sound switched off).
    public func stopLoopingEffects() {
        for (id, effect) in effects.sorted(by: { $0.key < $1.key }) where effect.repeats {
            stopEffect(id)
        }
    }

    /// The file to play: `name`, or one of its variants at random.
    private func resolve(_ name: String, variants count: Int?) -> String {
        guard let count else { return name }
        return configuration.variantName(name, Int.random(in: 1...max(count, 1), using: &variants))
    }

    private func spec(of file: String, like name: String) -> AudioConfiguration.Sound? {
        configuration.sounds.first { $0.name == file } ?? configuration.sounds.first { $0.name == name }
    }

    private func rate(of file: String, like name: String) -> Float {
        guard let variation = spec(of: file, like: name)?.rateVariation else { return 1 }
        return Float.random(in: variation, using: &rates)
    }

    /// Loads sounds not loaded yet into the backend, a call for each pool
    /// size and volume. A variant takes the options of the sound it's a
    /// variant of.
    private func prepare(_ files: [String], like name: String? = nil) {
        var groups: [(poolSize: Int, volume: Float, names: [String])] = []
        for file in files where !prepared.contains(file) {
            prepared.insert(file)
            let spec = spec(of: file, like: name ?? file)
            let poolSize = spec?.poolSize ?? configuration.poolSize
            let volume = spec?.volume ?? configuration.soundVolume
            if let index = groups.firstIndex(where: { $0.poolSize == poolSize && $0.volume == volume }) {
                groups[index].names.append(file)
            } else {
                groups.append((poolSize, volume, [file]))
            }
        }
        for group in groups {
            backend.prepareSounds(group.names, poolSize: group.poolSize, volume: group.volume)
        }
    }

    // MARK: Music

    /// Crossfades to `track`, or fades the soundtrack out for nil. Asking
    /// for the track already playing keeps it going. A track that loops
    /// repeats its `musicLoops` section, else the whole file; one that
    /// doesn't plays once. `variants` picks one of that many files at random.
    public func playMusic(_ track: String?, loop: Bool = true, variants count: Int? = nil) {
        requested = track.map { name in
            let file = resolve(name, variants: count)
            return Track(file: file, loop: loop ? configuration.musicLoops[file] ?? configuration.musicLoops[name] ?? .wholeTrack : nil)
        }
        isPaused = false
        updateMusic(fade: configuration.crossfadeDuration)
    }

    public func playMusic<T: RawRepresentable>(_ track: T?, loop: Bool = true) where T.RawValue == String {
        playMusic(track?.rawValue, loop: loop)
    }

    /// Fades the soundtrack out and forgets it.
    public func stopMusic(fadeDuration: TimeInterval? = nil) {
        requested = nil
        updateMusic(fade: fadeDuration ?? configuration.musicFadeDuration)
    }

    /// Fades the soundtrack out until `resumeMusic()`, keeping the track asked for.
    public func pauseMusic() {
        isPaused = true
        updateMusic(fade: configuration.musicFadeDuration)
    }

    public func resumeMusic() {
        isPaused = false
        updateMusic(fade: configuration.musicFadeDuration)
    }

    /// Turns the music down under a jingle.
    public func duckMusicForJingle() {
        ducks += 1
        isDucked = true
        updateMusic(fade: configuration.musicFadeDuration)
    }

    /// Brings the music back up `jingleLead` before a jingle of `duration`
    /// ends, unless another jingle ducked it since.
    public func restoreMusicAfterJingle(duration: TimeInterval?) {
        let duck = ducks
        clock.after(max((duration ?? 0) - configuration.jingleLead, 0)) { [weak self] in
            guard let self, self.ducks == duck else { return }
            self.isDucked = false
            self.updateMusic(fade: self.configuration.musicFadeDuration)
        }
    }

    /// Tells the backend what should be heard now, if that changed.
    private func updateMusic(fade: TimeInterval) {
        let silent = !musicEnabled || isPaused
        let wanted = silent ? nil : requested
        let volume = isDucked ? min(configuration.duckedMusicVolume, configuration.musicVolume) : configuration.musicVolume
        guard wanted?.file != sentTrack || (wanted != nil && volume != sentVolume) else { return }
        sentTrack = wanted?.file
        sentVolume = volume
        backend.playMusic(wanted?.file, loop: wanted?.loop, volume: volume, over: fade)
    }
}
