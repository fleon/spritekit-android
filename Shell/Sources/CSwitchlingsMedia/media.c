#include "CSwitchlingsMedia.h"

#include <android/log.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>
#include <media/NdkMediaMuxer.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define TAG "Switchlings"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

/// How long a dequeue waits for the codec while frames are flowing.
static const int64_t kDequeueTimeoutUs = 10000;
/// Give up on a codec that has nothing to show this many times running.
static const int kMaxIdleRounds = 500;

// MediaCodecInfo.CodecCapabilities' colour formats.
static const int32_t kColorFormatYUV420Planar = 19;
static const int32_t kColorFormatYUV420SemiPlanar = 21;
// MediaFormat's colour keys and values (API 24's strings; the NDK names them
// only from API 28): BT.709 primaries and matrix, video range, SDR video.
static const int32_t kColorStandardBT709 = 1;
static const int32_t kColorRangeLimited = 2;
static const int32_t kColorTransferSDRVideo = 3;

// MediaCodec.BUFFER_FLAG_*: the NDK's spelling of KEY_FRAME is API 26+.
static const uint32_t kBufferFlagKeyFrame = 1;

/// A codec writing what it encodes into a muxer track.
typedef struct {
    AMediaCodec *codec;
    AMediaMuxer *muxer;
    int fd;
    ssize_t track;
    bool started;
    bool ended;
} Pipe;

static int open_output(const char *path) {
    return open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
}

/// Hands the muxer whatever the codec has finished. With `until_end` it
/// waits for the end of the stream; otherwise it takes what's ready.
static bool drain(Pipe *pipe, bool until_end) {
    int idle = 0;
    while (!pipe->ended) {
        AMediaCodecBufferInfo info;
        ssize_t index = AMediaCodec_dequeueOutputBuffer(pipe->codec, &info, until_end ? kDequeueTimeoutUs : 0);
        if (index == AMEDIACODEC_INFO_TRY_AGAIN_LATER) {
            if (!until_end) return true;
            if (++idle > kMaxIdleRounds) {
                LOGE("an encoder never finished its stream");
                return false;
            }
            continue;
        }
        idle = 0;
        if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
            AMediaFormat *format = AMediaCodec_getOutputFormat(pipe->codec);
            pipe->track = AMediaMuxer_addTrack(pipe->muxer, format);
            AMediaFormat_delete(format);
            if (pipe->track < 0 || AMediaMuxer_start(pipe->muxer) != AMEDIA_OK) {
                LOGE("the muxer would not take the encoder's track");
                return false;
            }
            pipe->started = true;
            continue;
        }
        if (index == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) continue;
        if (index < 0) {
            LOGE("an encoder's output failed (%zd)", index);
            return false;
        }
        size_t capacity = 0;
        uint8_t *data = AMediaCodec_getOutputBuffer(pipe->codec, (size_t)index, &capacity);
        // The codec's own setup bytes reached the muxer with its format.
        bool config = (info.flags & AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG) != 0;
        if (data != NULL && info.size > 0 && !config && pipe->started) {
            if (AMediaMuxer_writeSampleData(pipe->muxer, (size_t)pipe->track, data + info.offset, &info) != AMEDIA_OK) {
                LOGE("the muxer refused a sample");
                AMediaCodec_releaseOutputBuffer(pipe->codec, (size_t)index, false);
                return false;
            }
        }
        AMediaCodec_releaseOutputBuffer(pipe->codec, (size_t)index, false);
        if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) pipe->ended = true;
    }
    return true;
}

/// Queues `size` bytes (or the end of the stream, with `data` NULL),
/// draining output while the codec has no input buffer free.
static bool feed(Pipe *pipe, const uint8_t *data, size_t size, int64_t pts_us) {
    for (int round = 0; round < kMaxIdleRounds; round++) {
        ssize_t index = AMediaCodec_dequeueInputBuffer(pipe->codec, kDequeueTimeoutUs);
        if (index == AMEDIACODEC_INFO_TRY_AGAIN_LATER) {
            if (!drain(pipe, false)) return false;
            continue;
        }
        if (index < 0) {
            LOGE("an encoder's input failed (%zd)", index);
            return false;
        }
        size_t capacity = 0;
        uint8_t *buffer = AMediaCodec_getInputBuffer(pipe->codec, (size_t)index, &capacity);
        if (buffer == NULL) return false;
        size_t count = data == NULL ? 0 : (size < capacity ? size : capacity);
        if (count > 0) memcpy(buffer, data, count);
        uint32_t flags = data == NULL ? AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM : 0;
        if (AMediaCodec_queueInputBuffer(pipe->codec, (size_t)index, 0, count, (uint64_t)pts_us, flags) != AMEDIA_OK) return false;
        return drain(pipe, false);
    }
    LOGE("an encoder never took its input");
    return false;
}

/// Ends the stream and closes everything. True if the file is whole.
static bool close_pipe(Pipe *pipe, bool finish, int64_t end_us) {
    bool ok = true;
    if (finish) {
        ok = feed(pipe, NULL, 0, end_us) && drain(pipe, true) && pipe->started;
    }
    if (pipe->codec != NULL) {
        AMediaCodec_stop(pipe->codec);
        AMediaCodec_delete(pipe->codec);
    }
    if (pipe->muxer != NULL) {
        if (pipe->started && AMediaMuxer_stop(pipe->muxer) != AMEDIA_OK) ok = false;
        AMediaMuxer_delete(pipe->muxer);
    }
    if (pipe->fd >= 0) close(pipe->fd);
    return ok && finish;
}

// MARK: - Video

struct SwVideoEncoder {
    Pipe pipe;
    int32_t colorFormat;
    int32_t stride;
    int32_t sliceHeight;
    int64_t lastPts;
};

typedef AMediaFormat *(*GetInputFormat)(AMediaCodec *);

SwVideoEncoder *sw_video_open(const char *path, int32_t width, int32_t height, int32_t fps, int32_t bitrate) {
    SwVideoEncoder *e = calloc(1, sizeof(SwVideoEncoder));
    if (e == NULL) return NULL;
    e->pipe.fd = -1;
    e->pipe.track = -1;
    const int32_t formats[] = { kColorFormatYUV420SemiPlanar, kColorFormatYUV420Planar };
    for (size_t i = 0; i < sizeof(formats) / sizeof(formats[0]) && e->pipe.codec == NULL; i++) {
        AMediaCodec *codec = AMediaCodec_createEncoderByType("video/avc");
        if (codec == NULL) break;
        AMediaFormat *format = AMediaFormat_new();
        AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, "video/avc");
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, width);
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, height);
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_BIT_RATE, bitrate);
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_FRAME_RATE, fps);
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_I_FRAME_INTERVAL, 1);
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_COLOR_FORMAT, formats[i]);
        AMediaFormat_setInt32(format, "color-standard", kColorStandardBT709);
        AMediaFormat_setInt32(format, "color-range", kColorRangeLimited);
        AMediaFormat_setInt32(format, "color-transfer", kColorTransferSDRVideo);
        media_status_t status = AMediaCodec_configure(codec, format, NULL, NULL, AMEDIACODEC_CONFIGURE_FLAG_ENCODE);
        AMediaFormat_delete(format);
        if (status != AMEDIA_OK || AMediaCodec_start(codec) != AMEDIA_OK) {
            AMediaCodec_delete(codec);
            continue;
        }
        e->pipe.codec = codec;
        e->colorFormat = formats[i];
    }
    if (e->pipe.codec == NULL) {
        LOGE("no H.264 encoder takes %d x %d", width, height);
        free(e);
        return NULL;
    }
    e->stride = width;
    e->sliceHeight = height;
    GetInputFormat getInputFormat = (GetInputFormat)dlsym(RTLD_DEFAULT, "AMediaCodec_getInputFormat");
    if (getInputFormat != NULL) {
        AMediaFormat *input = getInputFormat(e->pipe.codec);
        if (input != NULL) {
            int32_t value = 0;
            if (AMediaFormat_getInt32(input, "stride", &value) && value >= width) e->stride = value;
            if (AMediaFormat_getInt32(input, "slice-height", &value) && value >= height) e->sliceHeight = value;
            AMediaFormat_delete(input);
        }
    }
    e->pipe.fd = open_output(path);
    e->pipe.muxer = e->pipe.fd >= 0 ? AMediaMuxer_new(e->pipe.fd, AMEDIAMUXER_OUTPUT_FORMAT_MPEG_4) : NULL;
    if (e->pipe.muxer == NULL) {
        LOGE("could not write %s", path);
        close_pipe(&e->pipe, false, 0);
        free(e);
        return NULL;
    }
    LOGI("H.264 encoder: %d x %d at %d fps, %d bps, colour format %d, stride %d, slice height %d",
         width, height, fps, bitrate, e->colorFormat, e->stride, e->sliceHeight);
    return e;
}

int32_t sw_video_color_format(const SwVideoEncoder *e) { return e->colorFormat; }
int32_t sw_video_stride(const SwVideoEncoder *e) { return e->stride; }
int32_t sw_video_slice_height(const SwVideoEncoder *e) { return e->sliceHeight; }

bool sw_video_encode(SwVideoEncoder *e, const uint8_t *yuv, size_t size, int64_t pts_us) {
    e->lastPts = pts_us;
    return feed(&e->pipe, yuv, size, pts_us);
}

bool sw_video_finish(SwVideoEncoder *e) {
    bool ok = close_pipe(&e->pipe, true, e->lastPts);
    free(e);
    return ok;
}

void sw_video_cancel(SwVideoEncoder *e) {
    close_pipe(&e->pipe, false, 0);
    free(e);
}

// MARK: - AAC

struct SwAudioEncoder {
    Pipe pipe;
    int32_t sampleRate;
    int32_t channels;
    int64_t framesIn;
};

SwAudioEncoder *sw_aac_open(const char *path, int32_t sample_rate, int32_t channels, int32_t bitrate) {
    SwAudioEncoder *e = calloc(1, sizeof(SwAudioEncoder));
    if (e == NULL) return NULL;
    e->pipe.fd = -1;
    e->pipe.track = -1;
    e->sampleRate = sample_rate;
    e->channels = channels;
    AMediaCodec *codec = AMediaCodec_createEncoderByType("audio/mp4a-latm");
    AMediaFormat *format = AMediaFormat_new();
    AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, "audio/mp4a-latm");
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_SAMPLE_RATE, sample_rate);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_CHANNEL_COUNT, channels);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_BIT_RATE, bitrate);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_AAC_PROFILE, 2); // AAC-LC
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_MAX_INPUT_SIZE, 1 << 16);
    bool ok = codec != NULL
        && AMediaCodec_configure(codec, format, NULL, NULL, AMEDIACODEC_CONFIGURE_FLAG_ENCODE) == AMEDIA_OK
        && AMediaCodec_start(codec) == AMEDIA_OK;
    AMediaFormat_delete(format);
    if (!ok) {
        LOGE("no AAC encoder at %d Hz, %d channels", sample_rate, channels);
        if (codec != NULL) AMediaCodec_delete(codec);
        free(e);
        return NULL;
    }
    e->pipe.codec = codec;
    e->pipe.fd = open_output(path);
    e->pipe.muxer = e->pipe.fd >= 0 ? AMediaMuxer_new(e->pipe.fd, AMEDIAMUXER_OUTPUT_FORMAT_MPEG_4) : NULL;
    if (e->pipe.muxer == NULL) {
        close_pipe(&e->pipe, false, 0);
        free(e);
        return NULL;
    }
    return e;
}

bool sw_aac_encode(SwAudioEncoder *e, const int16_t *pcm, int64_t frames) {
    // A few thousand frames at a time, so each fits an input buffer.
    const int64_t chunk = 2048;
    for (int64_t start = 0; start < frames; start += chunk) {
        int64_t count = frames - start < chunk ? frames - start : chunk;
        int64_t pts = e->framesIn * 1000000 / e->sampleRate;
        if (!feed(&e->pipe, (const uint8_t *)(pcm + start * e->channels), (size_t)(count * e->channels) * sizeof(int16_t), pts)) return false;
        e->framesIn += count;
    }
    return true;
}

bool sw_aac_finish(SwAudioEncoder *e) {
    bool ok = close_pipe(&e->pipe, true, e->framesIn * 1000000 / e->sampleRate);
    free(e);
    return ok;
}

// MARK: - Reading and remuxing

typedef struct {
    AMediaExtractor *extractor;
    int fd;
    ssize_t track;
    AMediaFormat *format;
} Source;

static bool open_source(Source *s, const char *path, bool video) {
    memset(s, 0, sizeof(*s));
    s->track = -1;
    s->fd = open(path, O_RDONLY);
    struct stat info;
    if (s->fd < 0 || fstat(s->fd, &info) != 0) return false;
    s->extractor = AMediaExtractor_new();
    if (s->extractor == NULL || AMediaExtractor_setDataSourceFd(s->extractor, s->fd, 0, info.st_size) != AMEDIA_OK) return false;
    const char *prefix = video ? "video/" : "audio/";
    size_t tracks = AMediaExtractor_getTrackCount(s->extractor);
    for (size_t i = 0; i < tracks; i++) {
        AMediaFormat *format = AMediaExtractor_getTrackFormat(s->extractor, i);
        const char *mime = NULL;
        if (AMediaFormat_getString(format, AMEDIAFORMAT_KEY_MIME, &mime) && strncmp(mime, prefix, 6) == 0) {
            s->track = (ssize_t)i;
            s->format = format;
            AMediaExtractor_selectTrack(s->extractor, i);
            return true;
        }
        AMediaFormat_delete(format);
    }
    return false;
}

static void close_source(Source *s) {
    if (s->format != NULL) AMediaFormat_delete(s->format);
    if (s->extractor != NULL) AMediaExtractor_delete(s->extractor);
    if (s->fd >= 0) close(s->fd);
}

int64_t sw_media_duration_us(const char *path, bool video) {
    Source s;
    int64_t duration = -1;
    if (open_source(&s, path, video) && !AMediaFormat_getInt64(s.format, AMEDIAFORMAT_KEY_DURATION, &duration)) duration = -1;
    close_source(&s);
    return duration;
}

bool sw_media_remux(const char *output, const char *const *paths, const bool *is_video, const int64_t *limits_us, int32_t count) {
    if (count <= 0 || count > 8) return false;
    Source sources[8];
    ssize_t tracks[8];
    bool done[8];
    int opened = 0;
    bool ok = true;
    int fd = open_output(output);
    AMediaMuxer *muxer = fd >= 0 ? AMediaMuxer_new(fd, AMEDIAMUXER_OUTPUT_FORMAT_MPEG_4) : NULL;
    if (muxer == NULL) ok = false;
    for (int i = 0; ok && i < count; i++) {
        ok = open_source(&sources[i], paths[i], is_video[i]);
        opened = i + 1;
        if (ok) {
            tracks[i] = AMediaMuxer_addTrack(muxer, sources[i].format);
            done[i] = false;
            ok = tracks[i] >= 0;
        }
        if (!ok) LOGE("%s has no %s track to copy", paths[i], is_video[i] ? "video" : "audio");
    }
    ok = ok && AMediaMuxer_start(muxer) == AMEDIA_OK;
    size_t capacity = 4 << 20;
    uint8_t *buffer = ok ? malloc(capacity) : NULL;
    ok = ok && buffer != NULL;
    // Every track's next sample, earliest first, so the file interleaves.
    while (ok) {
        int next = -1;
        int64_t earliest = INT64_MAX;
        for (int i = 0; i < count; i++) {
            if (done[i]) continue;
            int64_t time = AMediaExtractor_getSampleTime(sources[i].extractor);
            if (time < 0 || (limits_us[i] > 0 && time >= limits_us[i])) {
                done[i] = true;
                continue;
            }
            if (time < earliest) {
                earliest = time;
                next = i;
            }
        }
        if (next < 0) break;
        AMediaExtractor *extractor = sources[next].extractor;
        ssize_t size = AMediaExtractor_readSampleData(extractor, buffer, capacity);
        if (size < 0) {
            done[next] = true;
            continue;
        }
        AMediaCodecBufferInfo info = {
            .offset = 0,
            .size = (int32_t)size,
            .presentationTimeUs = earliest,
            .flags = (AMediaExtractor_getSampleFlags(extractor) & AMEDIAEXTRACTOR_SAMPLE_FLAG_SYNC) ? kBufferFlagKeyFrame : 0,
        };
        if (AMediaMuxer_writeSampleData(muxer, (size_t)tracks[next], buffer, &info) != AMEDIA_OK) ok = false;
        AMediaExtractor_advance(extractor);
    }
    free(buffer);
    for (int i = 0; i < opened; i++) close_source(&sources[i]);
    if (muxer != NULL) {
        if (AMediaMuxer_stop(muxer) != AMEDIA_OK) ok = false;
        AMediaMuxer_delete(muxer);
    }
    if (fd >= 0) close(fd);
    return ok;
}
