import CAndroidShell
import CAndroidAudio
import Foundation
import ShellCore

/// One sound effect, decoded once and kept, with a few voices so quick
/// repeats overlap rather than cutting one another off — the same shape as
/// the Apple build's pool of `AVAudioPlayer`s.
///
/// A voice is an `SDL_AudioStream` bound to the device. Playing means
/// clearing it and putting the whole clip in again, which is what
/// `player.currentTime = 0` does there. SDL gives two things the game needs
/// for free: a gain per stream, and a frequency ratio, which is how
/// footsteps vary their pitch (`DesignSystem.stepRateVariation`).
final class SoundPool {
    private final class Voice {
        let stream: OpaquePointer

        init(stream: OpaquePointer) {
            self.stream = stream
        }
    }

    private let pcm: [UInt8]
    /// How long the sound plays as recorded.
    let duration: TimeInterval
    private var voices: [Voice] = []
    private var next = 0

    init?(wav: Data, device: SDL_AudioDeviceID, voices count: Int, volume: Float) {
        var spec = SDL_AudioSpec()
        var buffer: UnsafeMutablePointer<UInt8>?
        var length: UInt32 = 0
        let loaded: Bool = wav.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, let io = SDL_IOFromConstMem(base, raw.count) else { return false }
            return SDL_LoadWAV_IO(io, true, &spec, &buffer, &length)
        }
        guard loaded, let buffer, length > 0 else { return nil }
        pcm = Array(UnsafeBufferPointer(start: buffer, count: Int(length)))
        SDL_free(buffer)
        // SDL_AUDIO_BITSIZE: the format's low byte is its sample's bits.
        let frameBytes = Int(UInt32(spec.format.rawValue) & 0xFF) / 8 * Int(spec.channels)
        duration = frameBytes > 0 && spec.freq > 0 ? TimeInterval(pcm.count / frameBytes) / TimeInterval(spec.freq) : 0

        var source = spec
        var destination = SDL_AudioSpec(format: SKA_AUDIO_FORMAT, channels: spec.channels, freq: spec.freq)
        for _ in 0..<count {
            guard let stream = SDL_CreateAudioStream(&source, &destination) else { continue }
            SDL_SetAudioStreamGain(stream, volume)
            SDL_BindAudioStream(device, stream)
            voices.append(Voice(stream: stream))
        }
        guard !voices.isEmpty else { return nil }
    }

    deinit {
        for voice in voices { SDL_DestroyAudioStream(voice.stream) }
    }

    /// Plays on the next voice round the pool, at `rate` (1 as recorded).
    func play(rate: Float) {
        guard !voices.isEmpty else { return }
        let voice = voices[next]
        next = (next + 1) % voices.count
        SDL_ClearAudioStream(voice.stream)
        SDL_SetAudioStreamFrequencyRatio(voice.stream, rate)
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            SDL_PutAudioStreamData(voice.stream, base, Int32(raw.count))
        }
    }

    func setVolume(_ volume: Float) {
        for voice in voices { SDL_SetAudioStreamGain(voice.stream, volume) }
    }
}
