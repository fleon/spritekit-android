import Foundation

/// Everything about a game's audio that is the game's own: its sounds and
/// tracks, how loud they play, how long fades take and where the switches
/// are saved. `AudioManager.configure(_:)` takes it once, at launch.
public struct AudioConfiguration {
    /// One sound effect, by its resource name without an extension.
    public struct Sound {
        public var name: String
        /// Voices kept for it, so quick repeats overlap; nil for `poolSize`.
        public var poolSize: Int?
        /// A playback rate picked at random each time, so repeats (footsteps)
        /// don't sound alike; nil plays it as recorded.
        public var rateVariation: ClosedRange<Float>?
        /// Its own volume; nil for `soundVolume`.
        public var volume: Float?

        public init(_ name: String, poolSize: Int? = nil, rateVariation: ClosedRange<Float>? = nil, volume: Float? = nil) {
            self.name = name
            self.poolSize = poolSize
            self.rateVariation = rateVariation
            self.volume = volume
        }
    }

    /// Where the sound and music switches are saved, and how. Both default
    /// to on and to the standard user defaults; a game that syncs its
    /// settings writes through its own store instead.
    public struct Settings {
        public var soundKey: String
        public var musicKey: String
        /// The saved switch for a key; nil when nothing was saved, which reads as on.
        public var read: (String) -> Bool?
        public var write: (Bool, String) -> Void

        public init(
            soundKey: String = "settings.soundEnabled",
            musicKey: String = "settings.musicEnabled",
            read: @escaping (String) -> Bool? = { UserDefaults.standard.object(forKey: $0) as? Bool },
            write: @escaping (Bool, String) -> Void = { UserDefaults.standard.set($0, forKey: $1) }
        ) {
            self.soundKey = soundKey
            self.musicKey = musicKey
            self.read = read
            self.write = write
        }
    }

    /// Loaded at launch. A sound not listed loads the first time it plays,
    /// with the defaults below.
    public var sounds: [Sound]
    public var poolSize: Int
    public var soundVolume: Float
    public var musicVolume: Float
    /// What a jingle turns the music down to (`duckMusicForJingle()`).
    public var duckedMusicVolume: Float
    /// How long one track takes to crossfade into the next.
    public var crossfadeDuration: TimeInterval
    /// How long music takes to fade in or out on its own: switched on or
    /// off, paused, resumed, ducked or stopped.
    public var musicFadeDuration: TimeInterval
    /// How long before a jingle ends the music comes back up.
    public var jingleLead: TimeInterval
    /// Where each track repeats, by name; a looping track not listed
    /// repeats whole.
    public var musicLoops: [String: MusicLoop]
    /// The extensions a sound's or a track's file may have, the first found
    /// winning (Apple builds; Android's shell has its own).
    public var soundExtensions: [String]
    public var musicExtensions: [String]
    /// The file of variant `index` (from 1) of a sound or track asked for
    /// with `variants:`.
    public var variantName: (String, Int) -> String
    public var settings: Settings
    /// Told every sound asked for, by file name, whether or not sound is
    /// on: for a game that logs or records them.
    public var onSound: ((String) -> Void)?

    public init(
        sounds: [Sound] = [],
        poolSize: Int = 3,
        soundVolume: Float = 1,
        musicVolume: Float = 1,
        duckedMusicVolume: Float = 0.05,
        crossfadeDuration: TimeInterval = 1,
        musicFadeDuration: TimeInterval = 0.25,
        jingleLead: TimeInterval = 1,
        musicLoops: [String: MusicLoop] = [:],
        soundExtensions: [String] = ["wav", "caf", "m4a", "mp3"],
        musicExtensions: [String] = ["m4a", "mp3", "aac", "caf", "wav"],
        variantName: @escaping (String, Int) -> String = { "\($0) \($1)" },
        settings: Settings = Settings(),
        onSound: ((String) -> Void)? = nil
    ) {
        self.sounds = sounds
        self.poolSize = poolSize
        self.soundVolume = soundVolume
        self.musicVolume = musicVolume
        self.duckedMusicVolume = duckedMusicVolume
        self.crossfadeDuration = crossfadeDuration
        self.musicFadeDuration = musicFadeDuration
        self.jingleLead = jingleLead
        self.musicLoops = musicLoops
        self.soundExtensions = soundExtensions
        self.musicExtensions = musicExtensions
        self.variantName = variantName
        self.settings = settings
        self.onSound = onSound
    }

    /// One `Sound` for each case of a game's sound enum, its options from
    /// `options` (nil for the defaults).
    public static func sounds<S: CaseIterable & RawRepresentable>(
        _ type: S.Type,
        options: (S) -> Sound? = { _ in nil }
    ) -> [Sound] where S.RawValue == String {
        type.allCases.map { sound in
            var spec = options(sound) ?? Sound(sound.rawValue)
            spec.name = sound.rawValue
            return spec
        }
    }
}

/// When things happen: the system's clock and the main queue, or a test's.
public struct AudioClock {
    public var now: () -> TimeInterval
    public var after: (TimeInterval, @escaping () -> Void) -> Void

    public init(now: @escaping () -> TimeInterval, after: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.now = now
        self.after = after
    }

    public static var system: AudioClock {
        AudioClock(
            now: { ProcessInfo.processInfo.systemUptime },
            after: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { work() }
                }
            }
        )
    }
}
