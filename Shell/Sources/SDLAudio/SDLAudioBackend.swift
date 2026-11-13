import CAndroidShell
import CSwitchlingsAudio
import Foundation
import PlatformShim
import ShellCore

/// `AudioBackend` on a device: SDL3 for the output and the sound effects,
/// Android's own MediaCodec for the soundtrack.
///
/// ## Why AAC through MediaCodec, rather than re-encoding the music
///
/// The soundtrack is AAC in an MPEG-4 container, built from the WAV masters
/// by `npm run music`. Android decodes AAC-LC, Ogg Vorbis and MP3 on every
/// device — the CDD makes all three mandatory — so there is no format
/// Android "wants"; the choice falls to other things:
///
///  - The APK ships **the same bytes the IPA does**. One encode, one set of
///    loop points, nothing that can drift between the platforms, and no
///    second 28 MB to build and keep in step.
///  - `libmediandk.so` is a system library and already on the shell's list
///    of libraries Android provides, so nothing is vendored, fetched or
///    built. Vorbis would have meant a decoder in the tree, and this
///    machine's ffmpeg has no libvorbis encoder to make the files with.
///  - It is hardware-accelerated on a real phone. The game is GPU-bound with
///    eight procedural backdrops; a software music decoder is the wrong
///    place to spend CPU.
///
/// And the choice is cheap to undo: `AMediaExtractor` reads the container
/// and `AMediaCodec_createDecoderByType` takes the MIME type out of it, so
/// .ogg or .mp3 would decode through the same C without a line changing.
/// Switching would be `export-music.js` writing another format and
/// `AudioAssets.musicExtension` naming it.
///
/// ## Loop points
///
/// `MusicLoops.frames` counts frames of the master. An AAC decoder hands
/// back the encoder's priming samples too, so counting decoded frames would
/// sit a constant off the master. The mixer works in the container's
/// presentation time instead — for both "where am I" and "where does the
/// loop start" — so that constant cancels. `export-music.js` also
/// crossfades the seam into the file itself, so the loop is forgiving by
/// construction rather than by luck.
public final class SDLAudioBackend: AudioBackend {
    /// The masters are 48 kHz stereo and so is everything built from them.
    private static let deviceRate: Int32 = 48_000
    private static let channels: Int32 = 2

    private let device: SDL_AudioDeviceID
    private var sounds: [String: SoundPool] = [:]
    private var mixer: MusicMixer?
    private var soundVolume: Float = 1

    /// Opens the audio device. Returns nil, having said why, if Android
    /// gives none — the game then runs silent rather than not at all.
    public init?() {
        guard SDL_InitSubSystem(SDL_INIT_AUDIO) else {
            Log.error("no audio: \(String(cString: SDL_GetError()))")
            return nil
        }
        var spec = SDL_AudioSpec(format: SWITCHLINGS_AUDIO_FORMAT, channels: Self.channels, freq: Self.deviceRate)
        let device = SDL_OpenAudioDevice(SWITCHLINGS_DEFAULT_PLAYBACK, &spec)
        guard device != 0 else {
            Log.error("no audio device: \(String(cString: SDL_GetError()))")
            return nil
        }
        self.device = device
        // MediaCodec reads the music straight out of the APK, which needs the
        // activity's asset manager. SDL owns the activity, so it is the one
        // that can hand it over.
        if !sw_audio_use_asset_manager(SDL_GetAndroidJNIEnv(), SDL_GetAndroidActivity()) {
            Log.error("no asset manager — the soundtrack will not play")
        }
        mixer = MusicMixer(device: device, rate: Self.deviceRate)
        Log.info("audio: device \(device), \(Self.deviceRate) Hz, \(Self.channels) ch")
    }

    deinit {
        mixer?.stop()
        // The voices are bound to the device, so they go first.
        sounds.removeAll()
        SDL_CloseAudioDevice(device)
    }

    public func prepareSounds(_ names: [String], poolSize: Int, volume: Float) {
        soundVolume = volume
        var loaded = 0
        for name in names where sounds[name] == nil {
            guard let wav = AudioAssets.load(AudioAssets.sound(name)) else {
                Log.error("no sound \(name) in the APK")
                continue
            }
            guard let pool = SoundPool(wav: wav, device: device, voices: poolSize, volume: volume) else {
                Log.error("sound \(name) would not load: \(String(cString: SDL_GetError()))")
                continue
            }
            sounds[name] = pool
            loaded += 1
        }
        Log.info("audio: \(loaded) sounds, \(poolSize) voices each")
    }

    public func play(sound name: String, rate: Float) {
        sounds[name]?.play(rate: rate)
    }

    public func playMusic(_ track: String?, loop: MusicLoop?, volume: Float, over fade: TimeInterval) {
        mixer?.play(track, loop: loop, volume: volume, over: fade)
    }

    public func suspend() {
        SDL_PauseAudioDevice(device)
    }

    public func resume() {
        SDL_ResumeAudioDevice(device)
    }
}
