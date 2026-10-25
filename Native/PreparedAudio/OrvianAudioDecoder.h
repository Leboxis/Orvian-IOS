/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef ORVIAN_AUDIO_DECODER_H
#define ORVIAN_AUDIO_DECODER_H

#include <stdint.h>

#if defined(__GNUC__)
#define OAD_EXPORT __attribute__((visibility("default")))
#else
#define OAD_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OADDecoder OADDecoder;
typedef struct OADCancellation OADCancellation;

typedef enum OADStatus {
    OADStatusOK = 0,
    OADStatusEnd = 1,
    OADStatusCancelled = -1,
    OADStatusInvalidSource = -2,
    OADStatusNoAudio = -3,
    OADStatusMultipleAudio = -4,
    OADStatusUnsupportedAudio = -5,
    OADStatusInvalidTiming = -6,
    OADStatusTooLarge = -7,
    OADStatusOutOfMemory = -8
} OADStatus;

typedef struct OADAudioBlock {
    const float *samples;
    int32_t frameCount;
    int32_t sampleRate;
    int32_t channelCount;
    double startTime;
    /* Exact within a resampling segment: start = segmentStartTime +
     * frameOffset/sampleRate. Keep the integer offset across the Swift bridge. */
    double segmentStartTime;
    int64_t frameOffset;
} OADAudioBlock;

/* Each concurrent token user must own a reference, including a cancellation
 * handler. Retaining requires an already-live reference. NULL is accepted. */
OAD_EXPORT OADCancellation *OADCancellationCreate(void);
OAD_EXPORT void OADCancellationRetain(OADCancellation *cancellation);
OAD_EXPORT void OADCancellationCancel(OADCancellation *cancellation);
OAD_EXPORT void OADCancellationRelease(OADCancellation *cancellation);

/* Decoder operations (including close) require one owning serial queue.
 * Open retains cancellation. Only Cancel/Retain/Release are thread-safe.
 * Path must be an absolute local regular-file path, not a URL.
 * Output: interleaved Float32, 16000...192000 Hz, 1...8 channels. */
OAD_EXPORT OADDecoder *OADOpen(const char *absoluteLocalPath,
                             int32_t outputSampleRate,
                             int32_t outputChannels,
                             OADCancellation *cancellation,
                             OADStatus *status);
/* Seconds on the common container media timeline; negative means unknown. */
OAD_EXPORT double OADDuration(OADDecoder *decoder);
/* startTime = source PTS - container start_time (zero if unspecified), with
 * resampling delay accounted for. Initial audio delay and gaps are preserved;
 * PCM before media zero is clipped. Missing PTS after an explicit anchor follow
 * the decoded input sample count; missing initial/backwards PTS fail closed.
 * Samples remain valid only until the next Read, Seek, or Close. Empty output
 * is never returned with OK. At most 1,000,000 frames / 32,000,000 bytes. */
OAD_EXPORT OADStatus OADRead(OADDecoder *decoder, OADAudioBlock *block);
/* May return audio before mediaTime; the caller trims to its requested range.
 * A failed seek makes the decoder terminal. Cancellation cannot be reset. */
OAD_EXPORT OADStatus OADSeek(OADDecoder *decoder, double mediaTime);
OAD_EXPORT void OADClose(OADDecoder *decoder);
OAD_EXPORT const char *OADVersion(void);

#ifdef __cplusplus
}
#endif
#endif
