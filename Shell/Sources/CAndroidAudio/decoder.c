#include "CAndroidAudio.h"

#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <android/log.h>
#include <jni.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The app's logcat tag (shim.c). */
extern const char *ska_log_tag;
#define TAG ska_log_tag
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/// How long a dequeue waits before giving the caller its turn back. Short
/// enough that the mixer thread never blocks for a frame's worth of audio.
static const int64_t kDequeueTimeoutUs = 5000;
/// Decoded audio kept between reads, in frames. A MediaCodec output buffer
/// for AAC is 1024 frames; a few of them in hand keeps the pull cheap.
static const int64_t kScratchFrames = 8192;
/// Give up rather than spin if the codec asks to be tried again this often
/// with nothing to show.
static const int kMaxIdleRounds = 64;
/// How far before a seek's frame decoding starts. An AAC frame is built from
/// the packet before it as well (the transform overlaps), so a decoder
/// started cold on the frame's own packet gets its first frames wrong; a few
/// packets earlier, they are thrown away before the frame is reached.
static const int64_t kSeekPrerollFrames = 4096;

struct SkaAudioDecoder {
    AMediaExtractor *extractor;
    AMediaCodec *codec;
    int fd;                 // >= 0 when we own one (an asset or a file)
    int32_t sampleRate;
    int32_t channels;
    int64_t durationUs;

    int16_t *scratch;       // interleaved PCM waiting to be handed out
    int64_t scratchFrames;  // frames in it
    int64_t scratchRead;    // frames already handed out
    int64_t frame;          // the frame the next read hands out

    bool inputDone;
    bool outputDone;
};

static AAssetManager *gAssets = NULL;

bool ska_audio_use_asset_manager(void *jni_env, void *activity) {
    if (jni_env == NULL || activity == NULL) return false;
    JNIEnv *env = (JNIEnv *)jni_env;
    jobject self = (jobject)activity;
    jclass cls = (*env)->GetObjectClass(env, self);
    if (cls == NULL) return false;
    jmethodID getAssets = (*env)->GetMethodID(env, cls, "getAssets", "()Landroid/content/res/AssetManager;");
    if (getAssets == NULL) {
        (*env)->ExceptionClear(env);
        return false;
    }
    jobject manager = (*env)->CallObjectMethod(env, self, getAssets);
    if (manager == NULL) return false;
    // The activity outlives the process's audio, so a global reference is
    // the right lifetime: the manager must stay valid for every open.
    jobject kept = (*env)->NewGlobalRef(env, manager);
    gAssets = AAssetManager_fromJava(env, kept);
    return gAssets != NULL;
}

/// Finds the first audio track, selects it, and builds a decoder for it.
static bool start(SkaAudioDecoder *d) {
    size_t tracks = AMediaExtractor_getTrackCount(d->extractor);
    for (size_t i = 0; i < tracks; i++) {
        AMediaFormat *format = AMediaExtractor_getTrackFormat(d->extractor, i);
        const char *mime = NULL;
        if (!AMediaFormat_getString(format, AMEDIAFORMAT_KEY_MIME, &mime) || strncmp(mime, "audio/", 6) != 0) {
            AMediaFormat_delete(format);
            continue;
        }
        AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_SAMPLE_RATE, &d->sampleRate);
        AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &d->channels);
        AMediaFormat_getInt64(format, AMEDIAFORMAT_KEY_DURATION, &d->durationUs);
        if (AMediaExtractor_selectTrack(d->extractor, i) != AMEDIA_OK) {
            AMediaFormat_delete(format);
            continue;
        }
        d->codec = AMediaCodec_createDecoderByType(mime);
        if (d->codec == NULL || AMediaCodec_configure(d->codec, format, NULL, NULL, 0) != AMEDIA_OK
            || AMediaCodec_start(d->codec) != AMEDIA_OK) {
            LOGE("no decoder for %s", mime);
            AMediaFormat_delete(format);
            return false;
        }
        AMediaFormat_delete(format);
        return d->sampleRate > 0 && d->channels > 0;
    }
    LOGE("no audio track");
    return false;
}

static SkaAudioDecoder *make(void) {
    SkaAudioDecoder *d = calloc(1, sizeof(SkaAudioDecoder));
    if (d == NULL) return NULL;
    d->fd = -1;
    d->extractor = AMediaExtractor_new();
    if (d->extractor == NULL) {
        free(d);
        return NULL;
    }
    return d;
}

static SkaAudioDecoder *finish(SkaAudioDecoder *d) {
    if (!start(d)) {
        ska_audio_close(d);
        return NULL;
    }
    d->scratch = malloc((size_t)(kScratchFrames * d->channels) * sizeof(int16_t));
    if (d->scratch == NULL) {
        ska_audio_close(d);
        return NULL;
    }
    return d;
}

SkaAudioDecoder *ska_audio_open_path(const char *path) {
    SkaAudioDecoder *d = make();
    if (d == NULL) return NULL;
    if (AMediaExtractor_setDataSource(d->extractor, path) != AMEDIA_OK) {
        LOGE("cannot read %s", path);
        ska_audio_close(d);
        return NULL;
    }
    return finish(d);
}

SkaAudioDecoder *ska_audio_open_asset(const char *path) {
    if (gAssets == NULL) {
        LOGE("no asset manager: call ska_audio_use_asset_manager first");
        return NULL;
    }
    AAsset *asset = AAssetManager_open(gAssets, path, AASSET_MODE_RANDOM);
    if (asset == NULL) {
        LOGE("no asset at %s", path);
        return NULL;
    }
    off_t start = 0, length = 0;
    int fd = AAsset_openFileDescriptor(asset, &start, &length);
    AAsset_close(asset);
    if (fd < 0) {
        // Only a stored asset has a descriptor; a deflated one has none.
        LOGE("%s is compressed in the APK — add its extension to noCompress", path);
        return NULL;
    }
    SkaAudioDecoder *d = make();
    if (d == NULL) {
        close(fd);
        return NULL;
    }
    d->fd = fd;
    if (AMediaExtractor_setDataSourceFd(d->extractor, fd, (off64_t)start, (off64_t)length) != AMEDIA_OK) {
        LOGE("cannot read asset %s", path);
        ska_audio_close(d);
        return NULL;
    }
    return finish(d);
}

int32_t ska_audio_sample_rate(const SkaAudioDecoder *d) { return d == NULL ? 0 : d->sampleRate; }
int32_t ska_audio_channels(const SkaAudioDecoder *d) { return d == NULL ? 0 : d->channels; }
int64_t ska_audio_duration_us(const SkaAudioDecoder *d) { return d == NULL ? 0 : d->durationUs; }

/// Hands the codec one compressed sample, if it has room for one.
static void feed(SkaAudioDecoder *d) {
    if (d->inputDone) return;
    ssize_t index = AMediaCodec_dequeueInputBuffer(d->codec, 0);
    if (index < 0) return;
    size_t capacity = 0;
    uint8_t *buffer = AMediaCodec_getInputBuffer(d->codec, (size_t)index, &capacity);
    if (buffer == NULL) return;
    ssize_t size = AMediaExtractor_readSampleData(d->extractor, buffer, capacity);
    if (size <= 0) {
        AMediaCodec_queueInputBuffer(d->codec, (size_t)index, 0, 0, 0, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
        d->inputDone = true;
        return;
    }
    int64_t time = AMediaExtractor_getSampleTime(d->extractor);
    AMediaCodec_queueInputBuffer(d->codec, (size_t)index, 0, (size_t)size, time < 0 ? 0 : time, 0);
    AMediaExtractor_advance(d->extractor);
}

/// Fills the scratch buffer with the next decoded run. Returns false at the
/// end of the stream or on an error the decoder cannot come back from.
static bool decodeMore(SkaAudioDecoder *d) {
    d->scratchFrames = 0;
    d->scratchRead = 0;
    if (d->outputDone) return false;

    for (int idle = 0; idle < kMaxIdleRounds; idle++) {
        feed(d);
        AMediaCodecBufferInfo info;
        ssize_t index = AMediaCodec_dequeueOutputBuffer(d->codec, &info, kDequeueTimeoutUs);
        if (index == AMEDIACODEC_INFO_TRY_AGAIN_LATER || index == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) {
            continue;
        }
        if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
            AMediaFormat *format = AMediaCodec_getOutputFormat(d->codec);
            if (format != NULL) {
                // A decoder may only report the real rate once it has run.
                int32_t rate = d->sampleRate, channels = d->channels;
                AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_SAMPLE_RATE, &rate);
                AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &channels);
                AMediaFormat_delete(format);
                if (channels > d->channels) {
                    // The scratch was sized for fewer: grow it rather than overrun.
                    int16_t *grown = realloc(d->scratch, (size_t)(kScratchFrames * channels) * sizeof(int16_t));
                    if (grown == NULL) return false;
                    d->scratch = grown;
                }
                d->sampleRate = rate;
                d->channels = channels;
            }
            continue;
        }
        if (index < 0) {
            LOGE("decoder gave up (%zd)", index);
            d->outputDone = true;
            return false;
        }

        size_t capacity = 0;
        uint8_t *buffer = AMediaCodec_getOutputBuffer(d->codec, (size_t)index, &capacity);
        int64_t frames = 0;
        if (buffer != NULL && info.size > 0) {
            frames = (int64_t)info.size / ((int64_t)d->channels * (int64_t)sizeof(int16_t));
            if (frames > kScratchFrames) frames = kScratchFrames;
            memcpy(d->scratch, buffer + info.offset, (size_t)(frames * d->channels) * sizeof(int16_t));
            d->scratchFrames = frames;
        }
        bool ended = (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) != 0;
        AMediaCodec_releaseOutputBuffer(d->codec, (size_t)index, false);
        if (ended) d->outputDone = true;
        if (frames > 0) return true;
        if (ended) return false;
    }
    LOGE("decoder stalled");
    return false;
}

int64_t ska_audio_read(SkaAudioDecoder *d, int16_t *out, int64_t frames, int64_t *position_us) {
    if (d == NULL || out == NULL || frames <= 0) return 0;
    int64_t written = 0;
    bool placed = false;
    while (written < frames) {
        if (d->scratchRead >= d->scratchFrames) {
            if (!decodeMore(d)) break;
        }
        int64_t available = d->scratchFrames - d->scratchRead;
        int64_t take = frames - written;
        if (take > available) take = available;
        if (!placed) {
            if (position_us != NULL) *position_us = d->frame * 1000000 / d->sampleRate;
            placed = true;
        }
        memcpy(out + written * d->channels,
               d->scratch + d->scratchRead * d->channels,
               (size_t)(take * d->channels) * sizeof(int16_t));
        written += take;
        d->scratchRead += take;
        d->frame += take;
    }
    return written;
}

int64_t ska_audio_frame(const SkaAudioDecoder *d) { return d == NULL ? 0 : d->frame; }

bool ska_audio_seek_frame(SkaAudioDecoder *d, int64_t frame) {
    if (d == NULL || frame < 0) return false;
    int64_t from = frame > kSeekPrerollFrames ? frame - kSeekPrerollFrames : 0;
    if (AMediaExtractor_seekTo(d->extractor, from * 1000000 / d->sampleRate, AMEDIAEXTRACTOR_SEEK_PREVIOUS_SYNC) != AMEDIA_OK) {
        return false;
    }
    // The container's time for the packet it landed on is exact, and a
    // decoder flushed there hands out that packet's frame first: what it
    // trims after a flush is what it trimmed at the top of the file, where
    // the count started.
    int64_t landedUs = AMediaExtractor_getSampleTime(d->extractor);
    if (landedUs < 0) return false;
    AMediaCodec_flush(d->codec);
    d->inputDone = false;
    d->outputDone = false;
    d->scratchFrames = 0;
    d->scratchRead = 0;
    d->frame = (landedUs * d->sampleRate + 500000) / 1000000;

    // Count decoded frames off until the frame is reached.
    while (d->frame < frame) {
        if (!decodeMore(d)) return false;
        int64_t skip = frame - d->frame;
        if (skip > d->scratchFrames) skip = d->scratchFrames;
        d->scratchRead = skip;
        d->frame += skip;
    }
    return true;
}

bool ska_audio_seek(SkaAudioDecoder *d, int64_t position_us) {
    if (d == NULL || position_us < 0) return false;
    return ska_audio_seek_frame(d, (position_us * d->sampleRate + 500000) / 1000000);
}

void ska_audio_close(SkaAudioDecoder *d) {
    if (d == NULL) return;
    if (d->codec != NULL) {
        AMediaCodec_stop(d->codec);
        AMediaCodec_delete(d->codec);
    }
    if (d->extractor != NULL) AMediaExtractor_delete(d->extractor);
    if (d->fd >= 0) close(d->fd);
    free(d->scratch);
    free(d);
}
