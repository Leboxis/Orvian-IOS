/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "OrvianAudioDecoder.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

#define OAD_MAX_FRAMES 1000000
#define OAD_MAX_BYTES 32000000
#define OAD_MAX_PACKET_BYTES (16 * 1024 * 1024)
#define OAD_MAX_EXTRADATA_BYTES (1024 * 1024)
#define OAD_IO_BYTES 65536
#define OAD_MAX_STEPS 1000000
/* Keep double-precision timeline arithmetic well below sample resolution. */
#define OAD_MAX_TIME 100000000.0

struct OADCancellation {
    atomic_uint references;
    atomic_int cancelled;
};

typedef struct OADPacketNode {
    AVPacket *packet;
    struct OADPacketNode *next;
} OADPacketNode;

struct OADDecoder {
    OADPacketNode *prefetch;
    OADPacketNode *prefetchTail;
    OADCancellation *cancellation;
    int fd;
    AVIOContext *io;
    AVFormatContext *format;
    AVCodecContext *codec;
    AVPacket *packet;
    AVFrame *frame;
    SwrContext *swr;
    AVChannelLayout inputLayout;
    int inputRate;
    enum AVSampleFormat inputFormat;
    int outputRate;
    int outputChannels;
    int stream;
    int demuxEnd;
    int sentEnd;
    int decoderEnd;
    int packetPending;
    int framePending;
    int gapDrain;
    int haveTimestamp;
    double origin;
    double duration;
    double tick;
    double previousPTS;
    double expectedPTS;
    double inputAnchor;
    int64_t inputFrames;
    double pendingPTS;
    double anchor;
    int64_t outputFrames;
    float *samples;
    unsigned int sampleBytes;
    OADStatus terminal;
};

OADCancellation *OADCancellationCreate(void) {
    OADCancellation *token = calloc(1, sizeof(*token));
    if (token) {
        atomic_init(&token->references, 1);
        atomic_init(&token->cancelled, 0);
    }
    return token;
}

void OADCancellationRetain(OADCancellation *token) {
    if (token) atomic_fetch_add_explicit(&token->references, 1, memory_order_relaxed);
}

void OADCancellationCancel(OADCancellation *token) {
    if (token) atomic_store_explicit(&token->cancelled, 1, memory_order_release);
}

void OADCancellationRelease(OADCancellation *token) {
    if (token && atomic_fetch_sub_explicit(&token->references, 1, memory_order_acq_rel) == 1)
        free(token);
}

static int oad_cancelled(void *opaque) {
    OADDecoder *d = opaque;
    return d->cancellation && atomic_load_explicit(&d->cancellation->cancelled,
                                                  memory_order_acquire);
}

static OADStatus oad_error(OADDecoder *d, int error, OADStatus fallback) {
    if (oad_cancelled(d)) return OADStatusCancelled;
    return error == AVERROR(ENOMEM) ? OADStatusOutOfMemory : fallback;
}

/* Custom AVIO makes the only I/O capability this already-open regular file.
 * Demuxer requests to open playlists, sidecars, keys or URLs are rejected. */
static int oad_no_open(AVFormatContext *context, AVIOContext **io,
                       const char *url, int flags, AVDictionary **options) {
    (void)context; (void)io; (void)url; (void)flags; (void)options;
    return AVERROR(EACCES);
}

static int oad_read_file(void *opaque, uint8_t *buffer, int size) {
    OADDecoder *d = opaque;
    if (size <= 0 || size > OAD_MAX_PACKET_BYTES) return AVERROR(EINVAL);
    for (;;) {
        if (oad_cancelled(d)) return AVERROR_EXIT;
        ssize_t count = read(d->fd, buffer, (size_t)size);
        if (count > 0) return (int)count;
        if (count == 0) return AVERROR_EOF;
        if (errno != EINTR) return AVERROR(errno);
    }
}

static int64_t oad_seek_file(void *opaque, int64_t offset, int whence) {
    OADDecoder *d = opaque;
    if (oad_cancelled(d)) return AVERROR_EXIT;
    if (whence & AVSEEK_SIZE) {
        struct stat st;
        return fstat(d->fd, &st) == 0 ? (int64_t)st.st_size : AVERROR(errno);
    }
    whence &= ~AVSEEK_FORCE;
    if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END)
        return AVERROR(EINVAL);
    off_t result = lseek(d->fd, (off_t)offset, whence);
    return result < 0 ? AVERROR(errno) : (int64_t)result;
}

static void oad_clear_prefetch(OADDecoder *d) {
    while (d->prefetch) {
        OADPacketNode *node = d->prefetch;
        d->prefetch = node->next;
        av_packet_free(&node->packet);
        free(node);
    }
    d->prefetchTail = NULL;
}

static OADStatus oad_packet_bounds(const AVPacket *packet) {
    if (packet->size < 0 || packet->size > OAD_MAX_PACKET_BYTES ||
        packet->side_data_elems < 0 || packet->side_data_elems > 256)
        return OADStatusTooLarge;
    size_t bytes = (size_t)packet->size;
    for (int i = 0; i < packet->side_data_elems; ++i) {
        if (packet->side_data[i].size > OAD_MAX_PACKET_BYTES - bytes)
            return OADStatusTooLarge;
        bytes += packet->side_data[i].size;
    }
    return packet->flags & AV_PKT_FLAG_CORRUPT ? OADStatusInvalidSource : OADStatusOK;
}

/* Header-only formats need no probing. Otherwise discover common A/V origin
 * using packets only, never find_stream_info (which may look up video codecs).
 * Retain audio packets so probing cannot lose priming or the first samples. */
static OADStatus oad_probe_origin(OADDecoder *d) {
    double starts[256];
    for (int i = 0; i < 256; ++i) starts[i] = NAN;
    size_t cachedBytes = 0;
    size_t readBytes = 0;
    double firstTime = NAN;
    double latestTime = NAN;
    int noHeader = !!(d->format->ctx_flags & AVFMTCTX_NOHEADER);
    AVPacket *packet = av_packet_alloc();
    if (!packet) return OADStatusOutOfMemory;
    OADStatus result = OADStatusInvalidTiming;
    for (int step = 0; step < 4096; ++step) {
        if (oad_cancelled(d)) { result = OADStatusCancelled; break; }
        if (d->format->nb_streams > 256) { result = OADStatusTooLarge; break; }
        int missing = 0, audio = 0;
        double minimum = INFINITY;
        for (unsigned int i = 0; i < d->format->nb_streams; ++i) {
            AVStream *s = d->format->streams[i];
            if (s->codecpar->extradata_size < 0 ||
                s->codecpar->extradata_size > OAD_MAX_EXTRADATA_BYTES) {
                result = OADStatusTooLarge; goto done;
            }
            if (s->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) ++audio;
            if ((s->codecpar->codec_type != AVMEDIA_TYPE_AUDIO &&
                 s->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) ||
                (s->disposition & AV_DISPOSITION_ATTACHED_PIC)) continue;
            if (s->time_base.num <= 0 || s->time_base.den <= 0) { ++missing; continue; }
            if (s->start_time != AV_NOPTS_VALUE)
                starts[i] = s->start_time * av_q2d(s->time_base);
            if (isfinite(starts[i])) minimum = fmin(minimum, starts[i]);
            else ++missing;
        }
        if (audio > 1) { result = OADStatusMultipleAudio; break; }
        if (d->format->start_time != AV_NOPTS_VALUE)
            minimum = (double)d->format->start_time / AV_TIME_BASE;
        if (audio && isfinite(minimum) && !missing &&
            (!noHeader || (isfinite(firstTime) && latestTime - firstTime >= 5.0))) {
            d->origin = minimum;
            result = OADStatusOK;
            break;
        }
        if (readBytes >= 8 * 1024 * 1024) {
            /* No-header discovery is intentionally bounded, not exhaustive. */
            if (audio && !missing && isfinite(minimum)) {
                d->origin = minimum;
                result = OADStatusOK;
            } else result = audio ? OADStatusInvalidTiming : OADStatusNoAudio;
            break;
        }
        int error = av_read_frame(d->format, packet);
        if (error == AVERROR_EOF) {
            if (d->io->error && d->io->error != AVERROR_EOF)
                result = oad_error(d, d->io->error, OADStatusInvalidSource);
            else if (audio && !missing && isfinite(minimum)) {
                d->origin = minimum;
                result = OADStatusOK;
            } else result = audio ? OADStatusInvalidTiming : OADStatusNoAudio;
            break;
        }
        if (error < 0) { result = oad_error(d, error, OADStatusInvalidSource); break; }
        result = oad_packet_bounds(packet);
        if (result != OADStatusOK) break;
        result = OADStatusInvalidTiming;
        if (packet->stream_index < 0 || packet->stream_index >= 256 ||
            (unsigned int)packet->stream_index >= d->format->nb_streams) break;
        AVStream *s = d->format->streams[packet->stream_index];
        if (packet->pts != AV_NOPTS_VALUE && s->time_base.num > 0 && s->time_base.den > 0) {
            double time = packet->pts * av_q2d(s->time_base);
            if (isfinite(time)) {
                if (!isfinite(starts[packet->stream_index])) starts[packet->stream_index] = time;
                if (!isfinite(firstTime)) firstTime = time;
                latestTime = time;
            }
        }
        readBytes += (size_t)packet->size;
        if (s->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            size_t bytes = (size_t)packet->size;
            for (int i = 0; i < packet->side_data_elems; ++i) bytes += packet->side_data[i].size;
            if (bytes > 8 * 1024 * 1024 - cachedBytes) { result = OADStatusTooLarge; break; }
            cachedBytes += bytes;
            OADPacketNode *node = calloc(1, sizeof(*node));
            if (!node) { result = OADStatusOutOfMemory; break; }
            node->packet = av_packet_alloc();
            if (!node->packet) { free(node); result = OADStatusOutOfMemory; break; }
            av_packet_move_ref(node->packet, packet);
            if (d->prefetchTail) d->prefetchTail->next = node;
            else d->prefetch = node;
            d->prefetchTail = node;
        }
        av_packet_unref(packet);
    }
done:
    av_packet_free(&packet);
    return result;
}

void OADClose(OADDecoder *d) {
    if (!d) return;
    oad_clear_prefetch(d);
    swr_free(&d->swr);
    av_channel_layout_uninit(&d->inputLayout);
    av_frame_free(&d->frame);
    av_packet_free(&d->packet);
    avcodec_free_context(&d->codec);
    avformat_close_input(&d->format);
    if (d->io) {
        av_freep(&d->io->buffer);
        avio_context_free(&d->io);
    }
    if (d->fd >= 0) close(d->fd);
    av_free(d->samples);
    OADCancellationRelease(d->cancellation);
    free(d);
}

OADDecoder *OADOpen(const char *path, int32_t rate, int32_t channels,
                    OADCancellation *token, OADStatus *status) {
    OADStatus result = OADStatusInvalidSource;
    OADDecoder *d = NULL;
    AVDictionary *options = NULL;
    if (status) *status = result;
    if (!path || path[0] != '/' || path[1] == '/' ||
        rate < 16000 || rate > 192000 || channels < 1 || channels > 8)
        return NULL;
    d = calloc(1, sizeof(*d));
    if (!d) { if (status) *status = OADStatusOutOfMemory; return NULL; }
    d->fd = -1;
    d->stream = -1;
    d->duration = -1;
    d->outputRate = rate;
    d->outputChannels = channels;
    d->cancellation = token;
    OADCancellationRetain(token);
    if (oad_cancelled(d)) { result = OADStatusCancelled; goto fail; }
    /* O_NONBLOCK prevents a malicious FIFO path from blocking before fstat. */
    d->fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (d->fd < 0) goto fail;
    struct stat st;
    if (fstat(d->fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0) goto fail;
    uint8_t *buffer = av_malloc(OAD_IO_BYTES);
    if (!buffer) { result = OADStatusOutOfMemory; goto fail; }
    d->io = avio_alloc_context(buffer, OAD_IO_BYTES, 0, d, oad_read_file, NULL, oad_seek_file);
    if (!d->io) { av_free(buffer); result = OADStatusOutOfMemory; goto fail; }
    d->format = avformat_alloc_context();
    if (!d->format) { result = OADStatusOutOfMemory; goto fail; }
    d->format->pb = d->io;
    d->format->flags |= AVFMT_FLAG_CUSTOM_IO;
    d->format->interrupt_callback = (AVIOInterruptCB){oad_cancelled, d};
    d->format->io_open = oad_no_open;
    d->format->max_streams = 256;
    d->format->probesize = 8 * 1024 * 1024;
    d->format->format_probesize = OAD_MAX_EXTRADATA_BYTES;
    d->format->max_probe_packets = 4096;
    /* Keep parser timestamp interpolation: MPEG PES packets can contain several
     * audio frames with only one explicit PTS. Never invent a new zero origin. */
    d->format->max_analyze_duration = 5 * AV_TIME_BASE;
    int error = av_dict_set(&options, "protocol_whitelist", "file", 0);
    if (error < 0) { result = oad_error(d, error, result); goto fail; }
    error = avformat_open_input(&d->format, path, NULL, &options);
    av_dict_free(&options);
    if (error < 0) { result = oad_error(d, error, result); goto fail; }
    result = oad_probe_origin(d);
    if (result != OADStatusOK) goto fail;
    result = OADStatusInvalidSource;
    for (unsigned int i = 0; i < d->format->nb_streams; ++i) {
        AVStream *stream = d->format->streams[i];
        stream->discard = AVDISCARD_ALL;
        if (stream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        if (d->stream >= 0) { result = OADStatusMultipleAudio; goto fail; }
        d->stream = (int)i;
    }
    if (d->stream < 0) { result = OADStatusNoAudio; goto fail; }
    AVStream *stream = d->format->streams[d->stream];
    stream->discard = AVDISCARD_DEFAULT;
    if (stream->time_base.num <= 0 || stream->time_base.den <= 0) {
        result = OADStatusInvalidTiming; goto fail;
    }
    d->tick = av_q2d(stream->time_base);
    if (!isfinite(d->tick) || d->tick <= 0) { result = OADStatusInvalidTiming; goto fail; }
    if (d->format->start_time != AV_NOPTS_VALUE)
        d->origin = (double)d->format->start_time / AV_TIME_BASE;
    if (!isfinite(d->origin) || fabs(d->origin) > OAD_MAX_TIME) {
        result = OADStatusInvalidTiming; goto fail;
    }
    if (d->format->duration != AV_NOPTS_VALUE && d->format->duration >= 0)
        d->duration = (double)d->format->duration / AV_TIME_BASE;
    else if (stream->duration != AV_NOPTS_VALUE && stream->duration >= 0) {
        double start = stream->start_time == AV_NOPTS_VALUE ? d->origin :
                       stream->start_time * d->tick;
        d->duration = start - d->origin + stream->duration * d->tick;
    }
    if (!isfinite(d->duration) || d->duration > OAD_MAX_TIME) {
        result = OADStatusTooLarge; goto fail;
    }
    if (stream->codecpar->ch_layout.nb_channels < 0 ||
        stream->codecpar->ch_layout.nb_channels > 64 ||
        stream->codecpar->sample_rate < 0 || stream->codecpar->sample_rate > 768000) {
        result = OADStatusUnsupportedAudio; goto fail;
    }
    if (stream->codecpar->extradata_size < 0 ||
        stream->codecpar->extradata_size > OAD_MAX_EXTRADATA_BYTES) {
        result = OADStatusTooLarge; goto fail;
    }
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec || codec->type != AVMEDIA_TYPE_AUDIO) {
        result = OADStatusUnsupportedAudio; goto fail;
    }
    d->codec = avcodec_alloc_context3(codec);
    if (!d->codec) { result = OADStatusOutOfMemory; goto fail; }
    error = avcodec_parameters_to_context(d->codec, stream->codecpar);
    if (error < 0) { result = oad_error(d, error, OADStatusUnsupportedAudio); goto fail; }
    d->codec->pkt_timebase = stream->time_base;
    d->codec->thread_count = 1;
    d->codec->max_samples = OAD_MAX_FRAMES;
    d->codec->err_recognition = AV_EF_CRCCHECK | AV_EF_CAREFUL | AV_EF_EXPLODE;
    error = avcodec_open2(d->codec, codec, NULL);
    if (error < 0) { result = oad_error(d, error, OADStatusUnsupportedAudio); goto fail; }
    d->packet = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->packet || !d->frame) { result = OADStatusOutOfMemory; goto fail; }
    if (oad_cancelled(d)) { result = OADStatusCancelled; goto fail; }
    if (status) *status = OADStatusOK;
    return d;
fail:
    av_dict_free(&options);
    if (oad_cancelled(d)) result = OADStatusCancelled;
    OADClose(d);
    if (status) *status = result;
    return NULL;
}

static OADStatus oad_prepare_frame(OADDecoder *d) {
    AVFrame *f = d->frame;
    if (f->flags & AV_FRAME_FLAG_CORRUPT) return OADStatusInvalidSource;
    if (f->nb_samples <= 0 || f->sample_rate <= 0 ||
        !av_channel_layout_check(&f->ch_layout)) return OADStatusUnsupportedAudio;
    int bytes = av_get_bytes_per_sample(f->format);
    if (f->nb_samples > OAD_MAX_FRAMES || f->ch_layout.nb_channels > 64 ||
        bytes <= 0 || (int64_t)f->nb_samples * f->ch_layout.nb_channels * bytes > OAD_MAX_BYTES)
        return OADStatusTooLarge;
    if (!f->extended_data) return OADStatusInvalidSource;
    int planes = av_sample_fmt_is_planar(f->format) ? f->ch_layout.nb_channels : 1;
    for (int i = 0; i < planes; ++i)
        if (!f->extended_data[i]) return OADStatusInvalidSource;
    int64_t pts = f->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) pts = f->pts;
    if (pts == AV_NOPTS_VALUE && !d->haveTimestamp) return OADStatusInvalidTiming;
    if (d->haveTimestamp && d->inputRate != f->sample_rate) return OADStatusUnsupportedAudio;
    /* MPEG PES may timestamp only the first of several decoded audio frames.
     * Infer untimed frames from the last explicit input anchor, never media zero
     * or the delayed resampler output clock. Explicit timestamps still win. */
    double time = pts == AV_NOPTS_VALUE
        ? d->inputAnchor + (double)d->inputFrames / f->sample_rate
        : pts * d->tick - d->origin;
    if (!isfinite(time) || fabs(time) > OAD_MAX_TIME) return OADStatusInvalidTiming;
    double tolerance = d->tick + 1e-9;
    if (d->haveTimestamp && (time < d->previousPTS - tolerance ||
                            time < d->expectedPTS - tolerance))
        return OADStatusInvalidTiming;
    if (!d->swr) {
        AVChannelLayout output = {0};
        av_channel_layout_default(&output, d->outputChannels);
        int error = swr_alloc_set_opts2(&d->swr, &output, AV_SAMPLE_FMT_FLT, d->outputRate,
                                       &f->ch_layout, f->format, f->sample_rate, 0, NULL);
        av_channel_layout_uninit(&output);
        if (error < 0) return oad_error(d, error, OADStatusUnsupportedAudio);
        error = av_channel_layout_copy(&d->inputLayout, &f->ch_layout);
        if (error < 0) return oad_error(d, error, OADStatusUnsupportedAudio);
        d->inputRate = f->sample_rate;
        d->inputFormat = f->format;
        error = swr_init(d->swr);
        if (error < 0) return oad_error(d, error, OADStatusUnsupportedAudio);
        d->anchor = time;
        d->outputFrames = 0;
    } else if (d->inputRate != f->sample_rate || d->inputFormat != f->format ||
               av_channel_layout_compare(&d->inputLayout, &f->ch_layout) != 0) {
        return OADStatusUnsupportedAudio;
    }
    d->gapDrain = d->haveTimestamp && time > d->expectedPTS + tolerance;
    d->pendingPTS = time;
    d->previousPTS = time;
    if (pts != AV_NOPTS_VALUE) { d->inputAnchor = time; d->inputFrames = 0; }
    if (d->inputFrames > INT64_MAX - f->nb_samples) return OADStatusTooLarge;
    d->inputFrames += f->nb_samples;
    d->expectedPTS = d->inputAnchor + (double)d->inputFrames / f->sample_rate;
    d->haveTimestamp = 1;
    d->framePending = 1;
    return OADStatusOK;
}

/* Cursor denotes samples emitted, not input submitted: swr's internal delay
 * remains on the old segment until fully drained, including at a source gap. */
static OADStatus oad_convert(OADDecoder *d, int drain, OADAudioBlock *block) {
    int inputFrames = drain ? 0 : d->frame->nb_samples;
    int64_t delay = swr_get_delay(d->swr, d->inputRate);
    if (delay < 0 || delay > OAD_MAX_FRAMES) return OADStatusTooLarge;
    int64_t capacity = av_rescale_rnd(delay + inputFrames, d->outputRate,
                                     d->inputRate, AV_ROUND_UP) + 32;
    if (capacity <= 0 || capacity > OAD_MAX_FRAMES ||
        capacity * d->outputChannels * (int64_t)sizeof(float) > OAD_MAX_BYTES)
        return OADStatusTooLarge;
    size_t bytes = (size_t)capacity * d->outputChannels * sizeof(float);
    /* av_fast_malloc frees its previous allocation on failure. */
    av_fast_malloc(&d->samples, &d->sampleBytes, bytes);
    if (!d->samples) return OADStatusOutOfMemory;
    uint8_t *output[] = {(uint8_t *)d->samples};
    const uint8_t **input = drain ? NULL : (const uint8_t **)d->frame->extended_data;
    int count = swr_convert(d->swr, output, (int)capacity, input, inputFrames);
    if (count < 0) return oad_error(d, count, OADStatusInvalidSource);
    if (count == 0) return OADStatusEnd;
    if (d->outputFrames > INT64_MAX - count) return OADStatusTooLarge;
    double start = d->anchor + (double)d->outputFrames / d->outputRate;
    d->outputFrames += count;
    int skip = 0;
    if (start < 0) {
        double preroll = ceil(-start * d->outputRate - 1e-7);
        skip = preroll >= count ? count : (int)preroll;
    }
    if (skip == count) return OADStatusOK;
    block->samples = d->samples + (size_t)skip * d->outputChannels;
    block->frameCount = count - skip;
    block->sampleRate = d->outputRate;
    block->channelCount = d->outputChannels;
    block->segmentStartTime = d->anchor;
    block->frameOffset = d->outputFrames - count + skip;
    block->startTime = d->anchor + (double)block->frameOffset / d->outputRate;
    if (block->startTime < 0 && block->startTime > -1e-9) block->startTime = 0;
    return OADStatusOK;
}

OADStatus OADRead(OADDecoder *d, OADAudioBlock *block) {
    if (!block) return OADStatusInvalidSource;
    memset(block, 0, sizeof(*block));
    if (!d) return OADStatusInvalidSource;
    if (oad_cancelled(d)) return d->terminal = OADStatusCancelled;
    if (d->terminal != OADStatusOK) return d->terminal;
    OADStatus result = OADStatusInvalidSource;
    /* Finite progress budget covers streams filled with irrelevant packets,
     * broken demuxers, empty frames, and illegal send/receive EAGAIN cycles. */
    for (int step = 0; step < OAD_MAX_STEPS; ++step) {
        if (oad_cancelled(d)) { result = OADStatusCancelled; break; }
        if (d->gapDrain || d->decoderEnd) {
            result = d->swr ? oad_convert(d, 1, block) : OADStatusEnd;
            if (result == OADStatusOK) {
                if (block->frameCount) return result;
                continue;
            }
            if (result != OADStatusEnd) break;
            if (d->decoderEnd) break;
            swr_close(d->swr);
            int error = swr_init(d->swr);
            if (error < 0) { result = oad_error(d, error, OADStatusUnsupportedAudio); break; }
            d->anchor = d->pendingPTS;
            d->outputFrames = 0;
            d->gapDrain = 0;
        }
        if (d->framePending) {
            result = oad_convert(d, 0, block);
            av_frame_unref(d->frame);
            d->framePending = 0;
            if (result != OADStatusOK && result != OADStatusEnd) break;
            if (block->frameCount) return OADStatusOK;
            continue;
        }
        int error = avcodec_receive_frame(d->codec, d->frame);
        if (error == 0) {
            result = oad_prepare_frame(d);
            if (result != OADStatusOK) break;
            continue;
        }
        if (error == AVERROR_EOF) { d->decoderEnd = 1; continue; }
        if (error != AVERROR(EAGAIN)) { result = oad_error(d, error, OADStatusInvalidSource); break; }
        if (d->sentEnd) { result = OADStatusInvalidSource; break; }
        if (d->packetPending || d->demuxEnd) {
            error = avcodec_send_packet(d->codec, d->packetPending ? d->packet : NULL);
            /* receive EAGAIN immediately followed by send EAGAIN violates the
             * codec API progress guarantee; never spin retrying the pair. */
            if (error < 0) { result = oad_error(d, error, OADStatusInvalidSource); break; }
            if (d->packetPending) {
                av_packet_unref(d->packet);
                d->packetPending = 0;
            } else d->sentEnd = 1;
            continue;
        }
        if (d->prefetch) {
            OADPacketNode *node = d->prefetch;
            d->prefetch = node->next;
            if (!d->prefetch) d->prefetchTail = NULL;
            av_packet_move_ref(d->packet, node->packet);
            av_packet_free(&node->packet);
            free(node);
            error = 0;
        } else error = av_read_frame(d->format, d->packet);
        if (error == AVERROR_EOF) {
            if (d->io->error && d->io->error != AVERROR_EOF) {
                result = oad_error(d, d->io->error, OADStatusInvalidSource); break;
            }
            d->demuxEnd = 1;
            continue;
        }
        if (error < 0) { result = oad_error(d, error, OADStatusInvalidSource); break; }
        /* A demuxer that discovers a new audio track during reading cannot
         * silently weaken the single-track contract. */
        for (unsigned int i = 0; i < d->format->nb_streams; ++i) {
            if ((int)i != d->stream &&
                d->format->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
                result = OADStatusMultipleAudio;
                goto done;
            }
        }
        result = oad_packet_bounds(d->packet);
        if (result != OADStatusOK) break;
        if (d->packet->stream_index != d->stream) {
            av_packet_unref(d->packet);
            continue;
        }
        d->packetPending = 1;
    }
done:
    if (result == OADStatusOK) result = OADStatusInvalidSource;
    if (oad_cancelled(d)) result = OADStatusCancelled;
    memset(block, 0, sizeof(*block));
    d->terminal = result;
    return result;
}

OADStatus OADSeek(OADDecoder *d, double mediaTime) {
    if (!d) return OADStatusInvalidSource;
    if (oad_cancelled(d)) return d->terminal = OADStatusCancelled;
    if (!isfinite(mediaTime) || mediaTime < 0 || mediaTime > OAD_MAX_TIME)
        return d->terminal = OADStatusInvalidTiming;
    if (d->terminal != OADStatusOK && d->terminal != OADStatusEnd) return d->terminal;
    long double target = ((long double)mediaTime + d->origin) / d->tick;
    if (target <= INT64_MIN || target >= INT64_MAX)
        return d->terminal = OADStatusInvalidTiming;
    int64_t timestamp = (int64_t)floorl(target);
    int error = avformat_seek_file(d->format, d->stream, INT64_MIN, timestamp,
                                  timestamp, 0);
    if (error < 0) return d->terminal = oad_error(d, error, OADStatusInvalidSource);
    oad_clear_prefetch(d);
    avcodec_flush_buffers(d->codec);
    av_packet_unref(d->packet);
    av_frame_unref(d->frame);
    swr_free(&d->swr);
    av_channel_layout_uninit(&d->inputLayout);
    d->demuxEnd = d->sentEnd = d->decoderEnd = 0;
    d->packetPending = d->framePending = d->gapDrain = d->haveTimestamp = 0;
    d->outputFrames = 0;
    d->inputAnchor = 0;
    d->inputFrames = 0;
    d->terminal = OADStatusOK;
    return oad_cancelled(d) ? (d->terminal = OADStatusCancelled) : OADStatusOK;
}

double OADDuration(OADDecoder *d) {
    return d ? d->duration : -1.0;
}

const char *OADVersion(void) {
    return "OrvianAudioDecoder/2 " LIBAVFORMAT_IDENT;
}
