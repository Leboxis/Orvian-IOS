"""Exercise the native input-clock policy without linking Apple/FFmpeg SDKs.

The tested block is copied verbatim from the production frame timing boundary;
codec I/O and resampling remain covered by the hosted iOS decoder tests.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PreparedMPEGTimingTests(unittest.TestCase):
    def test_mpeg_frame_without_pts_continues_from_known_audio_anchor(self):
        compiler = shutil.which("clang")
        if not compiler:
            self.skipTest("C compiler unavailable")
        native = (ROOT / "Native/PreparedAudio/OrvianAudioDecoder.c").read_text(encoding="utf-8")
        policy = "    int64_t pts =" + native.split("    int64_t pts =", 1)[1].split("    if (!d->swr)", 1)[0]
        harness = r'''
#include <stdint.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include "OrvianAudioDecoder.h"
#define AV_NOPTS_VALUE INT64_MIN
#define OAD_MAX_TIME 100000000.0
struct Frame { int64_t best_effort_timestamp, pts; int sample_rate; };
struct Clock {
    int haveTimestamp, inputRate;
    double tick, origin, previousPTS, expectedPTS, inputAnchor;
    int64_t inputFrames;
};
static OADStatus frame_time(struct Clock *d, struct Frame *f, double *result) {
POLICY
    *result = time;
    return OADStatusOK;
}
#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "%s\n", message); return 1; } } while (0)
int main(void) {
    struct Clock clock = {0};
    clock.tick = 1.0 / 90000; clock.inputRate = 48000;
    struct Frame frame = {AV_NOPTS_VALUE, AV_NOPTS_VALUE, 48000};
    double time = -1;
    CHECK(frame_time(&clock, &frame, &time) == OADStatusInvalidTiming, "Never invent an initial anchor");
    clock.haveTimestamp = 1; clock.previousPTS = 1.5;
    clock.inputAnchor = 1.5; clock.inputFrames = 1152; clock.expectedPTS = 1.524;
    CHECK(frame_time(&clock, &frame, &time) == OADStatusOK, "Valid MPEG audio frame without its own PTS was rejected");
    CHECK(fabs(time - 1.524) < 1e-12, "Missing MPEG PTS lost the initial delay");
    clock.inputFrames = 2304; clock.expectedPTS = 1.548;
    CHECK(frame_time(&clock, &frame, &time) == OADStatusOK && fabs(time - 1.548) < 1e-12, "Consecutive missing PTS drifted");
    clock.inputFrames = 11520000; clock.expectedPTS = 241.5;
    CHECK(frame_time(&clock, &frame, &time) == OADStatusOK && fabs(time - 241.5) < 1e-12, "Long missing-PTS run must use sample counts");
    clock.inputFrames = 1152; clock.expectedPTS = 1.524;
    frame.best_effort_timestamp = 90000; frame.pts = 90000;
    CHECK(frame_time(&clock, &frame, &time) == OADStatusInvalidTiming, "Explicit backwards PTS must still fail");
    frame.best_effort_timestamp = 270000; frame.pts = 270000;
    CHECK(frame_time(&clock, &frame, &time) == OADStatusOK && fabs(time - 3.0) < 1e-12, "Explicit audio gap must be preserved");
    frame.best_effort_timestamp = AV_NOPTS_VALUE; frame.pts = AV_NOPTS_VALUE; frame.sample_rate = 44100;
    CHECK(frame_time(&clock, &frame, &time) != OADStatusOK, "Changed input rate cannot inherit the old sample clock");
    puts("MPEG missing-PTS, initial anchor, gaps and backwards-PTS checks passed");
    return 0;
}
'''.replace("POLICY", policy)
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "mpeg-timing.c"
            source.write_text(harness, encoding="utf-8")
            executable = Path(temporary) / ("mpeg-timing.exe" if os.name == "nt" else "mpeg-timing")
            command = [compiler, "-std=c11", "-I", str(ROOT / "Native/PreparedAudio"), str(source), "-o", str(executable)]
            if os.name != "nt":
                command.append("-lm")
            subprocess.run(command, check=True, timeout=120)
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    unittest.main()
