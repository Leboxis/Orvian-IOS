"""Build/activation separation contracts, not proof of PCM or device rendering."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SpeechProbeDeliveryTests(unittest.TestCase):
    def test_subtitle_engine_ships_in_release(self):
        """Le prototype est devenu une fonctionnalité : plus de garde de compilation."""
        for relative in [
            "Orvian/Core/Media/PlayerSpeechAudioTap.swift",
            "Orvian/Core/Media/SpeechProbeMailbox.swift",
            "Orvian/Core/Media/SpeechProbeWorker.swift",
            "Orvian/Features/Viewer/VideoSpeechProbe.swift",
            "Orvian/Core/Media/SubtitleCue.swift",
            "Orvian/Core/Media/SubtitleTranslator.swift",
            "Orvian/UI/SubtitleOverlay.swift",
        ]:
            with self.subTest(path=relative):
                source = (ROOT / relative).read_text(encoding="utf-8")
                self.assertFalse(source.lstrip().startswith("#if"),
                                 "A shipped subtitle source must not be compiled out")
        player = (ROOT / "Orvian/Features/Viewer/VideoPlayerView.swift").read_text(encoding="utf-8")
        self.assertIn("SubtitleOverlay(", player)
        self.assertIn("SubtitleModeMenu(", player)

    def test_diagnostic_panel_stays_out_of_the_product_ui(self):
        player = (ROOT / "Orvian/Features/Viewer/VideoPlayerView.swift").read_text(encoding="utf-8")
        panel = player.split("VideoSpeechProbePanel(", 1)[0].rsplit("#if", 1)[-1]
        self.assertIn("DEBUG", panel, "The diagnostic panel is a development tool only")
        source = (ROOT / "Orvian/Features/Viewer/VideoSpeechProbe.swift").read_text(encoding="utf-8")
        exposure = source.split("static var isExposed: Bool {", 1)[1].split("private(set)", 1)[0]
        self.assertIn('environment["ORVIAN_SPEECH_PROBE"]', exposure)
        self.assertIn('arguments.contains("-OrvianSpeechProbe")', exposure)

    def test_workflow_dispatch_isolated_from_stable_publisher(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")
        stable, diagnostic = workflow.split("\n  speech-probe:\n", 1)
        self.assertIn("if: ${{ !startsWith(github.ref, 'refs/heads/diagnostics/speech-probe') }}", stable)
        self.assertIn("github.event_name == 'workflow_dispatch' && startsWith(github.ref, 'refs/heads/diagnostics/speech-probe')", diagnostic)
        self.assertNotIn("needs:", diagnostic)
        self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ORVIAN_SPEECH_PROBE", diagnostic)
        self.assertNotIn("ORVIAN_SPEECH_PROBE", stable)
        for forbidden in ["update_repo.py", "repo.json", "git push", "-configuration Debug"]:
            self.assertNotIn(forbidden, diagnostic)

    def test_packaged_app_and_release_have_separate_identity(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")
        diagnostic = workflow.split("\n  speech-probe:\n", 1)[1]
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=com.orvian.app.speechprobe", diagnostic)
        self.assertIn("INFOPLIST_KEY_CFBundleDisplayName=Orvian Test IA", diagnostic)
        self.assertIn("Print :CFBundleIdentifier", diagnostic)
        self.assertIn("Print :CFBundleDisplayName", diagnostic)
        self.assertIn("Orvian-Test-IA-${GITHUB_SHA:0:8}-unsigned.ipa", diagnostic)
        self.assertIn('--target "$GITHUB_SHA"', diagnostic)
        self.assertIn("--prerelease --latest=false", diagnostic)
        self.assertIn("GITHUB_RUN_ATTEMPT", diagnostic)
        self.assertIn("GH_TOKEN: ${{ github.token }}", diagnostic)

    def test_diagnostic_job_does_not_launch_app_or_capture_ui(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")
        diagnostic = workflow.split("\n  speech-probe:\n", 1)[1]
        for forbidden in ["simctl", "screencapture", "test-without-building", "-destination 'platform=iOS Simulator"]:
            self.assertNotIn(forbidden, diagnostic)
        self.assertIn("-destination 'generic/platform=iOS'", diagnostic)
        self.assertIn('build 2>&1 | tee "$RUNNER_TEMP/orvian-speech-probe-build.log"', diagnostic)

    def test_first_pcm_is_not_dropped_for_missing_media_timing(self):
        timeline = (ROOT / "Orvian/Core/Media/SpeechProbeMailbox.swift").read_text(encoding="utf-8")
        accept = timeline.split("mutating func accept(", 1)[1].split("mutating func advance", 1)[0]
        self.assertIn("guard start.isFinite else", accept)
        self.assertIn("hasCompleteTiming = false", accept)
        self.assertIn("return .continuous", accept)
        worker = (ROOT / "Orvian/Core/Media/SpeechProbeWorker.swift").read_text(encoding="utf-8")
        self.assertNotIn("guard timeline.accept", worker, "A missing timestamp must not abort the test")
        self.assertIn("if acceptance == .restart", worker)
        self.assertIn("receivedBuffers += 1", worker)

    def test_probe_reports_playback_and_separates_received_from_analyzed(self):
        source = (ROOT / "Orvian/Features/Viewer/VideoSpeechProbe.swift").read_text(encoding="utf-8")
        self.assertIn("playbackDiagnostic", source)
        self.assertIn("analyzedBuffers", source)
        self.assertIn("restoreAfterTapChange", source)
        self.assertIn("wantsPlaybackValue", source)
        self.assertIn("if wasWanted, wantsPlayback() { restoreAfterTapChange?() }", source)
        self.assertNotIn("player.play()", source, "The probe must never force playback")

    def test_transient_inactive_state_does_not_end_the_test(self):
        player = (ROOT / "Orvian/Features/Viewer/VideoPlayerView.swift").read_text(encoding="utf-8")
        scene = player.split(".onChange(of: scenePhase)", 1)[1].split(".onChange(of: voiceOverEnabled)", 1)[0]
        self.assertIn('if phase == .background { speechProbe.stop(', scene)
        self.assertNotIn("phase != .active", scene,
                         "A notification or Control Center makes scenePhase inactive for a moment")
        probe = (ROOT / "Orvian/Features/Viewer/VideoSpeechProbe.swift").read_text(encoding="utf-8")
        stop = probe.split("func stop(reason", 1)[1].split("private func describePlayback", 1)[0]
        self.assertNotIn('transcript = ""', stop, "Keep the last recognized text for diagnosis")

    def test_speech_backpressure_waits_instead_of_ending_the_test(self):
        worker = (ROOT / "Orvian/Core/Media/SpeechProbeWorker.swift").read_text(encoding="utf-8")
        self.assertIn("yieldWithBackpressure", worker)
        self.assertNotIn("case .dropped: throw SpeechProbeError.backpressure", worker,
                         "A full queue must be retried, not treated as a fatal error")
        self.assertIn("if ContinuousClock.now >= deadline { throw SpeechProbeError.backpressure }", worker)

    def test_speech_results_are_counted_even_without_text(self):
        worker = (ROOT / "Orvian/Core/Media/SpeechProbeWorker.swift").read_text(encoding="utf-8")
        self.assertIn("resultCount += 1", worker)
        self.assertIn("textCount += 1", worker)
        probe = (ROOT / "Orvian/Features/Viewer/VideoSpeechProbe.swift").read_text(encoding="utf-8")
        self.assertIn("speechResults", probe)
        self.assertIn("speechTextResults", probe)
        self.assertIn("résultats \\(probe.speechResults)", probe)

    def test_speech_input_queue_survives_model_startup(self):
        worker = (ROOT / "Orvian/Core/Media/SpeechProbeWorker.swift").read_text(encoding="utf-8")
        self.assertIn(".bufferingOldest(64)", worker,
                      "Eight buffers ended the test before the model produced anything")
        self.assertNotIn(".bufferingOldest(8)", worker)

    def test_tap_stream_restart_does_not_discard_remaining_audio(self):
        worker = (ROOT / "Orvian/Core/Media/SpeechProbeWorker.swift").read_text(encoding="utf-8")
        self.assertNotIn("throw SpeechProbeError.streamRestart", worker)
        self.assertIn("timeline.restart()", worker)
        timeline = (ROOT / "Orvian/Core/Media/SpeechProbeMailbox.swift").read_text(encoding="utf-8")
        self.assertIn("mutating func restart()", timeline)


if __name__ == "__main__":
    unittest.main()
