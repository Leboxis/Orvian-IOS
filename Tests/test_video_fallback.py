"""Nonvisual wiring contracts complement the executable controller/policy checks."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLAYER = (ROOT / "Orvian/Features/Viewer/VideoPlayerView.swift").read_text(encoding="utf-8")
VLC = (ROOT / "Orvian/Features/Viewer/VLCPlaybackController.swift").read_text(encoding="utf-8")


class VideoFallbackTests(unittest.TestCase):
    def test_only_explicit_format_failure_can_select_vlc(self):
        retry = PLAYER.split("private func retryPlaybackAfterProcessingDelay", 1)[1].split(
            "private func rememberRecoveryPosition", 1)[0]
        self.assertEqual(PLAYER.count("requiresVLC = true"), 1)
        for condition in ["player?.currentItem === failedItem", "VideoPlaybackCompatibility.requiresVLC(",
                          "failedItem.error", "failedItem.errorLog()?.events", "asset.url"]:
            self.assertIn(condition, retry)
        self.assertLess(retry.index("teardown("), retry.index("startVLCPlayback("))
        watchdog = PLAYER.split("private func startStallWatchdog", 1)[1].split(
            "private func cancelStallWatchdog", 1)[0]
        self.assertNotIn("startVLCPlayback", watchdog)
        self.assertNotIn("requiresVLC = true", watchdog)

    def test_same_transport_and_lifecycle_own_both_engines(self):
        self.assertIn("player != nil || vlcPlayback != nil", PLAYER)
        teardown = PLAYER.split("private func teardown(", 1)[1].split("// MARK:", 1)[0]
        self.assertIn("vlcPlayback?.stop()", teardown)
        self.assertIn("vlcPlayback = nil", teardown)
        self.assertIn("AudioSessionKeeper.shared.release()", teardown)
        pause = PLAYER.split("private func pausePlayback()", 1)[1].split(
            "private func requestPlayback", 1)[0]
        self.assertIn("vlcPlayback?.pause()", pause)
        self.assertIn("coordinator.stop()", VLC)

    def test_unsupported_apple_integrations_are_not_offered_for_vlc(self):
        self.assertEqual(PLAYER.count(".disabled(vlcPlayback != nil)"), 2)
        self.assertEqual(PLAYER.count(".disabled(vlcPlayback != nil && !preparedSubtitles.isAvailable)"), 2)
        self.assertIn("La transcription en direct n’est pas disponible avec VLC", PLAYER)
        self.assertIn("AirPlay vidéo indisponible", PLAYER)

    def test_hardware_is_preferred_without_conversion(self):
        self.assertIn(':avcodec-hw=any', VLC)
        for forbidden in ["AVAssetExportSession", "ffmpeg", "sout=", "transcode{", ":avcodec-hw=none"]:
            self.assertNotIn(forbidden, VLC)


if __name__ == "__main__":
    unittest.main()
