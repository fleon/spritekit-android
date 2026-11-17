#ifndef CANDROIDMEDIA_H
#define CANDROIDMEDIA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Writing video on Android: the device half of the AVFoundation
// stand-ins in `PlatformShim/Media`, over the NDK's MediaCodec, MediaMuxer
// and MediaExtractor (`libmediandk.so`, a system library), as the
// soundtrack's decoder is. Swift converts the frames and mixes the sound;
// this only encodes, muxes and copies.
//
// Everything here links against API 23. `AMediaCodec_getInputFormat`, which
// says how an encoder wants its frames laid out, is API 28, so it is looked
// up at run time and the frame's own size assumed without it.

typedef struct SkaVideoEncoder SkaVideoEncoder;

/// An H.264 encoder writing an MP4 at `path`. NULL if none could be opened.
SkaVideoEncoder *ska_video_open(const char *path, int32_t width, int32_t height, int32_t fps, int32_t bitrate);
/// The frames' layout the encoder took: 21 (NV12) or 19 (I420), the luma
/// row stride and the rows before the chroma.
int32_t ska_video_color_format(const SkaVideoEncoder *encoder);
int32_t ska_video_stride(const SkaVideoEncoder *encoder);
int32_t ska_video_slice_height(const SkaVideoEncoder *encoder);
/// Encodes one frame of `size` bytes, `pts_us` into the video, writing what
/// comes out to the file.
bool ska_video_encode(SkaVideoEncoder *encoder, const uint8_t *yuv, size_t size, int64_t pts_us);
/// Ends the stream, drains it, closes the file and frees the encoder.
bool ska_video_finish(SkaVideoEncoder *encoder);
/// Frees the encoder without finishing the file.
void ska_video_cancel(SkaVideoEncoder *encoder);

typedef struct SkaAudioEncoder SkaAudioEncoder;

/// An AAC-LC encoder writing an M4A at `path`.
SkaAudioEncoder *ska_aac_open(const char *path, int32_t sample_rate, int32_t channels, int32_t bitrate);
/// Encodes `frames` frames of interleaved 16-bit PCM.
bool ska_aac_encode(SkaAudioEncoder *encoder, const int16_t *pcm, int64_t frames);
/// Ends the stream, drains it, closes the file and frees the encoder.
bool ska_aac_finish(SkaAudioEncoder *encoder);

/// How long the first video (or audio) track in `path` runs; -1 if it has none.
int64_t sw_media_duration_us(const char *path, bool video);

/// Copies the first video or audio track of each of `count` files, as it
/// is, into one MP4 at `output`, interleaved by time; a track stops at its
/// limit (microseconds) when it has one (> 0).
bool sw_media_remux(const char *output, const char *const *paths, const bool *is_video, const int64_t *limits_us, int32_t count);

#endif /* CANDROIDMEDIA_H */
