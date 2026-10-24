"""Focused source-container safety and preparation sequencing regressions."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHEET = ROOT / "Orvian/Features/Viewer/PreparedSubtitleSheet.swift"
MODEL = ROOT / "Orvian/Core/Media/PreparedSubtitles.swift"


class PreparedSubtitleSourceTests(unittest.TestCase):
    def test_real_swift_extension_sanitizer_and_unsupported_error(self):
        compiler = shutil.which("swiftc")
        if not compiler:
            self.skipTest("Swift compiler unavailable")
        sheet = SHEET.read_text(encoding="utf-8")
        helper = re.search(
            r"    static func sourceExtension\(fileName: String\) -> String \{\n.*?\n    \}",
            sheet, re.S,
        )
        self.assertIsNotNone(helper)
        error = "enum PreparedSubtitleError:" + MODEL.read_text(encoding="utf-8").split(
            "enum PreparedSubtitleError:", 1
        )[1]
        checks = r'''
@main struct Checks {
    static func main() {
        let samples: [(String, String)] = [
            ("film.mkv", "mkv"), ("film.MPEG", "mpeg"), ("film.mpg", "mpg"),
            ("film.MP4", "mp4"), ("film.mov", "mov"), ("film.m2ts", "m2ts"),
            ("film", "bin"), ("film.", "bin"), ("", "bin"),
            ("film.mk v", "bin"), ("film.mkv?token=secret", "bin"),
            ("film.%2F", "bin"), ("film.mkv;rm", "bin"),
            ("film.\u{0000}mkv", "bin"), ("film.\nmkv", "bin"),
            ("film.é", "bin"), ("film.abcdefghijklmnopq", "bin"),
            ("../../escape.MKV", "mkv")
        ]
        let directory = URL(fileURLWithPath: "/protected/sources/unique", isDirectory: true)
        for (name, expected) in samples {
            let suffix = Download.sourceExtension(fileName: name)
            assert(suffix == expected, "Unexpected extension for \(name): \(suffix)")
            let local = directory.appendingPathComponent("source").appendingPathExtension(suffix)
            assert(local.deletingLastPathComponent() == directory)
            assert(local.lastPathComponent == "source.\(expected)")
        }
        let message = PreparedSubtitleError.unsupportedMedia.localizedDescription
        assert(message.contains("VLC") && message.contains("Apple") && message.contains("décoder"))
        assert(!message.contains("connexion") && !message.contains("modèles"))
    }
}
'''
        program = "import Foundation\nenum Download {\n" + helper.group() + "\n}\n" + error + checks
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "checks.swift"
            executable = Path(temporary) / ("checks.exe" if os.name == "nt" else "checks")
            source.write_text(program, encoding="utf-8")
            subprocess.run([compiler, "-parse-as-library", "-swift-version", "5",
                            str(source), "-o", str(executable)], check=True, timeout=120)
            subprocess.run([str(executable)], check=True, timeout=30)

    def test_translation_waits_for_native_transcription_and_keeps_validation(self):
        sheet = SHEET.read_text(encoding="utf-8")
        before, after = sheet.split("session.prepareTranslation()", 1)
        self.assertIn("PreparedSubtitleAnalyzer.shared.transcribe", before)
        self.assertRegex(before, r"try validate\(key\)\s*//[^\n]*\n\s*if let session \{ try await $")
        self.assertRegex(after, r"\s*\}\s*try validate\(key\)\s*for index in cues.indices")
        self.assertIn("configuration?.invalidate()", sheet)
        self.assertIn("withTaskCancellationHandler", sheet)
        self.assertIn("onCancel: { task.cancel() }", sheet)
        self.assertIn("TokenStore.credentialFingerprint() == key.credential else { return }", sheet)
        self.assertNotIn("var status", sheet)
        self.assertNotIn("contextFallbackCount", sheet)

    def test_download_keeps_original_extension_and_protected_cleanup(self):
        sheet = SHEET.read_text(encoding="utf-8")
        self.assertEqual(sheet.count("fileName: file.name"), 2)
        self.assertIn("PreparedSubtitleDownload.fetch(key: key, fileName: fileName)", sheet)
        self.assertIn(".appendingPathExtension(sourceExtension(fileName: fileName))", sheet)
        self.assertNotIn('"source.mov"', sheet)
        self.assertIn("catch is CancellationError", sheet)
        self.assertIn("VideoPlaybackCompatibility.requiresVLC(for: error)", sheet)
        self.assertIn("PreparedSubtitleError.unsupportedMedia.localizedDescription", sheet)
        self.assertIn("if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }", sheet)
        self.assertIn("defer { try? FileManager.default.removeItem(at: temporary) }", sheet)
        self.assertIn("try? FileManager.default.removeItem(at: directory)", sheet)
        self.assertEqual(sheet.count("FileProtectionType.complete"), 2)
        self.assertIn("configuration.httpCookieStorage = nil", sheet)
        self.assertIn("configuration.urlCredentialStorage = nil", sheet)
        self.assertIn("(200..<300).contains(http.statusCode)", sheet)
        self.assertNotIn("Authorization", sheet)


if __name__ == "__main__":
    unittest.main()
