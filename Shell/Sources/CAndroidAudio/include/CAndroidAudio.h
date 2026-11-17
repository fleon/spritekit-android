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
// comes from JNI. What Swift sees is the five functions below: open, ask the
// format, pull PCM, seek, close.
//
// Positions are in microseconds of presentation time, not frames. That is
// deliberate. A game's loop points count frames of the master, and an AAC
// decoder hands back the encoder's priming samples as well, so a frame
// counter would drift from the master by a constant. Presentation time comes
// from the container for both "where am I" and "where do I want to be", so
// that constant cancels: seeking to the loop's start lands where the master
// says, whatever the codec primed with.

typedef struct SkaAudioDecoder SkaAudioDecoder;

/// Opens a file on disk. Returns NULL if it cannot be decoded.
SkaAudioDecoder *ska_audio_open_path(const char *path);

/// Opens a file inside the APK's assets, by the path the Gradle project
/// staged it at. The asset must be stored rather than deflated (the app's
/// `noCompress` list), because this hands MediaCodec a file descriptor into
/// the APK rather than copying the music onto the device. Returns NULL
/// if the asset manager is not reachable or the asset is compressed.
SkaAudioDecoder *ska_audio_open_asset(const char *path);

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
/// when given, receives the presentation time of the first frame written.
int64_t ska_audio_read(SkaAudioDecoder *decoder, int16_t *out, int64_t frames, int64_t *position_us);

/// Moves to `position_us`, exactly: it seeks to the sync sample at or before
/// it and then throws away what it decodes until the position is reached.
bool ska_audio_seek(SkaAudioDecoder *decoder, int64_t position_us);

void ska_audio_close(SkaAudioDecoder *decoder);

#endif /* CANDROIDAUDIO_H */
