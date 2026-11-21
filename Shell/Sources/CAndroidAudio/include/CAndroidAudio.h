#ifndef CANDROIDAUDIO_H
#define CANDROIDAUDIO_H

#include <stdbool.h>
#include <stdint.h>

// Decoding the soundtrack on Android.
//
// A game's music is AAC in an MPEG-4 container (`.m4a`), as on Apple. Android decodes it with MediaCodec, which the NDK
// exposes as a C API over `libmediandk.so` — a system library, so nothing is
// vendored and the APK ships the same audio bytes the IPA does.
//
// This is C rather than Swift because the MediaCodec dance is a buffer
// ping-pong with three sentinel return values, and because the asset handle
// comes from JNI. What Swift sees is the functions below: open, ask the
// format, pull PCM, seek, close.
//
// Positions are frames of the decoded stream, counted as they are handed
// out, not the codec's presentation times. A game's loop points count frames
// of the master, as `AVAudioFile` does on Apple, and the codec's times can't
// be trusted to say which frame a buffer holds: a decoder that trims the
// encoder's priming (Android's AAC decoders read it from the file's
// `iTunSMPB`) drops those frames but keeps the stamps of the packets they
// came from, so its stamps run ahead of the audio by the priming and jump
// where a trimmed buffer ends. Only the container's own times are exact, and
// they are used for one thing: which frame a seek landed on.

typedef struct SkaAudioDecoder SkaAudioDecoder;

/// Opens a file on disk. Returns NULL if it cannot be decoded.
SkaAudioDecoder *ska_audio_open_path(const char *path);

/// Opens a file inside the APK's assets, by the path the Gradle project
/// staged it at. The asset must be stored rather than deflated (the app's
/// `noCompress` list), because this hands MediaCodec a file descriptor into
/// the APK rather than copying the music onto the device. Returns NULL
/// if the asset manager is not reachable or the asset is compressed.
SkaAudioDecoder *ska_audio_open_asset(const char *path);

/// Whether the APK's assets hold `path`, asked of the same asset manager
/// `ska_audio_open_asset` opens it with. That one sees every split APK the
/// app was installed as (a release bundle's install-time asset packs among
/// them), where SDL's own path lookups read the base APK alone.
bool ska_audio_has_asset(const char *path);

/// Gives the decoder the app's asset manager, taken from the Java side.
/// SDL owns the activity, so Swift passes its JNIEnv and activity object
/// through; without this `ska_audio_open_asset` fails rather than guessing.
bool ska_audio_use_asset_manager(void *jni_env, void *activity);

int32_t ska_audio_sample_rate(const SkaAudioDecoder *decoder);
int32_t ska_audio_channels(const SkaAudioDecoder *decoder);
/// The whole file's length in microseconds, or 0 if the container omits it.
int64_t ska_audio_duration_us(const SkaAudioDecoder *decoder);

/// Fills `out` with up to `frames` frames of interleaved 16-bit PCM.
/// Returns the frames written, or 0 at the end of the stream. `position_us`,
/// when given, receives the time of the first frame written: its frame
/// (`ska_audio_frame`) at the file's rate.
int64_t ska_audio_read(SkaAudioDecoder *decoder, int16_t *out, int64_t frames, int64_t *position_us);

/// The frame the next read starts at: 0 once opened, then counted.
int64_t ska_audio_frame(const SkaAudioDecoder *decoder);

/// Moves to `frame`, exactly: it seeks to a sync sample a little before it,
/// so the codec has the packets before the frame to decode it from, and then
/// throws away decoded frames, counted, until the frame is reached.
bool ska_audio_seek_frame(SkaAudioDecoder *decoder, int64_t frame);

/// `ska_audio_seek_frame` to the frame nearest `position_us`.
bool ska_audio_seek(SkaAudioDecoder *decoder, int64_t position_us);

void ska_audio_close(SkaAudioDecoder *decoder);

#endif /* CANDROIDAUDIO_H */
