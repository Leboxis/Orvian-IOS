"""Wiring contracts for quiet preparation and engine-independent prepared captions."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class SubtitleVideoCompatibilityTests(unittest.TestCase):
    def test_prepared_captions_survive_vlc_and_follow_its_media_clock(self):
        player = source("Orvian/Features/Viewer/VideoPlayerView.swift")
        start = player.split("private func startVLCPlayback(", 1)[1].split("private func startPlayback(", 1)[0]
        self.assertNotIn("preparedSubtitles.install(nil)", start)
        self.assertIn("preparedSubtitles.refresh(at: time)", start)
        self.assertIn("applySubtitlePreferences()", start)
        load = player.split("private func loadPreparedSubtitles()", 1)[1].split("private func applySubtitleMode", 1)[0]
        self.assertNotIn("!requiresVLC", load)
        self.assertIn("TokenStore.credentialFingerprint() == credential", load)
        mode = player.split("private func applySubtitleMode", 1)[1].split("private func phoneSkipButton", 1)[0]
        self.assertIn("preparedSubtitles.setMode(mode, at: playerTime ?? 0)", mode)
        self.assertIn("guard !requiresVLC", mode)
        self.assertEqual(player.count(".disabled(vlcPlayback != nil && !preparedSubtitles.isAvailable)"), 2)

    def test_preparation_uses_original_container_and_format_specific_errors(self):
        sheet = source("Orvian/Features/Viewer/PreparedSubtitleSheet.swift")
        self.assertNotIn('appendingPathComponent("source.mov")', sheet)
        self.assertIn("fileName: file.name", sheet)
        self.assertIn("VideoPlaybackCompatibility.requiresVLC", sheet)
        self.assertIn("PreparedSubtitleError.unsupportedMedia", sheet)
        model = source("Orvian/Core/Media/PreparedSubtitles.swift")
        self.assertIn("case .unsupportedMedia:", model)

    def test_preparation_shows_controls_and_progress_not_information_messages(self):
        sheet = source("Orvian/Features/Viewer/PreparedSubtitleSheet.swift")
        form = sheet.split("struct PreparedSubtitleSheet:", 1)[1]
        self.assertNotIn("Text(job.status)", form)
        for text in ["La vidéo entière est analysée", "Contexte de traduction :", "La qualité dépend",
                     "Les passages reconnus", "Transcription et traduction :", "Si les repères sont perdus"]:
            self.assertNotIn(text, form)
        self.assertIn("ProgressView(value: job.progress)", form)
        self.assertIn("if let error = job.error", form)
        self.assertIn('Picker("Langue parlée"', form)
        overlay = source("Orvian/UI/SubtitleOverlay.swift")
        self.assertNotIn("Préparation de la traduction…", overlay)
        self.assertNotIn("Traduction en cours…", overlay)
        self.assertIn("if let translationError", overlay)


if __name__ == "__main__":
    unittest.main()
